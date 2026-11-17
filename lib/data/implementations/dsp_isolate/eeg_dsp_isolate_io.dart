import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import '../../../domain/models/eeg_band_power.dart';
import '../../../domain/models/eeg_channel_catalog.dart';
import '../../../domain/models/eeg_sample.dart';
import '../eeg_coherence_tracker.dart';
import '../eeg_ring_buffer.dart';
import '../eeg_signal_processor.dart';
import '../eeg_spectral.dart';

/// Background [Isolate] client offloading 128–256 Hz EEG spectral DSP
/// (Hann-detrended band powers, Welch hemispheric coherence, and Goertzel
/// stimulus FFR SNR) off the UI thread.
///
/// Raw samples are micro-batched (12 samples = 1 Muse BLE frame, or 16 ms max
/// latency) into a flat [Float64List] and moved zero-copy via
/// [TransferableTypedData], publishing only aggregated frames (4 Hz band power,
/// 1 Hz coherence/FFR) back to the main isolate for SINT consumers.
class EegDspIsolateClient {
  static const int _batchMaxFrames = 12;
  static const Duration _batchMaxDelay = Duration(milliseconds: 16);
  static const int _maxQueuedMessages = 2048;

  final void Function(List<EegBandPower> frame) onBandPower;
  final void Function(EegPairCoherence coherence) onCoherence;

  Isolate? _isolate;
  ReceivePort? _receivePort;
  StreamSubscription<dynamic>? _portSub;
  SendPort? _workerPort;
  Future<void>? _spawning;

  final List<Object> _pendingMessages = <Object>[];
  final Map<int, Completer<Object?>> _requests = <int, Completer<Object?>>{};
  int _nextRequestId = 1;

  List<String> _channels = const [];
  EegHemisphericPair? _currentPair;
  int _sessionGen = 0;
  int _pairGen = 0;
  bool _configured = false;
  bool _disposed = false;

  Float64List _batchBuffer = Float64List(0);
  int _batchFrames = 0;
  Timer? _flushTimer;

  EegDspIsolateClient({
    required this.onBandPower,
    required this.onCoherence,
  });

  static bool get isSupported => true;

  bool get isActive => _configured && !_disposed;

  Future<void> _ensureSpawned() {
    if (_workerPort != null) return Future<void>.value();
    final existing = _spawning;
    if (existing != null) return existing;

    final completer = Completer<void>();
    _spawning = completer.future;

    final port = ReceivePort();
    _receivePort = port;
    _portSub = port.listen((dynamic msg) {
      if (msg is SendPort) {
        _workerPort = msg;
        for (final queued in _pendingMessages) {
          msg.send(queued);
        }
        _pendingMessages.clear();
        if (!completer.isCompleted) completer.complete();
        return;
      }
      _handleWorkerMessage(msg);
    });

    Isolate.spawn(
      _eegDspWorkerMain,
      port.sendPort,
      debugName: 'neom_eeg_dsp_worker',
    ).then<void>((iso) {
      if (_disposed) {
        iso.kill(priority: Isolate.immediate);
        if (!completer.isCompleted) completer.complete();
        return;
      }
      _isolate = iso;
    }, onError: (Object e, StackTrace st) {
      _spawning = null;
      if (!completer.isCompleted) completer.completeError(e, st);
    });

    return completer.future;
  }

  void _send(Object message) {
    if (_disposed) return;
    final port = _workerPort;
    if (port != null) {
      port.send(message);
    } else {
      if (_pendingMessages.length >= _maxQueuedMessages) {
        // Drop only the oldest sample batch, never a 'config' or 'pair' command.
        final dropIdx = _pendingMessages.indexWhere(
          (m) => m is Map && m['op'] == 'samples',
        );
        if (dropIdx >= 0) {
          _pendingMessages.removeAt(dropIdx);
        }
      }
      _pendingMessages.add(message);
    }
  }

  Future<void> configure({
    required List<String> channelNames,
    required int sampleRate,
    required bool deriveBandPower,
    required Duration bandWindow,
    required Duration bandHop,
    required Duration coherenceWindow,
    required Duration coherenceHop,
    required double coherenceSegmentSeconds,
    required EegHemisphericPair? analysisPair,
    Duration ffrWindow = const Duration(seconds: 8),
    int ffrMaxChannels = 6,
  }) async {
    if (_disposed) return;
    _flushTimer?.cancel();
    _flushTimer = null;
    _batchFrames = 0;

    _sessionGen++;
    _pairGen++;
    _channels = List<String>.unmodifiable(channelNames);
    _currentPair = analysisPair;
    _batchBuffer = Float64List(_batchMaxFrames * math.max(1, _channels.length));
    _configured = true;

    // Enqueue 'config' synchronously BEFORE awaiting isolate startup so any
    // samples pushed immediately after connect() execute strictly after config.
    _send(<String, Object?>{
      'op': 'config',
      'sessionGen': _sessionGen,
      'pairGen': _pairGen,
      'channels': _channels,
      'sampleRate': sampleRate,
      'deriveBandPower': deriveBandPower,
      'bandWindowUs': bandWindow.inMicroseconds,
      'bandHopUs': bandHop.inMicroseconds,
      'coherenceWindowUs': coherenceWindow.inMicroseconds,
      'coherenceHopUs': coherenceHop.inMicroseconds,
      'coherenceSegmentSeconds': coherenceSegmentSeconds,
      'pairLeft': analysisPair?.left,
      'pairRight': analysisPair?.right,
      'pairRegion': analysisPair?.region,
      'ffrWindowUs': ffrWindow.inMicroseconds,
      'ffrMaxChannels': ffrMaxChannels,
    });

    await _ensureSpawned();
  }

  void updatePair(EegHemisphericPair? pair) {
    if (!_configured || _disposed) return;
    if (_currentPair == pair) return;
    _flushPendingBatchSync();
    _currentPair = pair;
    _pairGen++;
    _send(<String, Object?>{
      'op': 'pair',
      'sessionGen': _sessionGen,
      'pairGen': _pairGen,
      'pairLeft': pair?.left,
      'pairRight': pair?.right,
      'pairRegion': pair?.region,
    });
  }

  void pushSample(EegSample sample) {
    if (!_configured || _disposed || _channels.isEmpty) return;
    final nCh = _channels.length;
    if (_batchBuffer.length < _batchMaxFrames * nCh) {
      _batchBuffer = Float64List(_batchMaxFrames * nCh);
    }
    final base = _batchFrames * nCh;
    for (var c = 0; c < nCh; c++) {
      final v = sample.channels[_channels[c]];
      _batchBuffer[base + c] = (v != null && v.isFinite) ? v : double.nan;
    }
    _batchFrames++;

    if (_batchFrames >= _batchMaxFrames) {
      _flushPendingBatchSync();
    } else {
      _flushTimer ??= Timer(_batchMaxDelay, _flushPendingBatchSync);
    }
  }

  void _flushPendingBatchSync() {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (_batchFrames == 0 || !_configured || _disposed || _channels.isEmpty) {
      _batchFrames = 0;
      return;
    }
    final count = _batchFrames * _channels.length;
    final payload = Float64List.sublistView(_batchBuffer, 0, count);
    final transferable = TransferableTypedData.fromList([payload]);
    final frames = _batchFrames;
    _batchFrames = 0;

    _send(<String, Object?>{
      'op': 'samples',
      'sessionGen': _sessionGen,
      'frames': frames,
      'data': transferable,
    });
  }

  /// Flushes any buffered micro-batch and waits for the worker isolate to
  /// process all queued messages up to this point.
  Future<void> flush() async {
    if (!_configured || _disposed) return;
    _flushPendingBatchSync();
    await _ensureSpawned();
    if (_disposed || _workerPort == null) return;
    final reqId = _nextRequestId++;
    final completer = Completer<Object?>();
    _requests[reqId] = completer;
    _send(<String, Object?>{'op': 'ping', 'reqId': reqId});
    await completer.future;
  }

  Future<({double snr, double hz})?> computeFfr({
    required double stimulusHz,
    required List<String> excludedChannels,
  }) async {
    if (!_configured || _disposed) return null;
    _flushPendingBatchSync();
    await _ensureSpawned();
    if (_disposed || _workerPort == null) return null;

    final reqId = _nextRequestId++;
    final completer = Completer<Object?>();
    _requests[reqId] = completer;
    _send(<String, Object?>{
      'op': 'ffr',
      'reqId': reqId,
      'sessionGen': _sessionGen,
      'hz': stimulusHz,
      'excluded': excludedChannels,
    });
    final res = await completer.future;
    if (res is Map) {
      final snr = (res['snr'] as num?)?.toDouble();
      final hz = (res['hz'] as num?)?.toDouble();
      if (snr != null && hz != null && snr.isFinite) {
        return (snr: snr, hz: hz);
      }
    }
    return null;
  }

  void reset() {
    _flushTimer?.cancel();
    _flushTimer = null;
    _batchFrames = 0;
    _configured = false;
    _currentPair = null;
    _sessionGen++;
    _pairGen++;
    for (final c in _requests.values) {
      if (!c.isCompleted) c.complete(null);
    }
    _requests.clear();
    if (_workerPort != null) {
      _send(<String, Object?>{'op': 'reset', 'sessionGen': _sessionGen});
    } else {
      _pendingMessages.clear();
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    reset();
    _disposed = true;
    final port = _workerPort;
    _workerPort = null;
    if (port != null) {
      try {
        port.send(const <String, Object?>{'op': 'dispose'});
      } catch (_) {}
    }
    await _portSub?.cancel();
    _portSub = null;
    _receivePort?.close();
    _receivePort = null;
    _isolate?.kill(priority: Isolate.beforeNextEvent);
    _isolate = null;
    _spawning = null;
  }

  void _handleWorkerMessage(dynamic msg) {
    if (_disposed || msg is! Map) return;
    final type = msg['type'] as String?;
    switch (type) {
      case 'bands':
        if (msg['sessionGen'] != _sessionGen) return;
        final channels = (msg['channels'] as List).cast<String>();
        final values = (msg['values'] as TransferableTypedData)
            .materialize()
            .asFloat64List();
        final now = DateTime.now();
        final frame = <EegBandPower>[];
        for (var i = 0; i < channels.length; i++) {
          final b = i * 6;
          frame.add(EegBandPower(
            channel: channels[i],
            delta: values[b],
            theta: values[b + 1],
            alpha: values[b + 2],
            betaLow: values[b + 3],
            betaHigh: values[b + 4],
            gamma: values[b + 5],
            timestamp: now,
          ));
        }
        if (frame.isNotEmpty) onBandPower(frame);

      case 'coherence':
        if (msg['sessionGen'] != _sessionGen || msg['pairGen'] != _pairGen) {
          return;
        }
        final pair = _currentPair;
        if (pair == null) return;
        onCoherence(EegPairCoherence(
          pair: pair,
          msc: Map<String, double>.from(msg['msc'] as Map),
          imaginary: Map<String, double>.from(msg['imaginary'] as Map),
          thresholds: Map<String, double>.from(msg['thresholds'] as Map),
          window: Duration(microseconds: msg['windowUs'] as int),
          at: DateTime.now(),
        ));

      case 'reply':
        final reqId = msg['reqId'] as int?;
        final completer = reqId == null ? null : _requests.remove(reqId);
        if (completer != null && !completer.isCompleted) {
          completer.complete(msg['result']);
        }
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Background DSP Isolate Entrypoint
// ═══════════════════════════════════════════════════════════════════════════

void _eegDspWorkerMain(SendPort mainPort) {
  final receivePort = ReceivePort();
  mainPort.send(receivePort.sendPort);

  final processor = EegSignalProcessor();
  var sessionGen = 0;
  var pairGen = 0;
  var channels = const <String>[];
  var channelIndex = const <String, int>{};
  var sampleRate = 0;
  var deriveBandPower = false;
  var bandWindowSamples = 256;
  var bandHopSamples = 64;
  var sinceBandEmit = 0;
  var bandSampleCount = 0;

  var ffrWindowSamples = 2048;
  var ffrMaxChannels = 6;

  final bandRings = <String, EegFloat64RingBuffer>{};
  final bandScratch = <String, Float64List>{};
  final ffrRings = <String, EegFloat64RingBuffer>{};
  final ffrScratch = <String, Float64List>{};

  EegCoherenceTracker? coherenceTracker;
  EegHemisphericPair? pair;
  int? pairLeftIdx;
  int? pairRightIdx;

  void updatePairIndices() {
    final p = pair;
    if (p == null) {
      pairLeftIdx = null;
      pairRightIdx = null;
    } else {
      pairLeftIdx = channelIndex[p.left];
      pairRightIdx = channelIndex[p.right];
    }
  }

  void clearState() {
    for (final r in bandRings.values) {
      r.clear();
    }
    for (final r in ffrRings.values) {
      r.clear();
    }
    coherenceTracker?.reset();
    sinceBandEmit = 0;
    bandSampleCount = 0;
  }

  receivePort.listen((dynamic raw) {
    if (raw is! Map) return;
    final op = raw['op'] as String?;

    switch (op) {
      case 'config':
        sessionGen = raw['sessionGen'] as int;
        pairGen = raw['pairGen'] as int;
        channels = (raw['channels'] as List).cast<String>();
        channelIndex = <String, int>{
          for (var i = 0; i < channels.length; i++) channels[i]: i,
        };
        sampleRate = raw['sampleRate'] as int;
        deriveBandPower = raw['deriveBandPower'] as bool;
        final bandWindowUs = raw['bandWindowUs'] as int;
        final bandHopUs = raw['bandHopUs'] as int;
        bandWindowSamples = sampleRate > 0
            ? math.max(1, (bandWindowUs * sampleRate / 1000000).round())
            : 1;
        bandHopSamples = sampleRate > 0
            ? math.max(1, (bandHopUs * sampleRate / 1000000).round())
            : 1;

        final ffrWindowUs = raw['ffrWindowUs'] as int;
        ffrMaxChannels = raw['ffrMaxChannels'] as int;
        ffrWindowSamples = sampleRate > 0
            ? (ffrWindowUs * sampleRate / 1000000)
                .round()
                .clamp(1, sampleRate * 300)
            : 1;

        bandRings.clear();
        bandScratch.clear();
        ffrRings.clear();
        ffrScratch.clear();
        for (final ch in channels) {
          if (deriveBandPower) {
            bandRings[ch] = EegFloat64RingBuffer(bandWindowSamples);
          }
          ffrRings[ch] = EegFloat64RingBuffer(ffrWindowSamples);
        }

        coherenceTracker = EegCoherenceTracker(
          window: Duration(microseconds: raw['coherenceWindowUs'] as int),
          hop: Duration(microseconds: raw['coherenceHopUs'] as int),
          segmentSeconds: (raw['coherenceSegmentSeconds'] as num).toDouble(),
        );
        final pLeft = raw['pairLeft'] as String?;
        final pRight = raw['pairRight'] as String?;
        final pRegion = raw['pairRegion'] as String?;
        pair = (pLeft != null && pRight != null && pRegion != null)
            ? EegHemisphericPair(pLeft, pRight, pRegion)
            : null;
        updatePairIndices();
        sinceBandEmit = 0;
        bandSampleCount = 0;

      case 'pair':
        if (raw['sessionGen'] != sessionGen) return;
        pairGen = raw['pairGen'] as int;
        final pLeft = raw['pairLeft'] as String?;
        final pRight = raw['pairRight'] as String?;
        final pRegion = raw['pairRegion'] as String?;
        pair = (pLeft != null && pRight != null && pRegion != null)
            ? EegHemisphericPair(pLeft, pRight, pRegion)
            : null;
        coherenceTracker?.reset();
        updatePairIndices();

      case 'samples':
        if (raw['sessionGen'] != sessionGen ||
            sampleRate <= 0 ||
            channels.isEmpty) {
          return;
        }
        final frames = raw['frames'] as int;
        final data = (raw['data'] as TransferableTypedData)
            .materialize()
            .asFloat64List();
        final nCh = channels.length;

        for (var f = 0; f < frames; f++) {
          final base = f * nCh;

          // 1. Update FFR & Band-Power Ring Buffers
          for (var c = 0; c < nCh; c++) {
            final ch = channels[c];
            final v = data[base + c];
            final safeV = v.isFinite ? v : 0.0;
            ffrRings[ch]?.push(safeV);
            if (deriveBandPower) {
              bandRings[ch]?.push(safeV);
            }
          }

          // 2. Hemispheric Welch Coherence (1 Hz hop)
          final activePair = pair;
          final tracker = coherenceTracker;
          final lIdx = pairLeftIdx;
          final rIdx = pairRightIdx;
          if (activePair != null &&
              tracker != null &&
              lIdx != null &&
              rIdx != null) {
            final lVal = data[base + lIdx];
            final rVal = data[base + rIdx];
            if (lVal.isFinite && rVal.isFinite) {
              final coh =
                  tracker.pushValues(lVal, rVal, activePair, sampleRate);
              if (coh != null) {
                mainPort.send(<String, Object?>{
                  'type': 'coherence',
                  'sessionGen': sessionGen,
                  'pairGen': pairGen,
                  'msc': coh.msc,
                  'imaginary': coh.imaginary,
                  'thresholds': coh.thresholds,
                  'windowUs': coh.window.inMicroseconds,
                });
              }
            }
          }

          // 3. Sliding-Window Band Power (4 Hz hop)
          if (deriveBandPower) {
            if (bandSampleCount < bandWindowSamples) bandSampleCount++;
            sinceBandEmit++;
            if (sinceBandEmit >= bandHopSamples &&
                bandSampleCount >= bandWindowSamples ~/ 2) {
              sinceBandEmit = 0;
              final windows = <String, List<double>>{};
              for (final ch in channels) {
                final ring = bandRings[ch];
                if (ring == null || ring.isEmpty) continue;
                var scratch = bandScratch[ch];
                if (scratch == null || scratch.length != ring.length) {
                  scratch = Float64List(ring.length);
                  bandScratch[ch] = scratch;
                }
                windows[ch] = ring.toFloat64List(scratch);
              }
              final bpFrame = processor.extractBandPowerFromWindows(
                windows,
                channels,
                sampleRate.toDouble(),
              );
              if (bpFrame.isNotEmpty) {
                final packed = Float64List(bpFrame.length * 6);
                final names = <String>[];
                for (var i = 0; i < bpFrame.length; i++) {
                  final b = bpFrame[i];
                  names.add(b.channel);
                  final off = i * 6;
                  packed[off] = b.delta;
                  packed[off + 1] = b.theta;
                  packed[off + 2] = b.alpha;
                  packed[off + 3] = b.betaLow;
                  packed[off + 4] = b.betaHigh;
                  packed[off + 5] = b.gamma;
                }
                mainPort.send(<String, Object?>{
                  'type': 'bands',
                  'sessionGen': sessionGen,
                  'channels': names,
                  'values': TransferableTypedData.fromList([packed]),
                });
              }
            }
          }
        }

      case 'ffr':
        final reqId = raw['reqId'] as int;
        if (raw['sessionGen'] != sessionGen || sampleRate <= 0) {
          mainPort.send(<String, Object?>{
            'type': 'reply',
            'reqId': reqId,
            'result': null,
          });
          return;
        }
        final hz = (raw['hz'] as num).toDouble();
        final excluded = (raw['excluded'] as List).cast<String>().toSet();
        final candidates = ffrRings.keys
            .where(
              (c) =>
                  !excluded.contains(c) &&
                  (ffrRings[c]?.length ?? 0) >= ffrWindowSamples,
            )
            .toList()
          ..sort((a, b) => _ffrPriority(a).compareTo(_ffrPriority(b)));
        var snrSum = 0.0;
        var snrCount = 0;
        for (final c in candidates.take(ffrMaxChannels)) {
          final ring = ffrRings[c]!;
          var scratch = ffrScratch[c];
          if (scratch == null || scratch.length != ring.length) {
            scratch = Float64List(ring.length);
            ffrScratch[c] = scratch;
          }
          final v = EegSpectral.frequencyFollowingSnr(
            ring.toFloat64List(scratch),
            sampleRate.toDouble(),
            hz,
          );
          if (v != null && v.isFinite) {
            snrSum += v;
            snrCount++;
          }
        }
        mainPort.send(<String, Object?>{
          'type': 'reply',
          'reqId': reqId,
          'result': snrCount > 0
              ? <String, double>{'snr': snrSum / snrCount, 'hz': hz}
              : null,
        });

      case 'ping':
        mainPort.send(<String, Object?>{
          'type': 'reply',
          'reqId': raw['reqId'] as int,
          'result': true,
        });

      case 'reset':
        sessionGen = raw['sessionGen'] as int;
        clearState();

      case 'dispose':
        clearState();
        receivePort.close();
    }
  });
}

int _ffrPriority(String channel) {
  if (EegChannelCatalog.isTemporal(channel)) return 0;
  if (EegChannelCatalog.isPosterior(channel)) return 1;
  return 2;
}

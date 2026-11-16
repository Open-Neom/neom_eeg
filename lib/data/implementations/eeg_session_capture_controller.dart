import 'dart:async';
import 'dart:collection';

import 'package:hive/hive.dart';
import 'package:sint/sint.dart';

import '../../domain/enums/eeg_connection_state.dart';
import '../../domain/enums/eeg_device_type.dart';
import '../../domain/models/eeg_band_power.dart';
import '../../domain/models/eeg_channel_catalog.dart';
import '../../domain/models/eeg_device_info.dart';
import '../../domain/models/eeg_mental_state.dart';
import '../../domain/models/eeg_recording.dart';
import '../../domain/models/eeg_sample.dart';
import '../../domain/models/eeg_session_capture.dart';
import '../../domain/models/eeg_watch_rule.dart';
import '../../domain/use_cases/eeg_recording_service.dart';
import '../hub/eeg_hub.dart';
import 'eeg_indices.dart';
import 'eeg_spectral.dart';

/// Real-time health of the EEG link, refreshed every second.
class EegLiveStats {
  /// Raw samples received in the last full second.
  final int samplesPerSecond;

  /// Band-power frames received in the last full second.
  final int framesPerSecond;

  /// Age of the most recent raw sample; null before the first one.
  final Duration? lastSampleAge;

  /// Samples since the current connection started.
  final int totalSamples;

  /// Nominal rate of the connected headset, for comparison.
  final int expectedSampleRate;

  const EegLiveStats({
    this.samplesPerSecond = 0,
    this.framesPerSecond = 0,
    this.lastSampleAge,
    this.totalSamples = 0,
    this.expectedSampleRate = 0,
  });

  /// Data arrived within the last two seconds.
  bool get isFlowing => lastSampleAge != null && lastSampleAge! < const Duration(seconds: 2);

  /// Received ÷ nominal for the last second, `0..1`.
  double get throughput => expectedSampleRate <= 0
      ? 0.0
      : (samplesPerSecond / expectedSampleRate).clamp(0.0, 1.0);

  static const idle = EegLiveStats();
}

/// Keeps a rolling, per-second record of everything the hub streams while a
/// headset is connected, and cuts [EegSessionCapture]s out of it aligned
/// with what the host is doing (a Cámara Neom practice, a recording).
///
/// Capture happens continuously — the point is to be able to say, after
/// the fact, *what the headset showed while the user was doing X* — but
/// only [EegSessionCapture]s are persisted. The buffer holds
/// [bufferSeconds] of history so a segment can be closed a little late
/// without losing its beginning.
///
/// Segments open in two ways:
/// * explicitly, with [startSegment] / [endSegment] — the host bridge
///   calls these when its own session starts and ends and supplies a
///   `contextSampler` for what it is playing;
/// * automatically, following `hub.recording` — a recording started from
///   the dashboard yields a capture of its own.
class EegSessionCaptureController extends SintController {
  static const boxName = 'eeg_session_captures';

  final EegHub hub;
  final int bufferSeconds;
  final Duration contextInterval;

  /// Raw window the stimulus-following SNR is computed over (≥ 4 s for the
  /// 0.25 Hz resolution it needs).
  final Duration ffrWindow;

  /// At most this many electrodes are used for the SNR (temporal and
  /// posterior first), to bound the cost on 32-channel caps.
  final int ffrMaxChannels;

  EegSessionCaptureController({
    required this.hub,
    this.bufferSeconds = 2 * 3600,
    this.contextInterval = const Duration(seconds: 5),
    this.ffrWindow = const Duration(seconds: 8),
    this.ffrMaxChannels = 6,
    Duration tick = const Duration(seconds: 1),
  }) : _tick = tick;

  final Duration _tick;

  // ── Reactive state for the UI ───────────────────────────────────────
  final Rx<EegLiveStats> liveStats = EegLiveStats.idle.obs;
  final RxBool segmentOpen = false.obs;
  final RxnString segmentPracticeId = RxnString();
  final RxInt segmentSeconds = 0.obs;
  final RxList<EegSessionCapture> captures = <EegSessionCapture>[].obs;

  // ── Live buffer ─────────────────────────────────────────────────────
  final _rows = ListQueue<_TimedRow>();
  _Accumulator _acc = _Accumulator();
  DateTime? _lastSampleAt;
  int _totalSamples = 0;
  EegMentalState? _lastMetrics;
  final _rawWindow = <String, ListQueue<double>>{};
  Timer? _ticker;
  final _subs = <StreamSubscription<dynamic>>[];
  StreamSubscription<EegRecording?>? _recordingSub;
  EegRecordingService? _followedRecording;

  // ── Open segment ────────────────────────────────────────────────────
  _Segment? _segment;
  Timer? _contextTimer;
  StreamSubscription<EegMarker>? _markerSub;

  Box<Map>? _box;
  final Map<String, Map<String, dynamic>> _memoryFallback = {};
  bool _disposed = false;
  static const int _maxSegmentEvents = 10000;
  static const int _maxRawChannels = 64;

  @override
  void onInit() {
    super.onInit();
    _subs.addAll([
      hub.rawStream.listen(_onRaw),
      hub.bandPowerStream.listen(_onBands),
      hub.mentalStateStream.listen((m) => _lastMetrics = m),
      hub.connectionStateStream.listen(_onConnection),
    ]);
    _ticker = Timer.periodic(_tick, (_) => _onTick());
    _followRecording();
    unawaited(_loadCaptures());
  }

  @override
  void onClose() {
    if (_disposed) return;
    _disposed = true;
    _ticker?.cancel();
    _ticker = null;
    _contextTimer?.cancel();
    _contextTimer = null;
    _markerSub?.cancel();
    _markerSub = null;
    _recordingSub?.cancel();
    _recordingSub = null;
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    liveStats.close();
    segmentOpen.close();
    segmentPracticeId.close();
    segmentSeconds.close();
    captures.close();
    super.onClose();
  }

  // ── Public API ──────────────────────────────────────────────────────

  /// Whether the headset is delivering samples right now.
  bool get isCapturingLive => liveStats.value.isFlowing;

  /// Rows currently held in the live buffer (oldest first), relative to
  /// [since] when given.
  List<EegCaptureRow> liveRows({DateTime? since}) {
    final origin = since ?? (_rows.isEmpty ? DateTime.now() : _rows.first.at);
    return [
      for (final r in _rows)
        if (since == null || !r.at.isBefore(since))
          r.row.shifted(r.at.difference(origin).inMilliseconds / 1000.0 - r.row.t),
    ];
  }

  /// Opens a capture segment aligned with a host session.
  ///
  /// [contextSampler] is polled every [contextInterval] and its map stored
  /// verbatim (use [EegContextKeys] for the fields the report understands).
  /// Calling it while a segment is open closes that one first.
  Future<void> startSegment({
    String? practiceSessionId,
    Map<String, dynamic> Function()? contextSampler,
    DateTime? startedAt,
  }) =>
      _openSegment(
        practiceSessionId: practiceSessionId,
        contextSampler: contextSampler,
        startedAt: startedAt,
        fromRecording: false,
      );

  Future<void> _openSegment({
    required String? practiceSessionId,
    required Map<String, dynamic> Function()? contextSampler,
    required DateTime? startedAt,
    required bool fromRecording,
  }) async {
    if (_segment != null) await endSegment();
    final start = startedAt ?? DateTime.now();
    _segment = _Segment(
      practiceSessionId: practiceSessionId,
      startedAt: start,
      contextSampler: contextSampler,
      device: hub.connectedDevice,
      initialExcluded: hub.excludedChannels,
      fromRecording: fromRecording,
    );
    segmentOpen.value = true;
    segmentPracticeId.value = practiceSessionId;
    segmentSeconds.value = 0;

    _sampleContext();
    _contextTimer?.cancel();
    if (contextSampler != null) {
      _contextTimer = Timer.periodic(contextInterval, (_) => _sampleContext());
    }
    _markerSub?.cancel();
    _markerSub = hub.recording.markerStream.listen((m) => _segment?.markers.add(m));
  }

  /// Adds a context snapshot now (e.g. right when the host changes
  /// frequency), in addition to the periodic ones.
  void annotateContext(Map<String, dynamic> values) {
    final seg = _segment;
    if (seg == null || seg.context.length >= _maxSegmentEvents) return;
    seg.context.add(EegContextSample(t: _elapsed(seg), values: Map.of(values)));
  }

  /// Records what the host's microphone pipeline reported.
  void noteVoice(EegVoiceEventKind kind, {double? frequencyHz}) {
    final seg = _segment;
    if (seg == null || seg.voice.length >= _maxSegmentEvents) return;
    seg.voice.add(EegVoiceEvent(t: _elapsed(seg), kind: kind, frequencyHz: frequencyHz));
  }

  /// Records a watch alert in the open segment. The watcher calls this so
  /// the report shows what fired even when no recording took the marker.
  void noteAlert(EegAlert alert) {
    final seg = _segment;
    if (seg == null || seg.alerts.length >= _maxSegmentEvents) return;
    seg.alerts.add(EegAlertNote(
      t: alert.firedAt.difference(seg.startedAt).inMilliseconds / 1000.0,
      ruleId: alert.rule.id,
      label: alert.rule.label,
      severity: alert.severity.name,
      value: alert.value,
      threshold: alert.threshold,
      sustainedSeconds: alert.sustained.inMilliseconds / 1000.0,
      markerAdded: alert.markerAdded,
      pair: alert.pair,
    ));
  }

  /// Closes the open segment, persists it and returns it. Returns null when
  /// nothing was open or the segment holds neither EEG nor markers.
  Future<EegSessionCapture?> endSegment({DateTime? endedAt}) async {
    final seg = _segment;
    if (seg == null) return null;
    _segment = null;
    _contextTimer?.cancel();
    _contextTimer = null;
    await _markerSub?.cancel();
    _markerSub = null;
    segmentOpen.value = false;
    segmentPracticeId.value = null;

    // Fold the second in progress so a short session is not lost.
    _flushAccumulator(DateTime.now());

    final end = endedAt ?? DateTime.now();
    final rows = [
      for (final r in _rows)
        if (!r.at.isBefore(seg.startedAt) && !r.at.isAfter(end))
          r.row.shifted(r.at.difference(seg.startedAt).inMilliseconds / 1000.0 - r.row.t),
    ];
    // Seconds with no samples are kept inside a capture (they show the
    // gaps), but a segment that never saw the headset is not worth saving.
    final hasSignal = rows.any((r) => r.samples > 0 || r.frames > 0);
    if (!hasSignal && seg.markers.isEmpty && seg.alerts.isEmpty) return null;

    final device = seg.device ?? hub.connectedDevice;
    final capture = EegSessionCapture(
      id: 'cap_${seg.startedAt.microsecondsSinceEpoch}',
      practiceSessionId: seg.practiceSessionId,
      deviceType: device?.type ??
          hub.registry.connectableTypes.firstOrNull ??
          EegDeviceType.simulated,
      deviceName: device?.name ?? 'EEG',
      channels: device?.channelLabels ?? const [],
      sampleRate: device?.sampleRate ?? 0,
      startedAt: seg.startedAt,
      endedAt: end,
      rows: rows,
      context: List.of(seg.context),
      voice: List.of(seg.voice),
      markers: List.of(seg.markers),
      contactChanges: List.of(seg.contactChanges),
      alerts: List.of(seg.alerts),
    );
    await _save(capture);
    return capture;
  }

  Future<List<EegSessionCapture>> listCaptures() async {
    await _openBox();
    final out = <EegSessionCapture>[];
    final values = (_box != null && _box!.isOpen)
        ? _box!.values
        : _memoryFallback.values;
    for (final json in values) {
      try {
        out.add(EegSessionCapture.fromJson(Map<String, dynamic>.from(json)));
      } catch (_) {
        // A row from an older schema; skip rather than break the list.
      }
    }
    out.sort((a, b) => b.startedAt.compareTo(a.startedAt));
    if (!_disposed) captures.assignAll(out);
    return out;
  }

  Future<EegSessionCapture?> capturesFor(String practiceSessionId) async {
    final all = await listCaptures();
    return all.where((c) => c.practiceSessionId == practiceSessionId).firstOrNull;
  }

  Future<void> deleteCapture(String id) async {
    await _openBox();
    if (_box != null && _box!.isOpen) {
      await _box!.delete(id);
    } else {
      _memoryFallback.remove(id);
    }
    if (!_disposed) captures.removeWhere((c) => c.id == id);
  }

  // ── Ingest ──────────────────────────────────────────────────────────

  void _onRaw(EegSample s) {
    if (_disposed) return;
    _lastSampleAt = DateTime.now();
    _totalSamples++;
    _acc.samples++;

    final rate = hub.connectedDevice?.sampleRate ?? 0;
    if (rate <= 0 || ffrWindow <= Duration.zero) return;
    final cap = (ffrWindow.inMicroseconds * rate / 1000000)
        .round()
        .clamp(1, rate * 300);
    for (final e in s.channels.entries) {
      if (!_rawWindow.containsKey(e.key) &&
          _rawWindow.length >= _maxRawChannels) {
        continue;
      }
      final q = _rawWindow.putIfAbsent(e.key, ListQueue<double>.new);
      q.addLast(e.value.isFinite ? e.value : 0.0);
      while (q.length > cap) {
        q.removeFirst();
      }
    }
  }

  static double _finiteBand(double v) => v.isFinite ? v : 0.0;

  void _onBands(List<EegBandPower> frame) {
    if (_disposed || frame.isEmpty) return;
    _acc.frames++;
    for (final b in frame) {
      _acc.delta += _finiteBand(b.delta);
      _acc.theta += _finiteBand(b.theta);
      _acc.alpha += _finiteBand(b.alpha);
      _acc.betaLow += _finiteBand(b.betaLow);
      _acc.betaHigh += _finiteBand(b.betaHigh);
      _acc.gamma += _finiteBand(b.gamma);
    }
    _acc.channelReadings += frame.length;

    // Power symmetry of alpha on the frame's pair (the hub already dropped
    // electrodes without contact, so this is the hub's analysis pair).
    final sym = EegIndices.symmetry(frame);
    if (sym != null) {
      _acc.symmetrySum += sym;
      _acc.symmetryCount++;
    }
  }

  void _onConnection(EegConnectionState state) {
    if (state == EegConnectionState.streaming) {
      _totalSamples = 0;
      _lastSampleAt = null;
      _acc = _Accumulator();
      _rawWindow.clear();
      _followRecording();
    } else if (state == EegConnectionState.disconnected ||
        state == EegConnectionState.error) {
      liveStats.value = EegLiveStats.idle;
    }
  }

  /// Follows `hub.recording`, which changes with the active driver. Only
  /// re-subscribes when the instance actually changed: cancelling a
  /// broadcast subscription drops events already queued for it, and the
  /// `streaming` notification can land right after a recording started.
  void _followRecording() {
    final service = hub.recording;
    if (identical(service, _followedRecording) && _recordingSub != null) return;
    _recordingSub?.cancel();
    _followedRecording = service;
    _recordingSub = service.activeRecordingStream.listen((rec) {
      if (rec != null) {
        // A recording started from the dashboard; capture alongside it
        // unless the host already opened a segment for its own session.
        if (_segment == null) {
          unawaited(_openSegment(
            practiceSessionId: rec.id,
            contextSampler: null,
            startedAt: rec.startedAt,
            fromRecording: true,
          ));
        }
      } else if (_segment != null && _segment!.fromRecording) {
        unawaited(endSegment());
      }
    });
  }

  void _onTick() {
    final now = DateTime.now();
    _flushAccumulator(now);

    final seg = _segment;
    if (seg != null) {
      segmentSeconds.value = _elapsed(seg).floor();
      final excluded = hub.excludedChannels;
      if (!_sameList(excluded, seg.lastExcluded)) {
        seg.lastExcluded = List.of(excluded);
        seg.contactChanges.add(EegContactChange(t: _elapsed(seg), excluded: List.of(excluded)));
      }
    }
  }

  void _flushAccumulator(DateTime now) {
    final connected = hub.connectionState == EegConnectionState.streaming;
    final acc = _acc;
    _acc = _Accumulator();

    if (connected) {
      liveStats.value = EegLiveStats(
        samplesPerSecond: acc.samples,
        framesPerSecond: acc.frames,
        lastSampleAge: _lastSampleAt == null ? null : now.difference(_lastSampleAt!),
        totalSamples: _totalSamples,
        expectedSampleRate: hub.connectedDevice?.sampleRate ?? 0,
      );
    } else {
      liveStats.value = EegLiveStats.idle;
      if (acc.samples == 0 && acc.frames == 0) return;
    }

    final n = acc.channelReadings == 0 ? 1 : acc.channelReadings;
    final m = _lastMetrics;
    final coherence = hub.lastCoherence;
    final ffr = _frequencyFollowing();
    _rows.addLast(_TimedRow(
      at: now,
      row: EegCaptureRow(
        t: 0,
        delta: acc.delta / n,
        theta: acc.theta / n,
        alpha: acc.alpha / n,
        betaLow: acc.betaLow / n,
        betaHigh: acc.betaHigh / n,
        gamma: acc.gamma / n,
        coherence: connected && coherence != null && coherence.isFresh(now: now)
            ? coherence.of(EegIndices.hemisphericBand)
            : null,
        symmetry: acc.symmetryCount > 0 ? acc.symmetrySum / acc.symmetryCount : null,
        ffrSnr: ffr?.snr,
        ffrHz: ffr?.hz,
        focus: m?.focus,
        relaxation: m?.relaxation,
        engagement: m?.engagement,
        excitement: m?.excitement,
        stress: m?.stress,
        samples: acc.samples,
        frames: acc.frames,
      ),
    ));
    final maxBuffer = bufferSeconds < 1 ? 1 : bufferSeconds;
    while (_rows.length > maxBuffer) {
      _rows.removeFirst();
    }
  }

  /// Stimulus the host is playing, from the latest context sample of the
  /// open segment: the isochronic pulse when on, otherwise the binaural
  /// beat. Null when neither is set.
  double? _stimulusHz() {
    final ctx = _segment?.context;
    if (ctx == null || ctx.isEmpty) return null;
    final last = ctx.last;
    final iso = last.hz(EegContextKeys.isochronicHz);
    if (iso != null && iso > 0) return iso;
    final beat = last.hz(EegContextKeys.beatHz);
    if (beat != null && beat > 0) return beat;
    return null;
  }

  /// SNR at the stimulus frequency, averaged over up to [ffrMaxChannels]
  /// electrodes in contact (temporal and posterior first: auditory and
  /// resting-alpha cortex).
  ({double snr, double hz})? _frequencyFollowing() {
    final hz = _stimulusHz();
    final rate = hub.connectedDevice?.sampleRate ?? 0;
    if (hz == null || rate <= 0 || _segment == null) return null;
    final excluded = hub.excludedChannels.toSet();
    final full = (ffrWindow.inMicroseconds * rate / 1000000).round();
    final channels = _rawWindow.keys
        .where((c) => !excluded.contains(c) && _rawWindow[c]!.length >= full)
        .toList()
      ..sort((a, b) => _ffrPriority(a).compareTo(_ffrPriority(b)));
    final snrs = <double>[];
    for (final c in channels.take(ffrMaxChannels)) {
      final v = EegSpectral.frequencyFollowingSnr(_rawWindow[c]!.toList(), rate.toDouble(), hz);
      if (v != null) snrs.add(v);
    }
    if (snrs.isEmpty) return null;
    return (snr: snrs.reduce((a, b) => a + b) / snrs.length, hz: hz);
  }

  static int _ffrPriority(String channel) {
    if (EegChannelCatalog.isTemporal(channel)) return 0;
    if (EegChannelCatalog.isPosterior(channel)) return 1;
    return 2;
  }

  void _sampleContext() {
    final seg = _segment;
    final sampler = seg?.contextSampler;
    if (seg == null || sampler == null) return;
    try {
      seg.context.add(EegContextSample(t: _elapsed(seg), values: Map.of(sampler())));
    } catch (_) {
      // A host getter threw (controller disposed mid-session); skip this tick.
    }
  }

  double _elapsed(_Segment seg) =>
      DateTime.now().difference(seg.startedAt).inMilliseconds / 1000.0;

  static bool _sameList(List<String> a, List<String> b) =>
      a.length == b.length && Set.of(a).containsAll(b);

  // ── Persistence ─────────────────────────────────────────────────────

  Future<void> _openBox() async {
    if (_box != null && _box!.isOpen) return;
    if (Hive.isBoxOpen(boxName)) {
      _box = Hive.box<Map>(boxName);
      return;
    }
    final completer = Completer<Box<Map>?>();
    runZonedGuarded(
      () async {
        try {
          final box = await Hive.openBox<Map>(boxName);
          if (!completer.isCompleted) completer.complete(box);
        } catch (_) {
          if (!completer.isCompleted) completer.complete(null);
        }
      },
      (_, _) {
        if (!completer.isCompleted) completer.complete(null);
      },
    );
    _box = await completer.future;
  }

  Future<void> _save(EegSessionCapture c) async {
    await _openBox();
    final data = c.toJson();
    if (_box != null && _box!.isOpen) {
      await _box!.put(c.id, data);
    } else {
      _memoryFallback[c.id] = data;
    }
    if (!_disposed) captures.insert(0, c);
  }

  Future<void> _loadCaptures() async {
    try {
      await listCaptures();
    } catch (_) {
      // Hive not initialised yet (tests, early boot); list() will retry.
    }
  }

}

class _TimedRow {
  final DateTime at;
  final EegCaptureRow row;
  const _TimedRow({required this.at, required this.row});
}

class _Accumulator {
  int samples = 0;
  int frames = 0;
  int channelReadings = 0;
  double delta = 0, theta = 0, alpha = 0, betaLow = 0, betaHigh = 0, gamma = 0;
  double symmetrySum = 0;
  int symmetryCount = 0;
}

class _Segment {
  final String? practiceSessionId;
  final DateTime startedAt;
  final Map<String, dynamic> Function()? contextSampler;
  final EegDeviceInfo? device;
  final bool fromRecording;
  final context = <EegContextSample>[];
  final voice = <EegVoiceEvent>[];
  final markers = <EegMarker>[];
  final contactChanges = <EegContactChange>[];
  final alerts = <EegAlertNote>[];
  List<String> lastExcluded;

  _Segment({
    required this.practiceSessionId,
    required this.startedAt,
    required this.contextSampler,
    required this.device,
    required List<String> initialExcluded,
    required this.fromRecording,
  }) : lastExcluded = List.of(initialExcluded) {
    if (initialExcluded.isNotEmpty) {
      contactChanges.add(EegContactChange(t: 0, excluded: List.of(initialExcluded)));
    }
  }
}

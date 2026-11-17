import 'dart:collection';
import 'dart:typed_data';

import '../../domain/models/eeg_band_power.dart';
import '../../domain/models/eeg_channel_info.dart';
import '../../domain/models/eeg_sample.dart';
import '../../domain/use_cases/eeg_processor_service.dart';
import 'eeg_ring_buffer.dart';
import 'eeg_signal_processor.dart';

/// Sliding-window spectral analysis over a raw stream, for devices that
/// do not compute band powers themselves.
///
/// Keeps the last [window] of samples and, every [hop], hands the window
/// to the [EegProcessorService]. With the defaults (1 s / 250 ms) a 256 Hz
/// headset yields four band-power frames per second from a 256-sample
/// window — the same cadence Cortex uses for its `pow` stream.
class EegBandPowerDeriver {
  final EegProcessorService processor;
  final Duration window;
  final Duration hop;

  // Zero-GC fast path for the stock EegSignalProcessor: contiguous Float64List
  // ring buffers per electrode instead of retaining boxed EegSample maps.
  final _channelRings = <String, EegFloat64RingBuffer>{};
  final _channelScratch = <String, Float64List>{};
  int _bufferedCount = 0;

  // Fallback queue used only when a custom EegProcessorService implementation
  // (e.g. test mock) requires List<EegSample>.
  final _fallbackBuffer = ListQueue<EegSample>();
  int _sinceLastEmit = 0;

  EegBandPowerDeriver({
    required this.processor,
    this.window = const Duration(seconds: 1),
    this.hop = const Duration(milliseconds: 250),
  });

  void reset() {
    for (final ring in _channelRings.values) {
      ring.clear();
    }
    _bufferedCount = 0;
    _fallbackBuffer.clear();
    _sinceLastEmit = 0;
  }

  /// Feeds one sample. Returns a band-power frame when a hop boundary is
  /// crossed and at least half a window has accumulated; otherwise null.
  List<EegBandPower>? push(
    EegSample sample,
    List<EegChannelInfo> channels,
    int sampleRate,
  ) {
    final windowSamples = _samplesFor(window, sampleRate);
    final hopSamples = _samplesFor(hop, sampleRate);

    final directProcessor =
        processor is EegSignalProcessor ? processor as EegSignalProcessor : null;

    if (directProcessor != null) {
      for (final ch in channels) {
        final label = ch.name;
        final ring = _channelRings.putIfAbsent(
          label,
          () => EegFloat64RingBuffer(windowSamples),
        )..ensureCapacity(windowSamples);
        ring.push(sample.channels[label] ?? 0.0);
      }
      if (_bufferedCount < windowSamples) _bufferedCount++;
      _sinceLastEmit++;

      if (_sinceLastEmit < hopSamples || _bufferedCount < windowSamples ~/ 2) {
        return null;
      }
      _sinceLastEmit = 0;

      final order = <String>[];
      final windows = <String, List<double>>{};
      for (final ch in channels) {
        final label = ch.name;
        final ring = _channelRings[label];
        if (ring == null || ring.isEmpty) continue;
        var scratch = _channelScratch[label];
        if (scratch == null || scratch.length != ring.length) {
          scratch = Float64List(ring.length);
          _channelScratch[label] = scratch;
        }
        windows[label] = ring.toFloat64List(scratch);
        order.add(label);
      }
      final frame = directProcessor.extractBandPowerFromWindows(
        windows,
        order,
        sampleRate.toDouble(),
      );
      return frame.isEmpty ? null : frame;
    }

    _fallbackBuffer.addLast(sample);
    while (_fallbackBuffer.length > windowSamples) {
      _fallbackBuffer.removeFirst();
    }
    _sinceLastEmit++;

    if (_sinceLastEmit < hopSamples ||
        _fallbackBuffer.length < windowSamples ~/ 2) {
      return null;
    }
    _sinceLastEmit = 0;

    final frame = processor.extractBandPower(
      _fallbackBuffer.toList(),
      channels,
      sampleRate: sampleRate.toDouble(),
    );
    return frame.isEmpty ? null : frame;
  }

  static int _samplesFor(Duration d, int sampleRate) {
    final n = (d.inMicroseconds * sampleRate / 1000000).round();
    return n < 1 ? 1 : n;
  }
}

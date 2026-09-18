import 'dart:collection';

import '../../domain/models/eeg_band_power.dart';
import '../../domain/models/eeg_channel_info.dart';
import '../../domain/models/eeg_sample.dart';
import '../../domain/use_cases/eeg_processor_service.dart';

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

  final _buffer = ListQueue<EegSample>();
  int _sinceLastEmit = 0;

  EegBandPowerDeriver({
    required this.processor,
    this.window = const Duration(seconds: 1),
    this.hop = const Duration(milliseconds: 250),
  });

  void reset() {
    _buffer.clear();
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

    _buffer.addLast(sample);
    while (_buffer.length > windowSamples) {
      _buffer.removeFirst();
    }
    _sinceLastEmit++;

    if (_sinceLastEmit < hopSamples || _buffer.length < windowSamples ~/ 2) {
      return null;
    }
    _sinceLastEmit = 0;

    final frame = processor.extractBandPower(_buffer.toList(), channels);
    return frame.isEmpty ? null : frame;
  }

  static int _samplesFor(Duration d, int sampleRate) {
    final n = (d.inMicroseconds * sampleRate / 1000000).round();
    return n < 1 ? 1 : n;
  }
}

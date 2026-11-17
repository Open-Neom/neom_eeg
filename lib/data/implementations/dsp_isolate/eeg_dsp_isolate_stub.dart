import '../../../domain/models/eeg_band_power.dart';
import '../../../domain/models/eeg_channel_catalog.dart';
import '../../../domain/models/eeg_sample.dart';
import '../eeg_coherence_tracker.dart';

/// Web/Wasm stub for [EegDspIsolateClient].
///
/// On Web (`dart.library.js_interop`), `dart:isolate` spawning is unavailable,
/// so [isSupported] is `false` and [EegHub] automatically runs the zero-GC
/// [Float64List] ring-buffer DSP pipeline synchronously.
class EegDspIsolateClient {
  final void Function(List<EegBandPower> frame) onBandPower;
  final void Function(EegPairCoherence coherence) onCoherence;

  EegDspIsolateClient({
    required this.onBandPower,
    required this.onCoherence,
  });

  static bool get isSupported => false;

  bool get isActive => false;

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
  }) async {}

  void updatePair(EegHemisphericPair? pair) {}

  void pushSample(EegSample sample) {}

  Future<void> flush() async {}

  Future<({double snr, double hz})?> computeFfr({
    required double stimulusHz,
    required List<String> excludedChannels,
  }) async =>
      null;

  void reset() {}

  Future<void> dispose() async {}
}

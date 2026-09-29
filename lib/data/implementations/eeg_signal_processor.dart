import '../../domain/models/eeg_asymmetry.dart';
import '../../domain/models/eeg_band_power.dart';
import '../../domain/models/eeg_calibration.dart';
import '../../domain/models/eeg_channel_info.dart';
import '../../domain/models/eeg_sample.dart';
import '../../domain/use_cases/eeg_processor_service.dart';
import 'eeg_spectral.dart';

/// Concrete signal processor.
///
/// Band powers come from [EegSpectral.powerSpectrum] (detrended, Hann
/// window, bands from [EegBands]) over the window the caller passes.
class EegSignalProcessor implements EegProcessorService {
  static const _frontalChannels = {'AF3', 'AF4', 'FP1', 'FP2', 'AF7', 'AF8'};
  static const _temporalLeft = {'T7', 'TP9'};
  static const _temporalRight = {'T8', 'TP10'};

  @override
  List<EegBandPower> extractBandPower(
    List<EegSample> samples,
    List<EegChannelInfo> channels, {
    double? sampleRate,
  }) {
    if (samples.isEmpty || channels.isEmpty) return [];

    final n = samples.length;
    final now = DateTime.now();
    // The driver knows its rate; timestamps are only the fallback, and n
    // samples span n − 1 intervals.
    final spanMs = samples.last.timestamp
        .difference(samples.first.timestamp)
        .inMicroseconds /
        1000.0;
    final rate = sampleRate ??
        (spanMs > 0 && n > 1 ? (n - 1) * 1000.0 / spanMs : 128.0);

    return channels.map((ch) {
      final signal = [
        for (final s in samples) (s.channels[ch.name] ?? 0.0),
      ];
      // Detrended, Hann-windowed spectrum (EegSpectral): electrode drift
      // and the DC offset no longer leak into delta/theta.
      final spectrum = EegSpectral.powerSpectrum(signal, rate);

      return EegBandPower(
        channel: ch.name,
        delta: spectrum.band('delta'),
        theta: spectrum.band('theta'),
        alpha: spectrum.band('alpha'),
        betaLow: spectrum.band('betaLow'),
        betaHigh: spectrum.band('betaHigh'),
        gamma: spectrum.band('gamma'),
        timestamp: now,
      );
    }).toList();
  }

  @override
  bool detectArtifact(EegSample sample, EegCalibration calibration) {
    final threshold = calibration.artifactThreshold;

    // Blink detection: frontal channel spike > 3x baseline
    for (final ch in sample.channels.entries) {
      if (_frontalChannels.contains(ch.key)) {
        final baseline =
            calibration.baselines['raw']?[ch.key] ?? threshold;
        if (ch.value.abs() > baseline * 3) {
          return true; // Blink artifact
        }
      }
    }

    // Jaw clench: simultaneous T7 + T8 spike
    final t7 = sample.channels.entries
        .where((e) => _temporalLeft.contains(e.key));
    final t8 = sample.channels.entries
        .where((e) => _temporalRight.contains(e.key));

    if (t7.isNotEmpty && t8.isNotEmpty) {
      final leftSpike = t7.any((e) => e.value.abs() > threshold * 2.5);
      final rightSpike = t8.any((e) => e.value.abs() > threshold * 2.5);
      if (leftSpike && rightSpike) return true; // Jaw clench
    }

    return false;
  }

  @override
  EegAsymmetry computeAsymmetry(
    EegBandPower left,
    EegBandPower right,
    String band,
  ) {
    final leftPower = _getBandValue(left, band);
    final rightPower = _getBandValue(right, band);

    return EegAsymmetry(
      band: band,
      leftChannel: left.channel,
      rightChannel: right.channel,
      leftPower: leftPower,
      rightPower: rightPower,
      timestamp: DateTime.now(),
    );
  }

  double _getBandValue(EegBandPower bp, String band) {
    switch (band) {
      case 'delta':
        return bp.delta;
      case 'theta':
        return bp.theta;
      case 'alpha':
        return bp.alpha;
      case 'betaLow':
        return bp.betaLow;
      case 'betaHigh':
        return bp.betaHigh;
      case 'gamma':
        return bp.gamma;
      default:
        return bp.alpha;
    }
  }
}

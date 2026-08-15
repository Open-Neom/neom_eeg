import 'dart:math';

import '../../domain/models/eeg_asymmetry.dart';
import '../../domain/models/eeg_band_power.dart';
import '../../domain/models/eeg_calibration.dart';
import '../../domain/models/eeg_channel_info.dart';
import '../../domain/models/eeg_sample.dart';
import '../../domain/use_cases/eeg_processor_service.dart';

/// Concrete signal processor using manual DFT on double arrays.
///
/// No external FFT dependency — computes DFT over 128-256 sample
/// windows and sums bins in standard EEG frequency ranges.
class EegSignalProcessor implements EegProcessorService {
  static const _frontalChannels = {'AF3', 'AF4', 'FP1', 'FP2', 'AF7', 'AF8'};
  static const _temporalLeft = {'T7', 'TP9'};
  static const _temporalRight = {'T8', 'TP10'};

  @override
  List<EegBandPower> extractBandPower(
    List<EegSample> samples,
    List<EegChannelInfo> channels,
  ) {
    if (samples.isEmpty || channels.isEmpty) return [];

    final n = samples.length;
    final now = DateTime.now();
    // Assume uniform sample rate — derive from timestamp span
    final spanMs = samples.last.timestamp
        .difference(samples.first.timestamp)
        .inMilliseconds;
    final sampleRate = spanMs > 0 ? (n * 1000.0 / spanMs) : 128.0;

    return channels.map((ch) {
      // Extract time series for this channel, replacing NaN/Infinity with 0.
      final signal = samples
          .map((s) {
            final v = s.channels[ch.name] ?? 0.0;
            return v.isFinite ? v : 0.0;
          })
          .toList();

      // Compute power spectrum via DFT
      final spectrum = _computePowerSpectrum(signal, sampleRate);

      return EegBandPower(
        channel: ch.name,
        delta: _sumBand(spectrum, 0.5, 4.0),
        theta: _sumBand(spectrum, 4.0, 8.0),
        alpha: _sumBand(spectrum, 8.0, 13.0),
        betaLow: _sumBand(spectrum, 13.0, 20.0),
        betaHigh: _sumBand(spectrum, 20.0, 30.0),
        gamma: _sumBand(spectrum, 30.0, 50.0),
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

  // --- DFT implementation ---

  /// Returns a map of frequency (Hz) → power for each DFT bin.
  Map<double, double> _computePowerSpectrum(
    List<double> signal,
    double sampleRate,
  ) {
    final n = signal.length;
    final spectrum = <double, double>{};
    final maxBin = n ~/ 2;

    for (var k = 1; k <= maxBin; k++) {
      var realPart = 0.0;
      var imagPart = 0.0;

      for (var i = 0; i < n; i++) {
        final angle = -2.0 * pi * k * i / n;
        realPart += signal[i] * cos(angle);
        imagPart += signal[i] * sin(angle);
      }

      final freq = k * sampleRate / n;
      final power = (realPart * realPart + imagPart * imagPart) / (n * n);
      spectrum[freq] = power;
    }

    return spectrum;
  }

  /// Sum power in a frequency band [lowHz, highHz).
  double _sumBand(Map<double, double> spectrum, double lowHz, double highHz) {
    var total = 0.0;
    for (final entry in spectrum.entries) {
      if (entry.key >= lowHz && entry.key < highHz) {
        total += entry.value;
      }
    }
    return total;
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

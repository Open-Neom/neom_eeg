import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:neom_eeg/data/implementations/eeg_signal_processor.dart';
import 'package:neom_eeg/domain/models/eeg_band_power.dart';
import 'package:neom_eeg/domain/models/eeg_calibration.dart';
import 'package:neom_eeg/domain/models/eeg_channel_info.dart';
import 'package:neom_eeg/domain/models/eeg_sample.dart';

void main() {
  late EegSignalProcessor processor;

  setUp(() {
    processor = EegSignalProcessor();
  });

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Build N samples at the given sampleRate for one channel.
  /// [generator] receives time t (seconds) and returns the signal value.
  List<EegSample> _buildSamples({
    required int count,
    required double sampleRate,
    required String channel,
    required double Function(double t) generator,
  }) {
    final base = DateTime(2025, 1, 1);
    return List.generate(count, (i) {
      final t = i / sampleRate;
      return EegSample(
        timestamp: base.add(Duration(
          microseconds: (t * 1e6).round(),
        )),
        channels: {channel: generator(t)},
        quality: {channel: 1.0},
      );
    });
  }

  /// Build multi-channel samples.
  List<EegSample> _buildMultiChannelSamples({
    required int count,
    required double sampleRate,
    required Map<String, double Function(double t)> generators,
  }) {
    final base = DateTime(2025, 1, 1);
    return List.generate(count, (i) {
      final t = i / sampleRate;
      return EegSample(
        timestamp: base.add(Duration(
          microseconds: (t * 1e6).round(),
        )),
        channels: generators.map((ch, gen) => MapEntry(ch, gen(t))),
        quality: generators.map((ch, _) => MapEntry(ch, 1.0)),
      );
    });
  }

  List<EegChannelInfo> _channels(List<String> names) =>
      names.map((n) => EegChannelInfo(
            name: n,
            positionX: 0.5,
            positionY: 0.5,
          )).toList();

  EegCalibration _calibration({
    double artifactThreshold = 50.0,
    double noiseFloor = 5.0,
    Map<String, Map<String, double>>? baselines,
  }) =>
      EegCalibration(
        baselines: baselines ?? {},
        noiseFloor: noiseFloor,
        artifactThreshold: artifactThreshold,
        calibratedAt: DateTime(2025),
      );

  // ---------------------------------------------------------------------------
  // GROUP 1: FFT / extractBandPower edge cases
  // ---------------------------------------------------------------------------

  group('extractBandPower', () {
    test('empty sample list returns empty', () {
      final result = processor.extractBandPower([], _channels(['AF3']));
      expect(result, isEmpty);
    });

    test('empty channel list returns empty', () {
      final samples = _buildSamples(
        count: 128,
        sampleRate: 128,
        channel: 'AF3',
        generator: (_) => 0.0,
      );
      final result = processor.extractBandPower(samples, []);
      expect(result, isEmpty);
    });

    test('single sample does not crash', () {
      // With 1 sample the timestamp span is 0ms => sampleRate defaults to 128.
      // DFT with n=1 should produce maxBin = 0, loop does not execute.
      final samples = _buildSamples(
        count: 1,
        sampleRate: 128,
        channel: 'Pz',
        generator: (_) => 10.0,
      );
      final result = processor.extractBandPower(samples, _channels(['Pz']));
      expect(result, hasLength(1));
      // All bands should be ~0 since no DFT bins computed.
      final bp = result.first;
      expect(bp.totalPower, closeTo(0.0, 1e-9));
    });

    test('all-zero values produce near-zero power in all bands', () {
      final samples = _buildSamples(
        count: 256,
        sampleRate: 256,
        channel: 'Pz',
        generator: (_) => 0.0,
      );
      final result = processor.extractBandPower(samples, _channels(['Pz']));
      final bp = result.first;
      expect(bp.delta, closeTo(0.0, 1e-9));
      expect(bp.theta, closeTo(0.0, 1e-9));
      expect(bp.alpha, closeTo(0.0, 1e-9));
      expect(bp.betaLow, closeTo(0.0, 1e-9));
      expect(bp.betaHigh, closeTo(0.0, 1e-9));
      expect(bp.gamma, closeTo(0.0, 1e-9));
    });

    test('DC offset (constant 100uV) produces power only in DC/delta', () {
      // A constant signal = DC component. DFT bin k=0 is not computed
      // (loop starts at k=1), but the lowest freq bin (k=1) at 1Hz
      // falls in delta (0.5-4 Hz). Because the signal is constant,
      // DFT at k>=1 should yield near-zero. Let's verify.
      final samples = _buildSamples(
        count: 256,
        sampleRate: 256,
        channel: 'Pz',
        generator: (_) => 100.0,
      );
      final result = processor.extractBandPower(samples, _channels(['Pz']));
      final bp = result.first;
      // Constant signal has zero power in ALL non-DC bins.
      // Since k=0 is skipped, total power should be ~0.
      expect(bp.totalPower, closeTo(0.0, 1e-3));
    });

    test('pure 10Hz sine wave produces dominant alpha band', () {
      const sampleRate = 256.0;
      const n = 256;
      final samples = _buildSamples(
        count: n,
        sampleRate: sampleRate,
        channel: 'Pz',
        generator: (t) => 20.0 * sin(2 * pi * 10.0 * t),
      );
      final result = processor.extractBandPower(samples, _channels(['Pz']));
      final bp = result.first;

      // Alpha (8-13 Hz) should dominate.
      expect(bp.alpha, greaterThan(bp.delta));
      expect(bp.alpha, greaterThan(bp.theta));
      expect(bp.alpha, greaterThan(bp.betaLow));
      expect(bp.alpha, greaterThan(bp.betaHigh));
      expect(bp.alpha, greaterThan(bp.gamma));
      expect(bp.dominantBand, equals('alpha'));
    });

    test('pure 40Hz sine wave produces dominant gamma band', () {
      const sampleRate = 256.0;
      const n = 256;
      final samples = _buildSamples(
        count: n,
        sampleRate: sampleRate,
        channel: 'Pz',
        generator: (t) => 15.0 * sin(2 * pi * 40.0 * t),
      );
      final result = processor.extractBandPower(samples, _channels(['Pz']));
      final bp = result.first;

      expect(bp.gamma, greaterThan(bp.delta));
      expect(bp.gamma, greaterThan(bp.theta));
      expect(bp.gamma, greaterThan(bp.alpha));
      expect(bp.gamma, greaterThan(bp.betaLow));
      expect(bp.gamma, greaterThan(bp.betaHigh));
      expect(bp.dominantBand, equals('gamma'));
    });

    test('mixed 10Hz + 40Hz sine has both alpha and gamma present', () {
      const sampleRate = 256.0;
      const n = 256;
      final samples = _buildSamples(
        count: n,
        sampleRate: sampleRate,
        channel: 'Pz',
        generator: (t) =>
            20.0 * sin(2 * pi * 10.0 * t) + 15.0 * sin(2 * pi * 40.0 * t),
      );
      final result = processor.extractBandPower(samples, _channels(['Pz']));
      final bp = result.first;

      // Both alpha and gamma should be significantly above other bands.
      expect(bp.alpha, greaterThan(bp.delta));
      expect(bp.alpha, greaterThan(bp.theta));
      expect(bp.gamma, greaterThan(bp.delta));
      expect(bp.gamma, greaterThan(bp.theta));
      // Alpha should be larger (amplitude 20 vs 15) but both nonzero.
      expect(bp.alpha, greaterThan(0.1));
      expect(bp.gamma, greaterThan(0.1));
    });

    test('very high amplitude samples (+-1000uV) do not overflow', () {
      const sampleRate = 128.0;
      const n = 128;
      final samples = _buildSamples(
        count: n,
        sampleRate: sampleRate,
        channel: 'Pz',
        generator: (t) => 1000.0 * sin(2 * pi * 10.0 * t),
      );
      final result = processor.extractBandPower(samples, _channels(['Pz']));
      final bp = result.first;

      expect(bp.alpha.isFinite, isTrue);
      expect(bp.alpha, greaterThan(0));
      expect(bp.totalPower.isFinite, isTrue);
    });

    test('NaN values in samples are handled gracefully', () {
      // BUG FINDER: NaN in signal can propagate through DFT as NaN.
      // cos(NaN)*NaN = NaN, summing NaN gives NaN.
      // The processor should either filter them out or the test reveals the bug.
      final base = DateTime(2025, 1, 1);
      final samples = List.generate(128, (i) {
        final t = i / 128.0;
        final value = i == 64 ? double.nan : 10.0 * sin(2 * pi * 10.0 * t);
        return EegSample(
          timestamp: base.add(Duration(microseconds: (t * 1e6).round())),
          channels: {'Pz': value},
          quality: {'Pz': 1.0},
        );
      });

      final result = processor.extractBandPower(samples, _channels(['Pz']));
      final bp = result.first;

      // If NaN propagates, all band powers will be NaN — this IS a bug.
      // The test documents the expected correct behavior: finite values.
      expect(bp.alpha.isNaN, isFalse,
          reason: 'NaN in samples should not corrupt band power output');
      expect(bp.totalPower.isFinite, isTrue,
          reason: 'totalPower should remain finite despite NaN input');
    });

    test('negative timestamps do not crash the DFT', () {
      // Timestamps before epoch: still computes a valid span.
      final base = DateTime(1969, 1, 1);
      final samples = List.generate(128, (i) {
        final t = i / 128.0;
        return EegSample(
          timestamp: base.add(Duration(microseconds: (t * 1e6).round())),
          channels: {'Pz': 10.0 * sin(2 * pi * 10.0 * t)},
          quality: {'Pz': 1.0},
        );
      });

      expect(
        () => processor.extractBandPower(samples, _channels(['Pz'])),
        returnsNormally,
      );
    });

    test('channel name mismatch between samples and channelInfo', () {
      // Samples have channel 'Pz' but channelInfo asks for 'AF3'.
      // Should produce zero power for 'AF3' (fallback to 0.0 in map lookup).
      final samples = _buildSamples(
        count: 128,
        sampleRate: 128,
        channel: 'Pz',
        generator: (t) => 20.0 * sin(2 * pi * 10.0 * t),
      );
      final result = processor.extractBandPower(samples, _channels(['AF3']));

      expect(result, hasLength(1));
      expect(result.first.channel, equals('AF3'));
      // Signal for AF3 was all zeros (missing from samples map).
      expect(result.first.totalPower, closeTo(0.0, 1e-9));
    });

    test('two samples with identical timestamps handle sampleRate fallback', () {
      // spanMs = 0 => sampleRate defaults to 128.
      final base = DateTime(2025, 1, 1);
      final samples = List.generate(64, (_) => EegSample(
        timestamp: base,
        channels: {'Pz': 10.0},
        quality: {'Pz': 1.0},
      ));

      expect(
        () => processor.extractBandPower(samples, _channels(['Pz'])),
        returnsNormally,
      );
    });

    test('large window (1024 samples) does not cause performance crash', () {
      // DFT is O(n^2), 1024 samples = 1M operations. Should still complete.
      const sampleRate = 256.0;
      const n = 1024;
      final samples = _buildSamples(
        count: n,
        sampleRate: sampleRate,
        channel: 'Pz',
        generator: (t) => 10.0 * sin(2 * pi * 10.0 * t),
      );
      final result = processor.extractBandPower(samples, _channels(['Pz']));
      expect(result, hasLength(1));
      expect(result.first.alpha, greaterThan(0));
    });

    test('pure 2Hz sine produces dominant delta band', () {
      const sampleRate = 256.0;
      const n = 256;
      final samples = _buildSamples(
        count: n,
        sampleRate: sampleRate,
        channel: 'Pz',
        generator: (t) => 20.0 * sin(2 * pi * 2.0 * t),
      );
      final result = processor.extractBandPower(samples, _channels(['Pz']));
      expect(result.first.dominantBand, equals('delta'));
    });

    test('pure 6Hz sine produces dominant theta band', () {
      const sampleRate = 256.0;
      const n = 256;
      final samples = _buildSamples(
        count: n,
        sampleRate: sampleRate,
        channel: 'Pz',
        generator: (t) => 20.0 * sin(2 * pi * 6.0 * t),
      );
      final result = processor.extractBandPower(samples, _channels(['Pz']));
      expect(result.first.dominantBand, equals('theta'));
    });

    test('pure 15Hz sine produces dominant betaLow band', () {
      const sampleRate = 256.0;
      const n = 256;
      final samples = _buildSamples(
        count: n,
        sampleRate: sampleRate,
        channel: 'Pz',
        generator: (t) => 20.0 * sin(2 * pi * 15.0 * t),
      );
      final result = processor.extractBandPower(samples, _channels(['Pz']));
      expect(result.first.dominantBand, equals('betaLow'));
    });

    test('pure 25Hz sine produces dominant betaHigh band', () {
      const sampleRate = 256.0;
      const n = 256;
      final samples = _buildSamples(
        count: n,
        sampleRate: sampleRate,
        channel: 'Pz',
        generator: (t) => 20.0 * sin(2 * pi * 25.0 * t),
      );
      final result = processor.extractBandPower(samples, _channels(['Pz']));
      expect(result.first.dominantBand, equals('betaHigh'));
    });

    test('multi-channel extraction returns one BandPower per channel', () {
      final samples = _buildMultiChannelSamples(
        count: 256,
        sampleRate: 256,
        generators: {
          'AF3': (t) => 20.0 * sin(2 * pi * 10.0 * t), // alpha
          'T7': (t) => 20.0 * sin(2 * pi * 6.0 * t),   // theta
        },
      );
      final channels = _channels(['AF3', 'T7']);
      final result = processor.extractBandPower(samples, channels);

      expect(result, hasLength(2));
      expect(result[0].channel, 'AF3');
      expect(result[0].dominantBand, 'alpha');
      expect(result[1].channel, 'T7');
      expect(result[1].dominantBand, 'theta');
    });
  });

  // ---------------------------------------------------------------------------
  // GROUP 2: Artifact detection
  // ---------------------------------------------------------------------------

  group('detectArtifact', () {
    test('frontal channel spike 5x baseline detects blink', () {
      final sample = EegSample(
        timestamp: DateTime(2025),
        channels: {'AF3': 250.0, 'T7': 5.0, 'Pz': 5.0, 'T8': 5.0, 'AF4': 5.0},
        quality: {'AF3': 1.0, 'T7': 1.0, 'Pz': 1.0, 'T8': 1.0, 'AF4': 1.0},
      );
      final cal = _calibration(
        artifactThreshold: 50.0,
        baselines: {'raw': {'AF3': 50.0, 'AF4': 50.0, 'T7': 50.0, 'T8': 50.0}},
      );
      expect(processor.detectArtifact(sample, cal), isTrue);
    });

    test('frontal channel spike 2x baseline does NOT flag blink', () {
      final sample = EegSample(
        timestamp: DateTime(2025),
        channels: {'AF3': 100.0, 'T7': 5.0, 'Pz': 5.0, 'T8': 5.0, 'AF4': 5.0},
        quality: {'AF3': 1.0, 'T7': 1.0, 'Pz': 1.0, 'T8': 1.0, 'AF4': 1.0},
      );
      final cal = _calibration(
        artifactThreshold: 50.0,
        baselines: {'raw': {'AF3': 50.0, 'AF4': 50.0, 'T7': 50.0, 'T8': 50.0}},
      );
      // 100 is NOT > 50*3 = 150. So no blink.
      expect(processor.detectArtifact(sample, cal), isFalse);
    });

    test('simultaneous T7+T8 spike detects jaw clench', () {
      final sample = EegSample(
        timestamp: DateTime(2025),
        channels: {'AF3': 5.0, 'T7': 200.0, 'Pz': 5.0, 'T8': 200.0, 'AF4': 5.0},
        quality: {'AF3': 1.0, 'T7': 1.0, 'Pz': 1.0, 'T8': 1.0, 'AF4': 1.0},
      );
      // threshold * 2.5 = 50 * 2.5 = 125. 200 > 125. Both sides spike.
      final cal = _calibration(artifactThreshold: 50.0);
      expect(processor.detectArtifact(sample, cal), isTrue);
    });

    test('T7 spike without T8 does NOT flag jaw clench', () {
      final sample = EegSample(
        timestamp: DateTime(2025),
        channels: {'AF3': 5.0, 'T7': 200.0, 'Pz': 5.0, 'T8': 5.0, 'AF4': 5.0},
        quality: {'AF3': 1.0, 'T7': 1.0, 'Pz': 1.0, 'T8': 1.0, 'AF4': 1.0},
      );
      final cal = _calibration(artifactThreshold: 50.0);
      // T7 spikes, T8 does not. Not frontal so no blink. Should be false.
      expect(processor.detectArtifact(sample, cal), isFalse);
    });

    test('spike on non-frontal channel does NOT flag blink', () {
      final sample = EegSample(
        timestamp: DateTime(2025),
        channels: {'Pz': 500.0},
        quality: {'Pz': 1.0},
      );
      final cal = _calibration(
        artifactThreshold: 50.0,
        baselines: {'raw': {'Pz': 50.0}},
      );
      // Pz is not frontal, not temporal. No artifact.
      expect(processor.detectArtifact(sample, cal), isFalse);
    });

    test('no baseline provided for frontal channel uses threshold as fallback', () {
      // When baselines['raw'] has no entry for the channel, fallback is threshold.
      // AF3 value 160 vs threshold 50 * 3 = 150. 160 > 150 → blink.
      final sample = EegSample(
        timestamp: DateTime(2025),
        channels: {'AF3': 160.0},
        quality: {'AF3': 1.0},
      );
      final cal = _calibration(artifactThreshold: 50.0);
      expect(processor.detectArtifact(sample, cal), isTrue);
    });

    test('zero artifact threshold causes division-by-zero risk in jaw clench', () {
      // threshold * 2.5 = 0. Any value > 0 would spike.
      // This tests whether zero threshold is safe.
      final sample = EegSample(
        timestamp: DateTime(2025),
        channels: {'T7': 1.0, 'T8': 1.0},
        quality: {'T7': 1.0, 'T8': 1.0},
      );
      final cal = _calibration(artifactThreshold: 0.0);
      // 1.0 > 0.0 * 2.5 = 0.0 → true. Both sides. Jaw clench detected.
      // With threshold = 0, even tiny signals trigger. Not ideal but should not crash.
      expect(
        () => processor.detectArtifact(sample, cal),
        returnsNormally,
      );
      // Actually should be true since 1 > 0
      expect(processor.detectArtifact(sample, cal), isTrue);
    });

    test('zero baseline for frontal channel: division by zero risk', () {
      // baseline = 0. 0 * 3 = 0. Any value > 0 triggers blink.
      final sample = EegSample(
        timestamp: DateTime(2025),
        channels: {'AF3': 0.001},
        quality: {'AF3': 1.0},
      );
      final cal = _calibration(
        artifactThreshold: 50.0,
        baselines: {'raw': {'AF3': 0.0}},
      );
      // 0.001 > 0 * 3 = 0 → true. Blink with near-zero signal. Bug-ish behavior.
      expect(processor.detectArtifact(sample, cal), isTrue);
    });

    test('negative channel value triggers blink via abs()', () {
      // AF3 = -250. abs(-250) = 250 > 50*3 = 150 → blink.
      final sample = EegSample(
        timestamp: DateTime(2025),
        channels: {'AF3': -250.0},
        quality: {'AF3': 1.0},
      );
      final cal = _calibration(
        artifactThreshold: 50.0,
        baselines: {'raw': {'AF3': 50.0}},
      );
      expect(processor.detectArtifact(sample, cal), isTrue);
    });

    test('exactly at 3x threshold boundary does NOT flag blink', () {
      // AF3 = 150 exactly, baseline 50. 150 > 150 is false (not strictly greater).
      final sample = EegSample(
        timestamp: DateTime(2025),
        channels: {'AF3': 150.0},
        quality: {'AF3': 1.0},
      );
      final cal = _calibration(
        artifactThreshold: 50.0,
        baselines: {'raw': {'AF3': 50.0}},
      );
      expect(processor.detectArtifact(sample, cal), isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // GROUP 3: Asymmetry computation
  // ---------------------------------------------------------------------------

  group('computeAsymmetry', () {
    EegBandPower _bp(String ch, {double alpha = 0.0}) => EegBandPower(
          channel: ch,
          delta: 0, theta: 0, alpha: alpha, betaLow: 0, betaHigh: 0, gamma: 0,
          timestamp: DateTime(2025),
        );

    test('equal T7 T8 power: ratio 1.0, asymmetryIndex 0.0, not significant', () {
      final a = processor.computeAsymmetry(_bp('T7', alpha: 10), _bp('T8', alpha: 10), 'alpha');
      expect(a.ratio, closeTo(1.0, 1e-9));
      expect(a.asymmetryIndex, closeTo(0.0, 1e-9));
      expect(a.isSignificant, isFalse);
    });

    test('T7=0, T8>0: ratio 0, index -1.0, significant', () {
      final a = processor.computeAsymmetry(_bp('T7', alpha: 0), _bp('T8', alpha: 10), 'alpha');
      expect(a.ratio, closeTo(0.0, 1e-9));
      expect(a.asymmetryIndex, closeTo(-1.0, 1e-9));
      expect(a.isSignificant, isTrue);
    });

    test('both zero: no divide by zero, ratio infinity, index 0', () {
      final a = processor.computeAsymmetry(_bp('T7', alpha: 0), _bp('T8', alpha: 0), 'alpha');
      // ratio: rightPower=0 → double.infinity
      expect(a.ratio, equals(double.infinity));
      // asymmetryIndex: sum=0 → returns 0.0
      expect(a.asymmetryIndex, closeTo(0.0, 1e-9));
      expect(a.isSignificant, isFalse);
    });

    test('T7 much larger: index > 0.2, significant', () {
      final a = processor.computeAsymmetry(_bp('T7', alpha: 20), _bp('T8', alpha: 5), 'alpha');
      // index = (20-5)/(20+5) = 15/25 = 0.6
      expect(a.asymmetryIndex, closeTo(0.6, 1e-9));
      expect(a.isSignificant, isTrue);
    });

    test('negative power values: defensive handling', () {
      // Real sensors should not produce negative power, but the model allows it.
      final a = processor.computeAsymmetry(_bp('T7', alpha: -5), _bp('T8', alpha: 5), 'alpha');
      // ratio = -5/5 = -1.0
      expect(a.ratio, closeTo(-1.0, 1e-9));
      // index = (-5-5)/(-5+5) = -10/0 → asymmetryIndex returns 0 (sum==0 guard)
      expect(a.asymmetryIndex, closeTo(0.0, 1e-9));
    });

    test('unknown band name defaults to alpha', () {
      final left = EegBandPower(
        channel: 'T7', delta: 1, theta: 2, alpha: 10,
        betaLow: 3, betaHigh: 4, gamma: 5, timestamp: DateTime(2025),
      );
      final right = EegBandPower(
        channel: 'T8', delta: 1, theta: 2, alpha: 5,
        betaLow: 3, betaHigh: 4, gamma: 5, timestamp: DateTime(2025),
      );
      final a = processor.computeAsymmetry(left, right, 'nonexistent_band');
      // Should fallback to alpha via default case in _getBandValue.
      expect(a.leftPower, closeTo(10.0, 1e-9));
      expect(a.rightPower, closeTo(5.0, 1e-9));
    });

    test('asymmetry exactly at 0.2 boundary is NOT significant', () {
      // isSignificant = abs(index) > 0.2. At exactly 0.2 it should be false.
      // Need leftPower and rightPower such that (L-R)/(L+R) = 0.2 exactly.
      // L = 3, R = 2: (3-2)/(3+2) = 1/5 = 0.2
      final a = processor.computeAsymmetry(_bp('T7', alpha: 3), _bp('T8', alpha: 2), 'alpha');
      expect(a.asymmetryIndex, closeTo(0.2, 1e-9));
      expect(a.isSignificant, isFalse);
    });
  });
}

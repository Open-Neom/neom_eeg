import 'package:flutter_test/flutter_test.dart';
import 'package:neom_eeg/domain/models/eeg_asymmetry.dart';
import 'package:neom_eeg/domain/models/eeg_band_power.dart';

void main() {
  // ---------------------------------------------------------------------------
  // EegBandPower model tests
  // ---------------------------------------------------------------------------

  group('EegBandPower', () {
    test('dominantBand with all bands zero returns deterministic result', () {
      final bp = EegBandPower(
        channel: 'Pz',
        delta: 0, theta: 0, alpha: 0, betaLow: 0, betaHigh: 0, gamma: 0,
        timestamp: DateTime(2025),
      );
      // reduce with >= means first entry wins ties: 'delta'.
      expect(bp.dominantBand, isNotEmpty);
      // Should not crash.
      expect(bp.dominantBand, equals('delta'));
    });

    test('dominantBand with one band much higher returns correct band', () {
      final bp = EegBandPower(
        channel: 'Pz',
        delta: 1, theta: 1, alpha: 100, betaLow: 1, betaHigh: 1, gamma: 1,
        timestamp: DateTime(2025),
      );
      expect(bp.dominantBand, equals('alpha'));
    });

    test('dominantBand with two bands tied returns first in iteration order', () {
      // Both alpha and gamma are 50. Map iteration: delta, theta, alpha...
      // reduce picks a when a.value >= b.value, so 'alpha' should win (comes first).
      final bp = EegBandPower(
        channel: 'Pz',
        delta: 0, theta: 0, alpha: 50, betaLow: 0, betaHigh: 0, gamma: 50,
        timestamp: DateTime(2025),
      );
      expect(bp.dominantBand, equals('alpha'));
    });

    test('dominantBand: delta and theta tied, delta wins (first entry)', () {
      final bp = EegBandPower(
        channel: 'Pz',
        delta: 10, theta: 10, alpha: 0, betaLow: 0, betaHigh: 0, gamma: 0,
        timestamp: DateTime(2025),
      );
      expect(bp.dominantBand, equals('delta'));
    });

    test('totalPower is sum of all 6 bands', () {
      final bp = EegBandPower(
        channel: 'Pz',
        delta: 1, theta: 2, alpha: 3, betaLow: 4, betaHigh: 5, gamma: 6,
        timestamp: DateTime(2025),
      );
      expect(bp.totalPower, closeTo(21.0, 1e-9));
    });

    test('totalPower with negative values still sums correctly', () {
      final bp = EegBandPower(
        channel: 'Pz',
        delta: -1, theta: 2, alpha: -3, betaLow: 4, betaHigh: -5, gamma: 6,
        timestamp: DateTime(2025),
      );
      // -1+2-3+4-5+6 = 3
      expect(bp.totalPower, closeTo(3.0, 1e-9));
    });

    test('toJson -> fromJson round-trip produces identical values', () {
      final original = EegBandPower(
        channel: 'AF3',
        delta: 1.234,
        theta: 5.678,
        alpha: 9.012,
        betaLow: 3.456,
        betaHigh: 7.890,
        gamma: 2.345,
        timestamp: DateTime(2025, 6, 15, 10, 30, 0),
      );
      final json = original.toJson();
      final restored = EegBandPower.fromJson(json);

      expect(restored.channel, equals(original.channel));
      expect(restored.delta, closeTo(original.delta, 1e-9));
      expect(restored.theta, closeTo(original.theta, 1e-9));
      expect(restored.alpha, closeTo(original.alpha, 1e-9));
      expect(restored.betaLow, closeTo(original.betaLow, 1e-9));
      expect(restored.betaHigh, closeTo(original.betaHigh, 1e-9));
      expect(restored.gamma, closeTo(original.gamma, 1e-9));
      expect(restored.timestamp, equals(original.timestamp));
    });

    test('fromJson with integer values (num cast) works', () {
      final json = {
        'channel': 'Pz',
        'delta': 1,
        'theta': 2,
        'alpha': 3,
        'betaLow': 4,
        'betaHigh': 5,
        'gamma': 6,
        'timestamp': '2025-01-01T00:00:00.000',
      };
      final bp = EegBandPower.fromJson(json);
      expect(bp.delta, closeTo(1.0, 1e-9));
      expect(bp.gamma, closeTo(6.0, 1e-9));
    });

    test('fromJson with missing field throws (no defaults)', () {
      final json = {
        'channel': 'Pz',
        'delta': 1.0,
        // 'theta' missing
        'alpha': 3.0,
        'betaLow': 4.0,
        'betaHigh': 5.0,
        'gamma': 6.0,
        'timestamp': '2025-01-01T00:00:00.000',
      };
      // fromJson casts json['theta'] as num → null, toDouble() → TypeError.
      expect(() => EegBandPower.fromJson(json), throwsA(isA<TypeError>()));
    });

    test('fromJson with negative values stores them as-is', () {
      final json = {
        'channel': 'Pz',
        'delta': -5.0,
        'theta': -3.0,
        'alpha': -1.0,
        'betaLow': -2.0,
        'betaHigh': -4.0,
        'gamma': -6.0,
        'timestamp': '2025-01-01T00:00:00.000',
      };
      final bp = EegBandPower.fromJson(json);
      expect(bp.delta, closeTo(-5.0, 1e-9));
      expect(bp.gamma, closeTo(-6.0, 1e-9));
    });

    test('channel name empty string does not crash', () {
      final bp = EegBandPower(
        channel: '',
        delta: 0, theta: 0, alpha: 0, betaLow: 0, betaHigh: 0, gamma: 0,
        timestamp: DateTime(2025),
      );
      expect(bp.channel, equals(''));
      expect(bp.totalPower, closeTo(0.0, 1e-9));
      expect(bp.dominantBand, isNotEmpty); // 'delta'
    });
  });

  // ---------------------------------------------------------------------------
  // EegAsymmetry model tests
  // ---------------------------------------------------------------------------

  group('EegAsymmetry', () {
    test('ratio when rightPower is zero returns infinity', () {
      final a = EegAsymmetry(
        band: 'alpha',
        leftChannel: 'T7', rightChannel: 'T8',
        leftPower: 10.0, rightPower: 0.0,
        timestamp: DateTime(2025),
      );
      expect(a.ratio, equals(double.infinity));
    });

    test('ratio when both are zero returns infinity', () {
      final a = EegAsymmetry(
        band: 'alpha',
        leftChannel: 'T7', rightChannel: 'T8',
        leftPower: 0.0, rightPower: 0.0,
        timestamp: DateTime(2025),
      );
      // rightPower == 0 → double.infinity regardless of leftPower.
      expect(a.ratio, equals(double.infinity));
    });

    test('asymmetryIndex when both zero returns 0.0 not NaN', () {
      final a = EegAsymmetry(
        band: 'alpha',
        leftChannel: 'T7', rightChannel: 'T8',
        leftPower: 0.0, rightPower: 0.0,
        timestamp: DateTime(2025),
      );
      expect(a.asymmetryIndex, closeTo(0.0, 1e-9));
      expect(a.asymmetryIndex.isNaN, isFalse);
    });

    test('isSignificant at exactly 0.2 boundary is false (> not >=)', () {
      // L=3, R=2 → index = (3-2)/(3+2) = 0.2 exactly.
      final a = EegAsymmetry(
        band: 'alpha',
        leftChannel: 'T7', rightChannel: 'T8',
        leftPower: 3.0, rightPower: 2.0,
        timestamp: DateTime(2025),
      );
      expect(a.asymmetryIndex, closeTo(0.2, 1e-9));
      expect(a.isSignificant, isFalse);
    });

    test('isSignificant at 0.201 is true', () {
      // Need (L-R)/(L+R) slightly > 0.2.
      // L=3.01, R=2 → (1.01)/(5.01) ≈ 0.2016
      final a = EegAsymmetry(
        band: 'alpha',
        leftChannel: 'T7', rightChannel: 'T8',
        leftPower: 3.01, rightPower: 2.0,
        timestamp: DateTime(2025),
      );
      expect(a.asymmetryIndex, greaterThan(0.2));
      expect(a.isSignificant, isTrue);
    });

    test('negative asymmetry (right dominant) is also significant', () {
      // L=2, R=3 → index = (2-3)/(2+3) = -0.2
      // abs(-0.2) > 0.2? No, it's exactly 0.2. Not significant.
      // L=1, R=3 → index = (1-3)/(1+3) = -0.5. abs(-0.5) > 0.2 → true.
      final a = EegAsymmetry(
        band: 'alpha',
        leftChannel: 'T7', rightChannel: 'T8',
        leftPower: 1.0, rightPower: 3.0,
        timestamp: DateTime(2025),
      );
      expect(a.asymmetryIndex, lessThan(-0.2));
      expect(a.isSignificant, isTrue);
    });

    test('toJson -> fromJson round-trip', () {
      final original = EegAsymmetry(
        band: 'theta',
        leftChannel: 'T7', rightChannel: 'T8',
        leftPower: 12.5, rightPower: 8.3,
        timestamp: DateTime(2025, 3, 15, 14, 30),
      );
      final restored = EegAsymmetry.fromJson(original.toJson());
      expect(restored.band, equals('theta'));
      expect(restored.leftPower, closeTo(12.5, 1e-9));
      expect(restored.rightPower, closeTo(8.3, 1e-9));
      expect(restored.leftChannel, equals('T7'));
      expect(restored.rightChannel, equals('T8'));
    });

    test('ratio with negative leftPower is negative', () {
      final a = EegAsymmetry(
        band: 'alpha',
        leftChannel: 'T7', rightChannel: 'T8',
        leftPower: -10.0, rightPower: 5.0,
        timestamp: DateTime(2025),
      );
      expect(a.ratio, closeTo(-2.0, 1e-9));
    });
  });
}

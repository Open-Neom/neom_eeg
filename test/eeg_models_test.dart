// Tests for `EegSample`, `EegMentalState`, `EegAsymmetry`.

import 'package:flutter_test/flutter_test.dart';
import 'package:neom_eeg/domain/models/eeg_sample.dart';
import 'package:neom_eeg/domain/models/eeg_mental_state.dart';
import 'package:neom_eeg/domain/models/eeg_asymmetry.dart';

void main() {
  group('EegSample — round-trip', () {
    test('preserva timestamp + channels + quality', () {
      final original = EegSample(
        timestamp: DateTime.utc(2024, 1, 15, 12),
        channels: {'AF3': 0.5, 'AF4': -0.3},
        quality: {'AF3': 1.0, 'AF4': 0.9},
      );
      final restored = EegSample.fromJson(original.toJson());
      expect(restored.timestamp, original.timestamp);
      expect(restored.channels, original.channels);
      expect(restored.quality, original.quality);
    });

    test('toJson serializa timestamp como ISO 8601', () {
      final s = EegSample(
        timestamp: DateTime.utc(2024, 1, 15, 12),
        channels: {},
        quality: {},
      );
      expect(s.toJson()['timestamp'], '2024-01-15T12:00:00.000Z');
    });
  });

  group('EegMentalState — round-trip', () {
    test('preserva todas las métricas', () {
      final original = EegMentalState(
        engagement: 0.75,
        relaxation: 0.40,
        stress: 0.20,
        focus: 0.85,
        excitement: 0.55,
        timestamp: DateTime.utc(2024, 6, 1, 10),
      );
      final restored = EegMentalState.fromJson(original.toJson());
      expect(restored.engagement, original.engagement);
      expect(restored.relaxation, original.relaxation);
      expect(restored.stress, original.stress);
      expect(restored.focus, original.focus);
      expect(restored.excitement, original.excitement);
      expect(restored.timestamp, original.timestamp);
    });

    test('valores num int se convierten a double', () {
      final s = EegMentalState.fromJson({
        'engagement': 1,
        'relaxation': 0,
        'stress': 0,
        'focus': 0,
        'excitement': 0,
        'timestamp': '2024-01-01T00:00:00Z',
      });
      expect(s.engagement, 1.0);
    });
  });

  group('EegAsymmetry — computed', () {
    test('ratio = leftPower / rightPower', () {
      final a = EegAsymmetry(
        band: 'alpha',
        leftChannel: 'AF3',
        rightChannel: 'AF4',
        leftPower: 10,
        rightPower: 5,
        timestamp: DateTime.now(),
      );
      expect(a.ratio, 2.0);
    });

    test('ratio: rightPower 0 → infinity', () {
      final a = EegAsymmetry(
        band: 'alpha',
        leftChannel: 'AF3', rightChannel: 'AF4',
        leftPower: 10, rightPower: 0,
        timestamp: DateTime.now(),
      );
      expect(a.ratio, double.infinity);
    });

    test('asymmetryIndex = (left - right) / (left + right)', () {
      final a = EegAsymmetry(
        band: 'alpha',
        leftChannel: 'AF3', rightChannel: 'AF4',
        leftPower: 10, rightPower: 5,
        timestamp: DateTime.now(),
      );
      // (10 - 5) / (10 + 5) = 0.333...
      expect(a.asymmetryIndex, closeTo(1 / 3, 0.001));
    });

    test('asymmetryIndex: ambos 0 → 0', () {
      final a = EegAsymmetry(
        band: 'alpha',
        leftChannel: 'AF3', rightChannel: 'AF4',
        leftPower: 0, rightPower: 0,
        timestamp: DateTime.now(),
      );
      expect(a.asymmetryIndex, 0);
    });

    test('asymmetryIndex en rango [-1, 1]', () {
      // Solo izquierdo: (10 - 0) / 10 = 1
      final extreme = EegAsymmetry(
        band: 'alpha',
        leftChannel: 'AF3', rightChannel: 'AF4',
        leftPower: 10, rightPower: 0,
        timestamp: DateTime.now(),
      );
      expect(extreme.asymmetryIndex, 1.0);
    });

    test('isSignificant: > 20% de asimetría', () {
      // 0.25 → significativa
      final a = EegAsymmetry(
        band: 'alpha',
        leftChannel: 'AF3', rightChannel: 'AF4',
        leftPower: 1.5, rightPower: 1.0, // (0.5 / 2.5 = 0.2) — el límite
        timestamp: DateTime.now(),
      );
      // 0.5/2.5 = 0.2, abs() = 0.2 → NO > 0.2
      expect(a.isSignificant, isFalse);

      // (1.6 - 1.0) / (1.6 + 1.0) = 0.6/2.6 ≈ 0.231 → significativa
      final sig = EegAsymmetry(
        band: 'alpha',
        leftChannel: 'AF3', rightChannel: 'AF4',
        leftPower: 1.6, rightPower: 1.0,
        timestamp: DateTime.now(),
      );
      expect(sig.isSignificant, isTrue);
    });

    test('round-trip preserva campos', () {
      final original = EegAsymmetry(
        band: 'alpha',
        leftChannel: 'AF3', rightChannel: 'AF4',
        leftPower: 10, rightPower: 5,
        timestamp: DateTime.utc(2024, 1, 15, 12),
      );
      final restored = EegAsymmetry.fromJson(original.toJson());
      expect(restored.band, 'alpha');
      expect(restored.leftPower, 10.0);
      expect(restored.rightPower, 5.0);
    });
  });
}

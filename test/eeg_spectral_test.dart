import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:neom_eeg/data/hub/eeg_driver_registry.dart';
import 'package:neom_eeg/data/hub/eeg_hub.dart';
import 'package:neom_eeg/data/implementations/eeg_coherence_tracker.dart';
import 'package:neom_eeg/data/implementations/eeg_spectral.dart';
import 'package:neom_eeg/domain/enums/eeg_device_type.dart';
import 'package:neom_eeg/domain/enums/eeg_vendor.dart';
import 'package:neom_eeg/domain/models/eeg_capabilities.dart';
import 'package:neom_eeg/domain/models/eeg_device_status.dart';
import 'package:neom_eeg/domain/models/eeg_sample.dart';

import 'support/fake_eeg_driver.dart';

const fs = 128.0;

List<double> signal(int n, double Function(double t) f) => [for (var i = 0; i < n; i++) f(i / fs)];

void main() {
  final rnd = Random(21);
  double noise() => sqrt(-2 * log(1 - rnd.nextDouble())) * cos(2 * pi * rnd.nextDouble());

  group('power spectrum', () {
    test('a tone keeps its power (A²/4) under the Hann window', () {
      final x = signal(256, (t) => 2 * sin(2 * pi * 10 * t));
      final s = EegSpectral.powerSpectrum(x, fs);
      expect(s.band('alpha'), closeTo(1.0, 0.05));
      expect(s.band('theta'), lessThan(0.01));
    });

    test('DC offset and drift do not leak into delta', () {
      // Emotiv raw sits near 4200 µV and drifts.
      final x = signal(256, (t) => 4200 + 40 * t + 2 * sin(2 * pi * 10 * t));
      final s = EegSpectral.powerSpectrum(x, fs);
      expect(s.band('delta'), lessThan(0.05 * s.band('alpha')));
    });
  });

  group('coherence', () {
    test('a shared rhythm is coherent in its band only', () {
      final common = signal(1024, (t) => 3 * sin(2 * pi * 10 * t));
      final x = [for (final v in common) v + noise()];
      final y = [for (final v in common) v + noise()];
      final c = EegSpectral.coherence(x, y, fs);
      expect(c.segments, 15);
      expect(c.significance, closeTo(1 - pow(0.05, 1 / 7), 1e-9));
      expect(c.band('alpha'), greaterThan(0.5));
      expect(c.band('theta'), lessThan(c.bandSignificance('theta')!));
      // A band average has a narrower chance distribution than one bin.
      expect(c.bandSignificance('alpha')!, lessThan(c.significance));
    });

    test('independent signals stay under the chance threshold', () {
      // 95 % threshold: over 40 draws, at most a few may cross it.
      var crossings = 0;
      for (var trial = 0; trial < 40; trial++) {
        final x = [for (var i = 0; i < 1024; i++) noise()];
        final y = [for (var i = 0; i < 1024; i++) noise()];
        final c = EegSpectral.coherence(x, y, fs);
        if (c.band('alpha')! > c.bandSignificance('alpha')!) crossings++;
      }
      expect(crossings, lessThanOrEqualTo(6));
    });

    test('imaginary coherence ignores zero-lag coupling and sees lagged coupling', () {
      final common = signal(1024, (t) => 3 * sin(2 * pi * 10 * t));
      final lagged = signal(1024, (t) => 3 * sin(2 * pi * 10 * t - pi / 2));
      final x = [for (final v in common) v + 0.5 * noise()];
      final zeroLag = [for (final v in common) v + 0.5 * noise()];
      final quarter = [for (final v in lagged) v + 0.5 * noise()];
      final same = EegSpectral.coherence(x, zeroLag, fs);
      final shifted = EegSpectral.coherence(x, quarter, fs);
      expect(same.band('alpha'), greaterThan(0.5));
      expect(shifted.band('alpha'), greaterThan(0.5));
      expect(same.imaginaryBand('alpha'), lessThan(0.15));
      expect(shifted.imaginaryBand('alpha'), greaterThan(0.4));
    });

    test('flat signals have undefined coherence, not zero', () {
      final flat = List<double>.filled(512, 4200);
      final c = EegSpectral.coherence(flat, flat, fs);
      expect(c.band('alpha'), isNull);
    });
  });

  group('frequency-following response', () {
    test('a 6 Hz response stands out of its neighbours; a quiet frequency does not', () {
      final x = signal(1024, (t) => 1.0 * sin(2 * pi * 6 * t))
          .map((v) => v + 3 * noise())
          .toList();
      expect(EegSpectral.frequencyFollowingSnr(x, fs, 6)!, greaterThan(2));
      expect(EegSpectral.frequencyFollowingSnr(x, fs, 9)!, lessThan(2));
    });

    test('needs a window long enough to resolve the stimulus', () {
      final short = signal(256, (t) => sin(2 * pi * 6 * t)); // 2 s → 0.5 Hz bins
      expect(EegSpectral.frequencyFollowingSnr(short, fs, 6), isNull);
    });
  });

  group('hub coherence', () {
    late FakeEegDriver driver;
    late EegHub hub;

    setUp(() async {
      driver = FakeEegDriver(
        vendor: EegVendor.emotiv,
        capabilities: const EegCapabilities(nativeBandPower: true, nativeMentalMetrics: true, contactQuality: true),
      );
      hub = EegHub(registry: EegDriverRegistry([driver]));
      await hub.connect(FakeEegDriver.device(EegDeviceType.emotivInsight));
    });

    tearDown(() => hub.dispose());

    Future<void> feedRaw(int seconds) async {
      for (var i = 0; i < seconds * fs; i++) {
        final t = i / fs;
        final alpha = 20 * sin(2 * pi * 10 * t);
        driver.raw(EegSample(
          timestamp: DateTime(2026).add(Duration(microseconds: (t * 1e6).round())),
          channels: {
            'AF3': 4200 + alpha + 5 * noise(),
            'T7': 4200 + alpha + 5 * noise(),
            'Pz': 4200 + 5 * noise(),
            'T8': 4200 + alpha + 5 * noise(),
            'AF4': 4200 + alpha + 5 * noise(),
          },
          quality: const {},
        ));
      }
      await Future<void>.delayed(Duration.zero);
    }

    test('estimates coherence of the analysis pair from raw EEG', () async {
      expect(hub.analysisPair.toString(), 'T7/T8 (temporal)');
      final readings = <EegPairCoherence>[];
      final sub = hub.coherenceStream.listen(readings.add);
      await feedRaw(4);
      expect(readings, isNotEmpty);
      final last = hub.lastCoherence!;
      expect(last.pair.toString(), 'T7/T8 (temporal)');
      // A pure 10 Hz rhythm is coherent in its bins; averaged over 8–13 Hz
      // with incoherent noise in the others, clearly above chance.
      expect(last.of('alpha'), greaterThan(0.5));
      expect(last.of('theta'), lessThan(last.threshold('theta')!));
      expect(last.isSignificant('alpha'), isTrue);
      await sub.cancel();
    });

    test('an electrode without contact moves the pair and drops the old reading', () async {
      await feedRaw(3);
      expect(hub.lastCoherence, isNotNull);
      driver.status(EegDeviceStatus(
        contactQuality: const {'AF3': 1, 'T7': 0, 'Pz': 1, 'T8': 1, 'AF4': 1},
        timestamp: DateTime.now(),
      ));
      await Future<void>.delayed(Duration.zero);
      expect(hub.analysisPair.toString(), 'AF3/AF4 (prefrontal)');
      expect(hub.lastCoherence, isNull);
      await feedRaw(3);
      expect(hub.lastCoherence!.pair.toString(), 'AF3/AF4 (prefrontal)');
    });

    test('disconnecting clears the pair and the reading', () async {
      await feedRaw(3);
      await hub.disconnect();
      expect(hub.analysisPair, isNull);
      expect(hub.lastCoherence, isNull);
    });
  });
}

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:neom_eeg/data/implementations/eeg_calibration_builder.dart';
import 'package:neom_eeg/data/implementations/eeg_coherence_tracker.dart';
import 'package:neom_eeg/data/implementations/eeg_indices.dart';
import 'package:neom_eeg/domain/enums/eeg_device_type.dart';
import 'package:neom_eeg/domain/models/eeg_band_power.dart';
import 'package:neom_eeg/domain/models/eeg_calibration.dart';
import 'package:neom_eeg/domain/models/eeg_channel_catalog.dart';

EegBandPower bp(
  String ch, {
  double delta = 1,
  double theta = 2,
  double alpha = 10,
  double betaLow = 3,
  double betaHigh = 1,
  double gamma = 0.5,
}) =>
    EegBandPower(
      channel: ch,
      delta: delta,
      theta: theta,
      alpha: alpha,
      betaLow: betaLow,
      betaHigh: betaHigh,
      gamma: gamma,
      timestamp: DateTime(2026, 9, 21),
    );

void main() {
  group('EegChannelCatalog regions', () {
    test('classifies 10-20 labels by prefix', () {
      expect(EegChannelCatalog.regionOf('AF3'), 'prefrontal');
      expect(EegChannelCatalog.regionOf('Fp1'), 'prefrontal');
      expect(EegChannelCatalog.regionOf('F7'), 'frontal');
      expect(EegChannelCatalog.regionOf('Fz'), 'frontal');
      expect(EegChannelCatalog.regionOf('FC5'), 'frontocentral');
      expect(EegChannelCatalog.regionOf('T7'), 'temporal');
      expect(EegChannelCatalog.regionOf('T3'), 'temporal'); // legacy alias
      expect(EegChannelCatalog.regionOf('TP9'), 'temporoparietal');
      expect(EegChannelCatalog.regionOf('Pz'), 'parietal');
      expect(EegChannelCatalog.regionOf('PO7'), 'parieto-occipital');
      expect(EegChannelCatalog.regionOf('O1'), 'occipital');
      expect(EegChannelCatalog.regionOf('RAW_CQ'), isNull);
    });

    test('frontal and posterior sets match the Insight layout', () {
      expect(EegChannelCatalog.emotivInsight.where(EegChannelCatalog.isFrontal), ['AF3', 'AF4']);
      expect(EegChannelCatalog.emotivInsight.where(EegChannelCatalog.isPosterior), ['Pz']);
      expect(EegChannelCatalog.muse.where(EegChannelCatalog.isFrontal), ['AF7', 'AF8']);
      expect(EegChannelCatalog.muse.where(EegChannelCatalog.isPosterior), isEmpty);
      // TP9/TP10 are temporoparietal but count as temporal coverage.
      expect(EegChannelCatalog.isTemporal('TP9'), isTrue);
      expect(EegChannelCatalog.bestPair(EegChannelCatalog.muse)!.region, 'temporoparietal');
      expect(EegChannelCatalog.bestPair(EegChannelCatalog.muse)!.isTemporal, isTrue);
      expect(EegChannelCatalog.hasTemporalCoverage(EegChannelCatalog.muse), isTrue);
    });

    test('MN8 and MW20 are in-ear T7/T8', () {
      expect(EegChannelCatalog.labelsFor(EegDeviceType.emotivMn8), ['T7', 'T8']);
      expect(EegChannelCatalog.labelsFor(EegDeviceType.emotivMw20), ['T7', 'T8']);
      expect(EegChannelCatalog.hasTemporalCoverage(EegChannelCatalog.emotivMn8), isTrue);
      expect(EegChannelCatalog.hasTemporalCoverage(EegChannelCatalog.brainbit), isTrue); // T3/T4
      expect(EegChannelCatalog.hasTemporalCoverage(EegChannelCatalog.openbciGanglion), isFalse);
    });
  });

  group('EegIndices', () {
    final insight = [bp('AF3'), bp('T7', alpha: 12), bp('Pz', alpha: 20), bp('T8', alpha: 8), bp('AF4')];

    test('shares sum to one and merge beta', () {
      final s = EegIndices.shares(insight);
      expect(s.values.fold(0.0, (a, b) => a + b), closeTo(1.0, 1e-9));
      expect(s.keys, containsAll(['delta', 'theta', 'alpha', 'beta', 'gamma']));
      expect(s.containsKey('betaLow'), isFalse);
    });

    test('asymmetry uses the temporal pair and the requested band', () {
      final a = EegIndices.asymmetry(insight)!;
      expect(a.pair.left, 'T7');
      expect(a.pair.right, 'T8');
      expect(a.index, closeTo((12 - 8) / 20, 1e-9));
      final theta = EegIndices.asymmetry(insight, band: 'theta')!;
      expect(theta.index, 0.0);
    });

    test('frontal activation is beta over alpha+theta on frontal channels only', () {
      final frame = [bp('AF3', betaLow: 6, betaHigh: 2, alpha: 5, theta: 3), bp('Pz', betaLow: 100)];
      expect(EegIndices.frontalActivation(frame), closeTo(8 / 8, 1e-9));
      expect(EegIndices.frontalActivation([bp('T7'), bp('T8')]), isNull);
    });

    test('posterior alpha share ignores non-posterior electrodes', () {
      final frame = [bp('Pz', alpha: 10, delta: 0, theta: 0, betaLow: 0, betaHigh: 0, gamma: 10), bp('AF3', alpha: 0)];
      expect(EegIndices.posteriorAlphaShare(frame), closeTo(0.5, 1e-9));
      expect(EegIndices.posteriorAlphaShare([bp('AF3')]), isNull);
    });

    test('compute without calibration has no z-scores', () {
      final idx = EegIndices.compute(insight, excludedChannels: 1);
      expect(idx.isCalibrated, isFalse);
      // Power symmetry of alpha on T7/T8 (12 vs 8); no raw EEG → no
      // spectral coherence is claimed.
      expect(idx.symmetry, closeTo(1 - 0.2, 1e-9));
      expect(idx.coherence, isNull);
      expect(idx.pair!.isTemporal, isTrue);
      expect(idx.excludedChannels, 1);
      expect(idx.hypofrontality, isNull);
    });

    test('compute with calibration yields z-scores and hypofrontality', () {
      // Rest: every channel alpha 10·10^(±0.05), beta 4, theta 2.
      final rnd = Random(5);
      final b = EegCalibrationBuilder();
      for (var i = 0; i < 300; i++) {
        final j = pow(10, 0.05 * (rnd.nextDouble() * 2 - 1)).toDouble();
        final k = pow(10, 0.05 * (rnd.nextDouble() * 2 - 1)).toDouble();
        b.addFrame(EegCalibrationPhase.eyesOpen, [
          for (final ch in EegChannelCatalog.emotivInsight)
            bp(ch, alpha: 10 * j, betaLow: 3 * k, betaHigh: 1 * k, theta: 2 * j),
        ]);
      }
      final cal = b.build(eyesOpenSeconds: 40, eyesClosedSeconds: 0);

      final calm = [for (final ch in EegChannelCatalog.emotivInsight) bp(ch, alpha: 14)];
      final idx = EegIndices.compute(calm, calibration: cal);
      expect(idx.isCalibrated, isTrue);
      expect(idx.z['alpha'], greaterThan(3)); // 14 vs 10, log-SD ≈ 0.03
      expect(idx.z['beta']!.abs(), lessThan(1.5));
      // Frontal β/(α+θ): rest 4/12, now 4/16 → 25 % lower.
      expect(idx.hypofrontality, closeTo(1 - (4 / 16) / (4 / 12), 0.02));
      expect(idx.frontalActivationZ, lessThan(-1));

      // More frontal beta than at rest → no hypofrontality (clamped at 0).
      final busy = [for (final ch in EegChannelCatalog.emotivInsight) bp(ch, betaLow: 10)];
      expect(EegIndices.compute(busy, calibration: cal).hypofrontality, 0.0);
    });
  });

  group('coherence attached to indices', () {
    test('only when the reading belongs to the same pair', () {
      final frame = [bp('AF3'), bp('T7', alpha: 12), bp('Pz'), bp('T8', alpha: 8), bp('AF4')];
      EegPairCoherence reading(EegHemisphericPair pair) => EegPairCoherence(
            pair: pair,
            msc: const {'alpha': 0.7},
            imaginary: const {'alpha': 0.1},
            thresholds: const {'alpha': 0.25},
            window: const Duration(seconds: 8),
            at: DateTime.now(),
          );
      final t = EegIndices.compute(frame, coherence: reading(EegChannelCatalog.hemisphericPairs.first));
      expect(t.coherence, 0.7);
      expect(t.coherenceSignificant, isTrue);
      expect(t.imaginaryCoherence, 0.1);

      final af = EegChannelCatalog.availablePairs(['AF3', 'AF4']).first;
      expect(EegIndices.compute(frame, coherence: reading(af)).coherence, isNull);
    });
  });

  group('EegCalibration model', () {
    test('legacy JSON (baselines/noise/threshold/date) still loads', () {
      final cal = EegCalibration.fromJson({
        'baselines': {'raw': {'AF3': 50.0}},
        'noiseFloor': 5.0,
        'artifactThreshold': 15.0,
        'calibratedAt': '2026-01-01T00:00:00.000',
      });
      expect(cal.baseline('raw', 'AF3'), 50.0);
      expect(cal.hasDeviations, isFalse);
      expect(cal.hasEyesClosed, isFalse);
      expect(cal.alphaReactivity, isNull);
      expect(cal.supportsZ, isFalse);
      expect(cal.headZ('alpha', [bp('AF3')]), isNull);
      expect(cal.key, 'local|any');
    });

    test('round-trips the full schema', () {
      final cal = EegCalibration(
        id: 'cal_1',
        subjectId: 'u1',
        channels: const ['AF3', 'Pz'],
        baselines: {'alpha': {'AF3': 10, 'Pz': 12}},
        deviations: {'alpha': {'AF3': 2, 'Pz': 3}},
        eyesClosed: {'alpha': {'AF3': 15, 'Pz': 30}},
        indexMeans: {'frontalActivation': -0.4},
        indexDeviations: {'frontalActivation': 0.05},
        noiseFloor: 4,
        artifactThreshold: 16,
        calibratedAt: DateTime(2026, 9, 21, 10),
        eyesOpenSeconds: 60,
        eyesClosedSeconds: 30,
        frames: 700,
      );
      final back = EegCalibration.fromJson(cal.toJson());
      expect(back.id, 'cal_1');
      expect(back.subjectId, 'u1');
      expect(back.key, 'u1|any');
      expect(back.deviation('alpha', 'Pz'), 3);
      expect(back.eyesClosed['alpha']!['Pz'], 30);
      expect(back.indexMeans['frontalActivation'], -0.4);
      expect(back.schemaVersion, EegCalibration.currentSchema);
      expect(back.frames, 700);
      // Reactivity prefers posterior electrodes: Pz 30/12.
      expect(back.alphaReactivity, closeTo(2.5, 1e-9));
    });

    test('channel lookup is case-insensitive and beta merges the halves', () {
      final cal = EegCalibration(
        baselines: {'betaLow': {'T7': 3}, 'betaHigh': {'T7': 1}, 'alpha': {'T7': 8}},
        deviations: {'betaLow': {'T7': 3}, 'betaHigh': {'T7': 4}},
        noiseFloor: 0,
        artifactThreshold: 0,
        calibratedAt: DateTime(2026),
      );
      expect(cal.baseline('alpha', 't7'), 8);
      expect(cal.meanBaseline('beta'), 4);
      expect(cal.covers(['t7']), isTrue);
      expect(cal.covers(['T7', 'T8']), isFalse);
    });

    test('baseline asymmetry lets the watcher measure change, not imbalance', () {
      final cal = EegCalibration(
        baselines: {'alpha': {'T7': 12, 'T8': 8}},
        noiseFloor: 0,
        artifactThreshold: 0,
        calibratedAt: DateTime(2026),
      );
      expect(cal.baselineAsymmetry('alpha', 'T7', 'T8'), closeTo(0.2, 1e-9));
      expect(cal.baselineAsymmetry('alpha', 'T7', 'Pz'), isNull);
    });
  });
}

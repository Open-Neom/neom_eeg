import 'package:flutter_test/flutter_test.dart';
import 'package:neom_eeg/data/implementations/eeg_indices.dart';
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
      expect(idx.coherence, closeTo(1 - 0.2, 1e-9));
      expect(idx.pair!.isTemporal, isTrue);
      expect(idx.excludedChannels, 1);
      expect(idx.hypofrontality, isNull);
    });

    test('compute with calibration yields z-scores and hypofrontality', () {
      final cal = EegCalibration(
        baselines: {
          'alpha': {'AF3': 10, 'T7': 10, 'Pz': 10, 'T8': 10, 'AF4': 10},
          'theta': {'AF3': 2, 'T7': 2, 'Pz': 2, 'T8': 2, 'AF4': 2},
          'delta': {'AF3': 1, 'T7': 1, 'Pz': 1, 'T8': 1, 'AF4': 1},
          'betaLow': {'AF3': 3, 'T7': 3, 'Pz': 3, 'T8': 3, 'AF4': 3},
          'betaHigh': {'AF3': 1, 'T7': 1, 'Pz': 1, 'T8': 1, 'AF4': 1},
          'gamma': {'AF3': 0.5, 'T7': 0.5, 'Pz': 0.5, 'T8': 0.5, 'AF4': 0.5},
        },
        deviations: {
          'alpha': {'AF3': 2, 'T7': 2, 'Pz': 2, 'T8': 2, 'AF4': 2},
          'theta': {'AF3': 1, 'T7': 1, 'Pz': 1, 'T8': 1, 'AF4': 1},
          'delta': {'AF3': 1, 'T7': 1, 'Pz': 1, 'T8': 1, 'AF4': 1},
          'betaLow': {'AF3': 1, 'T7': 1, 'Pz': 1, 'T8': 1, 'AF4': 1},
          'betaHigh': {'AF3': 1, 'T7': 1, 'Pz': 1, 'T8': 1, 'AF4': 1},
          'gamma': {'AF3': 0.1, 'T7': 0.1, 'Pz': 0.1, 'T8': 0.1, 'AF4': 0.1},
        },
        indexMeans: {EegCalibration.frontalActivationIndex: 4 / 12},
        indexDeviations: {EegCalibration.frontalActivationIndex: 0.1},
        noiseFloor: 5,
        artifactThreshold: 20,
        calibratedAt: DateTime(2026, 9, 20),
      );

      // Whole-head alpha 14 vs baseline 10 with sd 2 → z = 2.
      final calm = [for (final ch in EegChannelCatalog.emotivInsight) bp(ch, alpha: 14)];
      final idx = EegIndices.compute(calm, calibration: cal);
      expect(idx.z['alpha'], closeTo(2.0, 1e-9));
      expect(idx.z['beta'], closeTo(0.0, 1e-9));
      expect(idx.frontalActivationZ, closeTo(((4 / 16) - (4 / 12)) / 0.1, 1e-9));
      expect(idx.hypofrontality, closeTo(((4 / 12) - (4 / 16)) / (4 / 12), 1e-9));

      // More frontal beta than at rest → no hypofrontality (clamped at 0).
      final busy = [for (final ch in EegChannelCatalog.emotivInsight) bp(ch, betaLow: 10)];
      expect(EegIndices.compute(busy, calibration: cal).hypofrontality, 0.0);
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
      expect(cal.zScore('alpha', 1), isNull);
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
        indexMeans: {'frontalActivation': 0.4},
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
      expect(back.indexMeans['frontalActivation'], 0.4);
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
      expect(cal.meanDeviation('beta'), 5); // quadrature: sqrt(9 + 16)
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

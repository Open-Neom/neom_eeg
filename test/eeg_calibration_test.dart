import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:neom_eeg/data/hub/eeg_driver_registry.dart';
import 'package:neom_eeg/data/hub/eeg_hub.dart';
import 'package:neom_eeg/data/implementations/eeg_calibration_builder.dart';
import 'package:neom_eeg/data/implementations/eeg_calibration_controller.dart';
import 'package:neom_eeg/domain/enums/eeg_device_type.dart';
import 'package:neom_eeg/domain/enums/eeg_vendor.dart';
import 'package:neom_eeg/domain/models/eeg_band_power.dart';
import 'package:neom_eeg/domain/models/eeg_calibration.dart';
import 'package:neom_eeg/domain/models/eeg_capabilities.dart';
import 'package:neom_eeg/domain/models/eeg_exceptions.dart';
import 'package:neom_eeg/domain/models/eeg_sample.dart';
import 'package:sint/sint.dart';

import 'support/fake_eeg_driver.dart';

EegBandPower bp(String ch, {double alpha = 10, double theta = 2, double betaLow = 3}) => EegBandPower(
      channel: ch,
      delta: 1,
      theta: theta,
      alpha: alpha,
      betaLow: betaLow,
      betaHigh: 1,
      gamma: 0.5,
      timestamp: DateTime.now(),
    );

List<EegBandPower> insight({double alpha = 10, double betaLow = 3}) => [
      bp('AF3', alpha: alpha, betaLow: betaLow),
      bp('T7', alpha: alpha),
      bp('Pz', alpha: alpha),
      bp('T8', alpha: alpha),
      bp('AF4', alpha: alpha, betaLow: betaLow),
    ];

void main() {
  group('EegCalibrationBuilder', () {
    test('computes per-channel mean and sd, raw DC level and noise floor', () {
      final b = EegCalibrationBuilder();
      b.addFrame(EegCalibrationPhase.eyesOpen, insight(alpha: 8));
      b.addFrame(EegCalibrationPhase.eyesOpen, insight(alpha: 12));
      b.addFrame(EegCalibrationPhase.eyesClosed, insight(alpha: 30));
      for (final v in [4200.0, 4210.0, 4190.0, 4200.0]) {
        b.addRaw(
          EegCalibrationPhase.eyesOpen,
          EegSample(timestamp: DateTime.now(), channels: {'AF3': v, 'Pz': v + 100}, quality: const {}),
        );
      }
      // Raw in the eyes-closed phase is ignored (blinks absent, adds nothing).
      b.addRaw(
        EegCalibrationPhase.eyesClosed,
        EegSample(timestamp: DateTime.now(), channels: {'AF3': 9999}, quality: const {}),
      );

      final cal = b.build(
        subjectId: 'u1',
        deviceType: EegDeviceType.emotivInsight,
        eyesOpenSeconds: 60,
        eyesClosedSeconds: 30,
        at: DateTime(2026, 9, 21, 12),
      );

      expect(cal.key, 'u1|emotivInsight');
      expect(cal.channels, ['AF3', 'T7', 'Pz', 'T8', 'AF4']);
      expect(cal.baseline('alpha', 'Pz'), closeTo(10, 1e-9));
      expect(cal.deviation('alpha', 'Pz'), closeTo(2.8284, 1e-3)); // sample sd of {8, 12}
      expect(cal.eyesClosed['alpha']!['Pz'], 30);
      expect(cal.alphaReactivity, closeTo(3.0, 1e-9));
      expect(cal.baseline(EegCalibration.rawKey, 'AF3'), closeTo(4200, 1e-9));
      expect(cal.baseline(EegCalibration.rawKey, 'Pz'), closeTo(4300, 1e-9));
      expect(cal.noiseFloor, closeTo(8.165, 1e-2)); // sd of ±10 around DC
      expect(cal.artifactThreshold, closeTo(cal.noiseFloor * 4, 1e-9));
      expect(cal.frames, 3);
      expect(cal.eyesOpenSeconds, 60);
      // Whole-head indices at rest: frontal β/(α+θ) of the two frames (4/10,
      // 4/14), averaged in log₁₀ (geometric mean as a ratio).
      expect(cal.indexMeans[EegCalibration.frontalActivationIndex],
          closeTo((log(0.4) / ln10 + log(4 / 14) / ln10) / 2, 1e-9));
      expect(cal.frontalActivationRest, closeTo(sqrt(0.4 * 4 / 14), 1e-9));
      expect(cal.schemaVersion, EegCalibration.currentSchema);
      expect(cal.supportsZ, isTrue);
      expect(cal.indexMeans['${EegCalibration.asymmetryIndexPrefix}alpha'], closeTo(0.0, 1e-9));
    });

    test('rejects artifact frames before computing the baseline', () {
      final rnd = Random(3);
      final b = EegCalibrationBuilder();
      for (var i = 0; i < 60; i++) {
        b.addFrame(EegCalibrationPhase.eyesOpen, insight(alpha: 10 + rnd.nextDouble()));
      }
      // Three blinks: frontal power ×40.
      for (var i = 0; i < 3; i++) {
        b.addFrame(EegCalibrationPhase.eyesOpen, [
          bp('AF3', alpha: 400, theta: 80, betaLow: 120),
          bp('T7'), bp('Pz'), bp('T8'),
          bp('AF4', alpha: 400, theta: 80, betaLow: 120),
        ]);
      }
      final cal = b.build(eyesOpenSeconds: 60, eyesClosedSeconds: 0);
      expect(cal.rejectedFrames, 3);
      expect(cal.frames, 60);
      expect(cal.baseline('alpha', 'AF3'), lessThan(11.5));
    });

    test('whole-head z is in σ of the whole-head quantity and uses the overlapping channels', () {
      final rnd = Random(11);
      double g() => sqrt(-2 * log(1 - rnd.nextDouble())) * cos(2 * pi * rnd.nextDouble());
      // Independent per-channel noise: the channel-averaged z at rest has
      // SD ≈ 1/√5, which the builder measures instead of assuming 1.
      List<EegBandPower> noisy({double gain = 1}) => [
            for (final ch in ['AF3', 'T7', 'Pz', 'T8', 'AF4'])
              bp(ch, alpha: 10 * gain * pow(10, 0.05 * g()).toDouble()),
          ];
      final b = EegCalibrationBuilder();
      for (var i = 0; i < 400; i++) {
        b.addFrame(EegCalibrationPhase.eyesOpen, noisy());
      }
      final cal = b.build(eyesOpenSeconds: 50, eyesClosedSeconds: 0);
      expect(cal.headDeviations['alpha'], closeTo(1 / sqrt(5), 0.08));

      // At rest the whole-head z has SD ≈ 1 — a real σ.
      final zs = [for (var i = 0; i < 400; i++) cal.headZ('alpha', noisy())!];
      final mean = zs.reduce((a, c) => a + c) / zs.length;
      final sd = sqrt(zs.map((z) => (z - mean) * (z - mean)).reduce((a, c) => a + c) / zs.length);
      expect(mean.abs(), lessThan(0.2));
      expect(sd, closeTo(1.0, 0.15));

      // A frame without T7 (lost contact) is scored on the four channels
      // it shares with the baseline, not against a five-channel mean.
      final withoutT7 = [for (final x in noisy(gain: 1)) if (x.channel != 'T7') x];
      expect(cal.headZ('alpha', withoutT7)!.abs(), lessThan(4));
      expect(cal.headZ('alpha', [bp('O1')]), isNull);
    });

    test('baselines of the previous schema load but do not support z', () {
      final v1 = EegCalibration.fromJson({
        'id': 'old',
        'baselines': {'alpha': {'Pz': 10.0}},
        'deviations': {'alpha': {'Pz': 2.0}},
        'noiseFloor': 5.0,
        'artifactThreshold': 20.0,
        'calibratedAt': '2026-09-21T10:00:00.000',
      });
      expect(v1.schemaVersion, 1);
      expect(v1.supportsZ, isFalse);
      expect(v1.headZ('alpha', [bp('Pz')]), isNull);
      expect(v1.baseline('alpha', 'Pz'), 10.0);
      final b = EegCalibrationBuilder()
        ..addFrame(EegCalibrationPhase.eyesOpen, insight())
        ..addFrame(EegCalibrationPhase.eyesOpen, insight(alpha: 12));
      final back = EegCalibration.fromJson(
        b.build(eyesOpenSeconds: 1, eyesClosedSeconds: 0).toJson(),
      );
      expect(back.schemaVersion, EegCalibration.currentSchema);
      expect(back.logMeans['alpha']!['Pz'], isNotNull);
      expect(back.headDeviations.containsKey('alpha'), isTrue);
    });

    test('hasData only after an eyes-open frame', () {
      final b = EegCalibrationBuilder();
      expect(b.hasData, isFalse);
      b.addFrame(EegCalibrationPhase.eyesClosed, insight());
      expect(b.hasData, isFalse);
      b.addFrame(EegCalibrationPhase.eyesOpen, insight());
      expect(b.hasData, isTrue);
      b.reset();
      expect(b.hasData, isFalse);
    });
  });

  group('EegCalibrationController', () {
    late Directory dir;
    late FakeEegDriver driver;
    late EegHub hub;
    late EegCalibrationController controller;

    setUpAll(() async {
      dir = await Directory.systemTemp.createTemp('neom_eeg_cal_');
      Hive.init(dir.path);
    });

    tearDownAll(() async {
      await Hive.close();
      await dir.delete(recursive: true);
    });

    setUp(() async {
      driver = FakeEegDriver(
        vendor: EegVendor.emotiv,
        capabilities: const EegCapabilities(nativeBandPower: true, nativeMentalMetrics: true),
      );
      hub = EegHub(registry: EegDriverRegistry([driver]));
      controller = EegCalibrationController(
        hub: hub,
        subjectId: () => 'tester',
        tick: const Duration(milliseconds: 10),
      );
      Sint.put(controller);
      if (Hive.isBoxOpen(EegCalibrationController.boxName)) {
        await Hive.box<Map>(EegCalibrationController.boxName).clear();
      }
    });

    tearDown(() async {
      Sint.delete<EegCalibrationController>(force: true);
      await hub.dispose();
    });

    test('refuses to run without a streaming headset', () async {
      expect(() => controller.run(), throwsA(isA<EegException>()));
    });

    test('runs both phases, saves and exposes the result', () async {
      await hub.connect(FakeEegDriver.device(EegDeviceType.emotivInsight));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(controller.current.value, isNull);

      final future = controller.run(
        eyesOpen: const Duration(milliseconds: 120),
        eyesClosed: const Duration(milliseconds: 80),
        settle: Duration.zero,
      );
      // Feed frames while the routine runs: calm eyes open, strong alpha
      // once the eyes-closed phase starts.
      final phases = <EegCalibrationPhase>{};
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        phases.add(controller.phase.value);
        final closed = controller.phase.value == EegCalibrationPhase.eyesClosed;
        driver.bandPower(insight(alpha: closed ? 30 : 10));
      }
      final cal = await future;

      expect(phases, containsAll([EegCalibrationPhase.eyesOpen, EegCalibrationPhase.eyesClosed]));
      expect(cal, isNotNull);
      expect(controller.phase.value, EegCalibrationPhase.done);
      expect(controller.progress.value, 1.0);
      expect(controller.current.value, same(cal));
      expect(cal!.subjectId, 'tester');
      expect(cal.deviceType, EegDeviceType.emotivInsight);
      expect(cal.hasEyesClosed, isTrue);
      expect(cal.alphaReactivity, greaterThan(1.5));
      expect(cal.frames, controller.frames.value);

      // Persisted under subject|model and reloaded on the next connection.
      controller.current.value = null;
      final loaded = await controller.load();
      expect(loaded?.id, cal.id);
    });

    test('frames in the first seconds of each phase are ignored', () async {
      await hub.connect(FakeEegDriver.device(EegDeviceType.emotivInsight));
      final future = controller.run(
        eyesOpen: const Duration(milliseconds: 150),
        eyesClosed: const Duration(milliseconds: 150),
        settle: const Duration(milliseconds: 80),
      );
      var early = 0;
      final started = DateTime.now();
      for (var i = 0; i < 30; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        final inPhase = DateTime.now().difference(started).inMilliseconds % 150;
        if (inPhase < 60) early++;
        driver.bandPower(insight(alpha: controller.phase.value == EegCalibrationPhase.eyesClosed ? 30 : 10));
      }
      final cal = await future;
      expect(early, greaterThan(0));
      expect(cal, isNotNull);
      // Fewer frames kept than fed: the settling ones were skipped.
      expect(cal!.frames, lessThan(30));
    });

    test('a routine with no band powers ends cancelled with an error', () async {
      await hub.connect(FakeEegDriver.device(EegDeviceType.emotivInsight));
      final cal = await controller.run(
        eyesOpen: const Duration(milliseconds: 40),
        includeEyesClosed: false,
        settle: Duration.zero,
      );
      expect(cal, isNull);
      expect(controller.phase.value, EegCalibrationPhase.cancelled);
      expect(controller.error.value, contains('no envió'));
      expect(controller.current.value, isNull);
    });

    test('cancel stops the routine without saving', () async {
      await hub.connect(FakeEegDriver.device(EegDeviceType.emotivInsight));
      final future = controller.run(eyesOpen: const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 15));
      driver.bandPower(insight());
      expect(controller.isRunning, isTrue);
      await controller.cancel();
      expect(await future, isNull);
      expect(controller.isRunning, isFalse);
      expect(controller.phase.value, EegCalibrationPhase.cancelled);
      expect(await controller.listAll(), isEmpty);
    });

    test('a disconnection mid-routine aborts it', () async {
      await hub.connect(FakeEegDriver.device(EegDeviceType.emotivInsight));
      final future = controller.run(eyesOpen: const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 15));
      await hub.disconnect();
      await Future<void>.delayed(const Duration(milliseconds: 15));
      expect(await future, isNull);
      expect(controller.error.value, contains('desconectó'));
    });

    test('load picks the baseline of the connected model and subject', () async {
      final other = EegCalibration(
        id: 'muse',
        subjectId: 'tester',
        deviceType: EegDeviceType.muse,
        baselines: {'alpha': {'TP9': 1}},
        noiseFloor: 0,
        artifactThreshold: 0,
        calibratedAt: DateTime(2026, 1, 1),
      );
      final mine = EegCalibration(
        id: 'insight',
        subjectId: 'tester',
        deviceType: EegDeviceType.emotivInsight,
        baselines: {'alpha': {'Pz': 1}},
        noiseFloor: 0,
        artifactThreshold: 0,
        calibratedAt: DateTime(2026, 2, 1),
      );
      await controller.save(other);
      await controller.save(mine);

      await hub.connect(FakeEegDriver.device(EegDeviceType.emotivInsight));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(controller.current.value?.id, 'insight');

      final all = await controller.listAll();
      expect(all.map((c) => c.id), ['insight', 'muse']);

      await controller.clear();
      expect(controller.current.value, isNull);
      expect((await controller.listAll()).map((c) => c.id), ['muse']);

      await hub.disconnect();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(controller.current.value, isNull);
    });
  });
}

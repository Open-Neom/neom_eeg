import 'dart:io';

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
      // Whole-head indices at rest: frontal β/(α+θ) of the two frames (4/10, 4/14).
      expect(cal.indexMeans[EegCalibration.frontalActivationIndex], closeTo((0.4 + 4 / 14) / 2, 1e-9));
      expect(cal.indexMeans['${EegCalibration.asymmetryIndexPrefix}alpha'], closeTo(0.0, 1e-9));
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

    test('a routine with no band powers ends cancelled with an error', () async {
      await hub.connect(FakeEegDriver.device(EegDeviceType.emotivInsight));
      final cal = await controller.run(
        eyesOpen: const Duration(milliseconds: 40),
        includeEyesClosed: false,
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

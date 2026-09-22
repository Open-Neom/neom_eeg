import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:neom_eeg/data/hub/eeg_driver_registry.dart';
import 'package:neom_eeg/data/hub/eeg_hub.dart';
import 'package:neom_eeg/data/implementations/eeg_session_capture_controller.dart';
import 'package:neom_eeg/data/implementations/eeg_watch_controller.dart';
import 'package:neom_eeg/domain/enums/eeg_device_type.dart';
import 'package:neom_eeg/domain/enums/eeg_vendor.dart';
import 'package:neom_eeg/domain/models/eeg_band_power.dart';
import 'package:neom_eeg/domain/models/eeg_calibration.dart';
import 'package:neom_eeg/domain/models/eeg_capabilities.dart';
import 'package:neom_eeg/domain/models/eeg_channel_catalog.dart';
import 'package:neom_eeg/domain/models/eeg_device_status.dart';
import 'package:neom_eeg/domain/models/eeg_watch_rule.dart';
import 'package:sint/sint.dart';

import 'support/fake_eeg_driver.dart';

EegBandPower bp(String ch, {double alpha = 10, double betaLow = 3, double betaHigh = 1}) => EegBandPower(
      channel: ch,
      delta: 1,
      theta: 2,
      alpha: alpha,
      betaLow: betaLow,
      betaHigh: betaHigh,
      gamma: 0.5,
      timestamp: DateTime.now(),
    );

/// Balanced Insight frame; [t7] and [t8] override the temporal alpha.
List<EegBandPower> insight({double t7 = 10, double t8 = 10, double beta = 3}) => [
      bp('AF3', betaLow: beta),
      bp('T7', alpha: t7, betaLow: beta),
      bp('Pz', betaLow: beta),
      bp('T8', alpha: t8, betaLow: beta),
      bp('AF4', betaLow: beta),
    ];

EegCalibration calibration({double restingT7 = 10, double restingT8 = 10}) => EegCalibration(
      deviceType: EegDeviceType.emotivInsight,
      baselines: {
        for (final band in ['delta', 'theta', 'alpha', 'betaLow', 'betaHigh', 'gamma'])
          band: {
            for (final ch in EegChannelCatalog.emotivInsight)
              ch: switch (band) {
                'alpha' => ch == 'T7' ? restingT7 : ch == 'T8' ? restingT8 : 10.0,
                'theta' => 2.0,
                'betaLow' => 3.0,
                'betaHigh' => 1.0,
                'gamma' => 0.5,
                _ => 1.0,
              },
          },
      },
      deviations: {
        for (final band in ['delta', 'theta', 'alpha', 'betaLow', 'betaHigh', 'gamma'])
          band: {for (final ch in EegChannelCatalog.emotivInsight) ch: band == 'alpha' ? 2.0 : 1.0},
      },
      indexMeans: {EegCalibration.frontalActivationIndex: 4 / 12},
      indexDeviations: {EegCalibration.frontalActivationIndex: 0.05},
      noiseFloor: 5,
      artifactThreshold: 20,
      calibratedAt: DateTime(2026, 9, 20),
    );

void main() {
  late Directory dir;
  late FakeEegDriver driver;
  late EegHub hub;
  late EegWatchController watch;
  EegCalibration? cal;
  late DateTime now;

  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('neom_eeg_watch_');
    Hive.init(dir.path);
  });

  tearDownAll(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  setUp(() async {
    driver = FakeEegDriver(
      vendor: EegVendor.emotiv,
      capabilities: const EegCapabilities(
        nativeBandPower: true,
        nativeMentalMetrics: true,
        contactQuality: true,
      ),
    );
    hub = EegHub(registry: EegDriverRegistry([driver]));
    cal = null;
    now = DateTime(2026, 9, 21, 9);
    watch = EegWatchController(
      hub: hub,
      calibration: () => cal,
      capture: () => Sint.isRegistered<EegSessionCaptureController>()
          ? Sint.find<EegSessionCaptureController>()
          : null,
      clock: () => now,
    );
    Sint.put(watch);
    await hub.connect(FakeEegDriver.device(EegDeviceType.emotivInsight));
  });

  tearDown(() async {
    Sint.delete<EegWatchController>(force: true);
    if (Sint.isRegistered<EegSessionCaptureController>()) {
      Sint.delete<EegSessionCaptureController>(force: true);
    }
    await hub.dispose();
  });

  /// Pushes [frame] through the hub every second for [seconds].
  Future<void> feed(List<EegBandPower> frame, {required int seconds}) async {
    for (var i = 0; i < seconds; i++) {
      now = now.add(const Duration(seconds: 1));
      driver.bandPower(frame);
      await Future<void>.delayed(Duration.zero);
    }
  }

  group('sustain and cooldown', () {
    test('an imbalance fires only after holding for the rule sustain', () async {
      // |asym| = (16 − 8) / 24 = 0.33 > 0.2, no calibration → absolute.
      await feed(insight(t7: 16, t8: 8), seconds: 9);
      expect(watch.alerts, isEmpty);
      expect(watch.holding.keys, contains('asymmetry_sustained'));
      expect(watch.active, isEmpty);

      await feed(insight(t7: 16, t8: 8), seconds: 2);
      expect(watch.alerts.length, 1);
      final a = watch.alerts.first;
      expect(a.rule.id, 'asymmetry_sustained');
      expect(a.value, closeTo(8 / 24, 1e-9));
      expect(a.sustained, greaterThanOrEqualTo(const Duration(seconds: 10)));
      expect(a.markerAdded, isFalse); // nothing was recording
      expect(watch.active, contains('asymmetry_sustained'));
      expect(watch.holding.containsKey('asymmetry_sustained'), isFalse);
    });

    test('a brief imbalance that releases never fires', () async {
      await feed(insight(t7: 16, t8: 8), seconds: 6);
      await feed(insight(), seconds: 1);
      expect(watch.holding, isEmpty);
      await feed(insight(t7: 16, t8: 8), seconds: 6);
      expect(watch.alerts, isEmpty);
    });

    test('a long episode is re-marked every cooldown, not every frame', () async {
      await feed(insight(t7: 16, t8: 8), seconds: 11);
      expect(watch.alerts.length, 1);
      await feed(insight(t7: 16, t8: 8), seconds: 50);
      expect(watch.alerts.length, 1);
      await feed(insight(t7: 16, t8: 8), seconds: 10);
      expect(watch.alerts.length, 2);
    });

    test('release clears the active state', () async {
      await feed(insight(t7: 16, t8: 8), seconds: 11);
      expect(watch.active, isNotEmpty);
      await feed(insight(), seconds: 1);
      expect(watch.active, isEmpty);
    });
  });

  group('personal thresholds', () {
    test('z-scored rules stay dormant without a calibration', () async {
      final betaRule = watch.rules.firstWhere((r) => r.id == 'beta_over_baseline');
      expect(watch.isArmed(betaRule), isFalse);
      await feed(insight(beta: 30), seconds: 15);
      expect(watch.alerts.where((a) => a.rule.id == 'beta_over_baseline'), isEmpty);
      expect(watch.indices.value.isCalibrated, isFalse);
    });

    test('beta 2σ over the resting level fires once calibrated', () async {
      cal = calibration();
      // betaLow 3 → 6 on every channel: whole-head beta 7 vs baseline 4,
      // sd(beta) = sqrt(1² + 1²) → z = 3 / 1.414 = 2.12 > 2.
      await feed(insight(beta: 6), seconds: 11);
      final betaAlerts = watch.alerts.where((a) => a.rule.id == 'beta_over_baseline').toList();
      expect(betaAlerts.length, 1);
      expect(betaAlerts.first.value, greaterThan(2.0));
      expect(watch.indices.value.isCalibrated, isTrue);
    });

    test('the asymmetry rule measures change from the resting balance', () async {
      // The subject habitually sits at +0.33 (T7 16 / T8 8). Calibrated, the
      // same frame is *not* an alert; a swing to the other side is.
      cal = calibration(restingT7: 16, restingT8: 8);
      await feed(insight(t7: 16, t8: 8), seconds: 12);
      expect(watch.alerts.where((a) => a.rule.id == 'asymmetry_sustained'), isEmpty);

      await feed(insight(t7: 8, t8: 16), seconds: 12);
      expect(watch.alerts.where((a) => a.rule.id == 'asymmetry_sustained').length, 1);
    });

    test('hypofrontality fires when frontal activation drops 1σ under rest', () async {
      cal = calibration();
      // Frontal β 4 over α+θ 12 at rest (0.333); β 1 → 0.083, z = −5.
      final quiet = [bp('AF3', betaLow: 0, betaHigh: 1), bp('T7'), bp('Pz'), bp('T8'), bp('AF4', betaLow: 0, betaHigh: 1)];
      await feed(quiet, seconds: 21);
      final hypo = watch.alerts.where((a) => a.rule.id == 'hypofrontality').toList();
      expect(hypo.length, 1);
      expect(hypo.first.severity, EegAlertSeverity.info);
      expect(watch.indices.value.hypofrontality, closeTo(0.75, 1e-9));
    });
  });

  group('contact and markers', () {
    test('an electrode without contact is reported without a marker', () async {
      driver.status(EegDeviceStatus(
        contactQuality: const {'AF3': 1, 'T7': 0, 'Pz': 1, 'T8': 1, 'AF4': 1},
        timestamp: now,
      ));
      await Future<void>.delayed(Duration.zero);
      expect(hub.excludedChannels, ['T7']);
      await feed(insight(), seconds: 6);
      final lost = watch.alerts.where((a) => a.rule.id == 'contact_lost').toList();
      expect(lost.length, 1);
      expect(lost.first.value, 1);
      expect(lost.first.rule.autoMarker, isFalse);
    });

    test('an alert during a recording pins an auto marker and is noted in the capture', () async {
      final capture = EegSessionCaptureController(hub: hub, tick: const Duration(milliseconds: 20));
      Sint.put(capture);
      if (Hive.isBoxOpen(EegSessionCaptureController.boxName)) {
        await Hive.box<Map>(EegSessionCaptureController.boxName).clear();
      }
      await Future<void>.delayed(const Duration(milliseconds: 30));

      final rec = await hub.recording.startRecording(title: 'watch');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final markers = <String>[];
      final sub = hub.recording.markerStream.listen((m) => markers.add(m.label));

      await feed(insight(t7: 16, t8: 8), seconds: 11);
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(markers, ['Asimetría hemisférica']);
      expect(watch.alerts.first.markerAdded, isTrue);
      expect(watch.alerts.first.recordingId, rec.id);
      expect(hub.recording.activeRecording?.markerCount, 1);

      await sub.cancel();
      await hub.recording.stopRecording();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      final saved = capture.captures.first;
      expect(saved.markers.map((m) => m.label), ['Asimetría hemisférica']);
      expect(saved.alerts.length, 1);
      expect(saved.alerts.first.ruleId, 'asymmetry_sustained');
      expect(saved.alerts.first.markerAdded, isTrue);
      expect(saved.alerts.first.severity, 'warning');
    });

    test('auto markers can be switched off while alerts keep firing', () async {
      watch.autoMarkers.value = false;
      await hub.recording.startRecording(title: 'quiet');
      await feed(insight(t7: 16, t8: 8), seconds: 11);
      await Future<void>.delayed(Duration.zero);
      expect(watch.alerts.length, 1);
      expect(watch.alerts.first.markerAdded, isFalse);
      expect(hub.recording.activeRecording?.markerCount, 0);
      await hub.recording.stopRecording();
    });
  });

  group('rules and lifecycle', () {
    test('rules are data: JSON round-trip and per-rule toggles', () {
      final rule = EegWatchRule.defaults.first;
      final back = EegWatchRule.fromJson(rule.toJson());
      expect(back.id, rule.id);
      expect(back.metric, rule.metric);
      expect(back.sustain, rule.sustain);
      expect(back.cooldown, rule.cooldown);
      expect(back.markerValue, rule.markerValue);
      expect(back.personal, rule.personal);

      watch.toggleRule('asymmetry_sustained', false);
      expect(watch.rules.firstWhere((r) => r.id == 'asymmetry_sustained').enabled, isFalse);
    });

    test('a disabled rule never fires and a custom rule set replaces the defaults', () async {
      watch.toggleRule('asymmetry_sustained', false);
      await feed(insight(t7: 16, t8: 8), seconds: 12);
      expect(watch.alerts, isEmpty);

      watch.setRules([
        const EegWatchRule(
          id: 'alpha_share',
          label: 'Alfa dominante',
          metric: EegWatchMetric.bandShare,
          band: 'alpha',
          threshold: 0.5,
          sustain: Duration(seconds: 3),
          autoMarker: false,
          severity: EegAlertSeverity.info,
        ),
      ]);
      await feed([for (final ch in EegChannelCatalog.emotivInsight) bp(ch, alpha: 40)], seconds: 4);
      expect(watch.alerts.map((a) => a.rule.id), ['alpha_share']);
    });

    test('a reconnection resets sustain timers', () async {
      await feed(insight(t7: 16, t8: 8), seconds: 8);
      expect(watch.holding, isNotEmpty);
      await hub.disconnect();
      await Future<void>.delayed(Duration.zero);
      expect(watch.holding, isEmpty);
      expect(watch.indices.value.isEmpty, isTrue);

      await hub.connect(FakeEegDriver.device(EegDeviceType.emotivInsight));
      await feed(insight(t7: 16, t8: 8), seconds: 5);
      expect(watch.alerts, isEmpty);
    });

    test('alertStream delivers every alert', () async {
      final seen = <EegAlert>[];
      final sub = watch.alertStream.listen(seen.add);
      await feed(insight(t7: 16, t8: 8), seconds: 11);
      await Future<void>.delayed(Duration.zero);
      expect(seen.length, 1);
      await sub.cancel();
    });
  });
}

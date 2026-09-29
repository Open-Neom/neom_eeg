import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:neom_eeg/data/hub/eeg_driver_registry.dart';
import 'package:neom_eeg/data/hub/eeg_hub.dart';
import 'package:neom_eeg/data/implementations/eeg_calibration_builder.dart';
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

/// Resting baseline built the way the routine builds it: 60 s at 8 Hz of
/// [insight]-like frames with ±12 % log-normal jitter per channel and band.
EegCalibration calibration({double restingT7 = 10, double restingT8 = 10}) {
  final rnd = Random(99);
  double j() => pow(10, 0.05 * (rnd.nextDouble() * 2 - 1)).toDouble();
  final b = EegCalibrationBuilder();
  for (var i = 0; i < 480; i++) {
    b.addFrame(EegCalibrationPhase.eyesOpen, [
      for (final ch in EegChannelCatalog.emotivInsight)
        EegBandPower(
          channel: ch,
          delta: 1 * j(),
          theta: 2 * j(),
          alpha: (ch == 'T7' ? restingT7 : ch == 'T8' ? restingT8 : 10.0) * j(),
          betaLow: 3 * j(),
          betaHigh: 1 * j(),
          gamma: 0.5 * j(),
          timestamp: DateTime(2026, 9, 20),
        ),
    ]);
  }
  return b.build(deviceType: EegDeviceType.emotivInsight, eyesOpenSeconds: 60, eyesClosedSeconds: 0);
}

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

    test('an imbalance that really ends restarts the count', () async {
      await feed(insight(t7: 16, t8: 8), seconds: 6);
      await feed(insight(), seconds: 6); // smoothed value falls below 0.15
      expect(watch.holding, isEmpty);
      await feed(insight(t7: 16, t8: 8), seconds: 6);
      expect(watch.alerts, isEmpty);
    });

    test('a single balanced frame does not restart a sustained episode', () async {
      await feed(insight(t7: 16, t8: 8), seconds: 6);
      await feed(insight(), seconds: 1); // one dip: smoothed stays over 0.15
      expect(watch.holding.keys, contains('asymmetry_sustained'));
      await feed(insight(t7: 16, t8: 8), seconds: 5);
      expect(watch.alerts.map((a) => a.rule.id), contains('asymmetry_sustained'));
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
      await feed(insight(), seconds: 6);
      expect(watch.active, isEmpty);
    });
  });

  group('noisy signal (8 Hz frames, like Cortex pow)', () {
    /// Frames with ±25 % multiplicative alpha noise per channel — what a
    /// ⅛ s band-power frame looks like — for [seconds] at 8 Hz.
    Future<void> feedNoisy({required double t7, required double t8, required int seconds}) async {
      final rnd = Random(7);
      double g() => sqrt(-2 * log(1 - rnd.nextDouble())) * cos(2 * pi * rnd.nextDouble());
      for (var i = 0; i < seconds * 8; i++) {
        now = now.add(const Duration(milliseconds: 125));
        driver.bandPower([
          for (final ch in EegChannelCatalog.emotivInsight)
            bp(ch, alpha: (ch == 'T7' ? t7 : ch == 'T8' ? t8 : 10) * (1 + 0.25 * g())),
        ]);
        await Future<void>.delayed(Duration.zero);
      }
    }

    test('a true 0.33 asymmetry fires despite frame noise', () async {
      // Before smoothing this fired 0 times in 120 s: 21 % of frames dipped
      // under 0.2 and each dip restarted the 10 s count.
      await feedNoisy(t7: 16, t8: 8, seconds: 30);
      expect(watch.alerts.where((a) => a.rule.id == 'asymmetry_sustained'), isNotEmpty);
    });

    test('balanced but noisy temporal alpha never fires', () async {
      // Per frame, 29 % of these exceed |0.2|; smoothed, none is sustained.
      await feedNoisy(t7: 10, t8: 10, seconds: 120);
      expect(watch.alerts.where((a) => a.rule.id == 'asymmetry_sustained'), isEmpty);
    });
  });

  group('personal thresholds', () {
    test('z-scored rules stay dormant without a calibration', () async {
      final betaRule = watch.rules.firstWhere((r) => r.id == 'beta_over_baseline');
      expect(watch.isArmed(betaRule), isFalse);
      // The coherence metric is dormant too: no raw EEG went through the hub.
      expect(
        watch.isArmed(const EegWatchRule(id: 'c', label: 'c', metric: EegWatchMetric.coherence, threshold: 0.5)),
        isFalse,
      );
      await feed(insight(beta: 30), seconds: 15);
      expect(watch.alerts.where((a) => a.rule.id == 'beta_over_baseline'), isEmpty);
      expect(watch.indices.value.isCalibrated, isFalse);
    });

    test('beta 2σ over the resting level fires once calibrated', () async {
      cal = calibration();
      // betaLow 3 → 6 on every channel: log₁₀(7/4) = 0.24 against a
      // resting log-SD near 0.03 — far beyond 2σ of the whole-head z.
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
      // Frontal β/(α+θ): 1/12 now against a resting geometric mean ≈ 4/12.
      expect(watch.indices.value.hypofrontality, closeTo(0.75, 0.03));
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

    test('an asymmetry rule measures its own band', () async {
      watch.setRules([
        const EegWatchRule(
          id: 'theta_asym',
          label: 'Asimetría theta',
          metric: EegWatchMetric.asymmetry,
          band: 'theta',
          threshold: 0.2,
          smoothing: Duration.zero,
          sustain: Duration(seconds: 3),
          autoMarker: false,
        ),
      ]);
      // Alpha is imbalanced, theta balanced: a theta rule must stay quiet.
      await feed(insight(t7: 16, t8: 8), seconds: 5);
      expect(watch.alerts, isEmpty);
      // Theta imbalanced on T7: now it fires.
      final thetaImbalance = [
        bp('AF3'), bp('T7').copyWithTheta(6), bp('Pz'), bp('T8').copyWithTheta(2), bp('AF4'),
      ];
      await feed(thetaImbalance, seconds: 5);
      expect(watch.alerts.map((a) => a.rule.id), ['theta_asym']);
    });

    test('losing an electrode of the pair restarts the episode on the new pair', () async {
      // Both T7/T8 and AF3/AF4 imbalanced.
      final both = [
        bp('AF3', alpha: 16), bp('T7', alpha: 16), bp('Pz'), bp('T8', alpha: 8), bp('AF4', alpha: 8),
      ];
      await feed(both, seconds: 8);
      expect(watch.holding.keys, contains('asymmetry_sustained'));

      driver.status(EegDeviceStatus(
        contactQuality: const {'AF3': 1, 'T7': 0, 'Pz': 1, 'T8': 1, 'AF4': 1},
        timestamp: now,
      ));
      await Future<void>.delayed(Duration.zero);
      // 8 s on T7/T8 + 5 s on AF3/AF4 is not 10 s on either.
      await feed(both, seconds: 5);
      expect(watch.alerts.where((a) => a.rule.id == 'asymmetry_sustained'), isEmpty);
      await feed(both, seconds: 6);
      final fired = watch.alerts.firstWhere((a) => a.rule.id == 'asymmetry_sustained');
      expect(fired.pair, 'AF3/AF4 (prefrontal)');
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

extension on EegBandPower {
  EegBandPower copyWithTheta(double theta) => EegBandPower(
        channel: channel,
        delta: delta,
        theta: theta,
        alpha: alpha,
        betaLow: betaLow,
        betaHigh: betaHigh,
        gamma: gamma,
        timestamp: timestamp,
      );
}

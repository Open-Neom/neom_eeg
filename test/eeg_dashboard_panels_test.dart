import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:neom_eeg/data/hub/eeg_driver_registry.dart';
import 'package:neom_eeg/data/hub/eeg_hub.dart';
import 'package:neom_eeg/data/implementations/eeg_calibration_controller.dart';
import 'package:neom_eeg/data/implementations/eeg_connection_controller.dart';
import 'package:neom_eeg/data/implementations/eeg_watch_controller.dart';
import 'package:neom_eeg/domain/enums/eeg_device_type.dart';
import 'package:neom_eeg/domain/enums/eeg_vendor.dart';
import 'package:neom_eeg/domain/models/eeg_band_power.dart';
import 'package:neom_eeg/domain/models/eeg_capabilities.dart';
import 'package:neom_eeg/ui/widgets/eeg_live_dashboard.dart';
import 'package:sint/sint.dart';

import 'support/fake_eeg_driver.dart';

void main() {
  late FakeEegDriver driver;
  late EegHub hub;
  late EegConnectionController connection;
  late Directory dir;

  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('neom_eeg_panels_');
    Hive.init(dir.path);
  });

  tearDownAll(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  setUp(() {
    driver = FakeEegDriver(
      vendor: EegVendor.emotiv,
      capabilities: const EegCapabilities(nativeBandPower: true, nativeMentalMetrics: true),
    );
    hub = EegHub(registry: EegDriverRegistry([driver]));
    connection = EegConnectionController(provider: hub);
    Sint.put(connection);
  });

  tearDown(() async {
    Sint.delete<EegConnectionController>(force: true);
    if (Sint.isRegistered<EegCalibrationController>()) {
      Sint.delete<EegCalibrationController>(force: true);
    }
    if (Sint.isRegistered<EegWatchController>()) {
      Sint.delete<EegWatchController>(force: true);
    }
    await hub.dispose();
  });

  Widget app() => const MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: EegLiveDashboard())),
      );

  List<EegBandPower> frame() => [
        for (final ch in ['AF3', 'T7', 'Pz', 'T8', 'AF4'])
          EegBandPower(
            channel: ch,
            delta: 1,
            theta: 2,
            alpha: ch == 'T7' ? 16 : ch == 'T8' ? 8 : 10,
            betaLow: 3,
            betaHigh: 1,
            gamma: 0.5,
            timestamp: DateTime.now(),
          ),
      ];

  testWidgets('without the opt-in controllers the dashboard shows neither section', (tester) async {
    await connection.connectDevice(FakeEegDriver.device(EegDeviceType.emotivInsight));
    await tester.pumpWidget(app());
    await tester.pump();
    expect(find.byKey(const ValueKey('eeg-calibrate')), findsNothing);
    expect(find.byKey(const ValueKey('eeg-auto-markers')), findsNothing);
    expect(find.byKey(const ValueKey('eeg-record-toggle')), findsOneWidget);
  });

  testWidgets('calibration panel opens the routine sheet; watcher shows live indices', (tester) async {
    Sint.put(EegCalibrationController(hub: hub));
    final watch = Sint.put(EegWatchController(hub: hub));
    await connection.connectDevice(FakeEegDriver.device(EegDeviceType.emotivInsight));

    await tester.pumpWidget(app());
    await tester.pump();

    expect(find.text('LÍNEA BASE PERSONAL'), findsOneWidget);
    expect(find.textContaining('Sin calibrar'), findsOneWidget);
    expect(find.textContaining('VIGILANTE'), findsOneWidget);
    expect(find.textContaining('Esperando bandas'), findsWidgets);

    driver.bandPower(frame());
    await tester.pump();
    expect(find.textContaining('ASIM T7/T8'), findsOneWidget);
    expect(find.text('+0.33'), findsOneWidget);
    // Power symmetry is shown as such; spectral coherence only appears
    // with raw EEG, which this test does not send.
    expect(find.text('SIMETRÍA α'), findsOneWidget);
    expect(find.text('COHERENCIA α'), findsNothing);
    expect(find.textContaining('simetría 67%'), findsOneWidget);
    expect(watch.indices.value.isCalibrated, isFalse);

    // Auto-marker switch is wired to the controller.
    expect(watch.autoMarkers.value, isTrue);
    await tester.tap(find.byKey(const ValueKey('eeg-auto-markers')));
    await tester.pump();
    expect(watch.autoMarkers.value, isFalse);

    await tester.tap(find.byKey(const ValueKey('eeg-calibrate')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('eeg-calibration-start')), findsOneWidget);
    expect(find.textContaining('Ojos abiertos · 60 s'), findsOneWidget);
    expect(find.textContaining('Ojos cerrados · 30 s'), findsOneWidget);
  });
}

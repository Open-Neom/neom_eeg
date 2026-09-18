import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:neom_eeg/data/hub/eeg_driver_registry.dart';
import 'package:neom_eeg/data/hub/eeg_hub.dart';
import 'package:neom_eeg/data/providers/eeg_pending_driver.dart';
import 'package:neom_eeg/domain/enums/eeg_connection_state.dart';
import 'package:neom_eeg/domain/enums/eeg_device_type.dart';
import 'package:neom_eeg/domain/enums/eeg_vendor.dart';
import 'package:neom_eeg/domain/models/eeg_band_power.dart';
import 'package:neom_eeg/domain/models/eeg_capabilities.dart';
import 'package:neom_eeg/domain/models/eeg_device_status.dart';
import 'package:neom_eeg/domain/models/eeg_exceptions.dart';
import 'package:neom_eeg/domain/models/eeg_mental_state.dart';
import 'package:neom_eeg/domain/models/eeg_sample.dart';
import 'package:neom_eeg/domain/models/emotiv_cortex_config.dart';

import 'support/fake_eeg_driver.dart';

void main() {
  late FakeEegDriver emotiv;
  late FakeEegDriver muse;
  late EegDriverRegistry registry;
  late EegHub hub;

  EegBandPower bp(String ch, {double alpha = 10, double beta = 2}) =>
      EegBandPower(
        channel: ch,
        delta: 1,
        theta: 2,
        alpha: alpha,
        betaLow: beta,
        betaHigh: beta / 2,
        gamma: 0.5,
        timestamp: DateTime.now(),
      );

  setUp(() {
    emotiv = FakeEegDriver(vendor: EegVendor.emotiv);
    muse = FakeEegDriver(
      vendor: EegVendor.interaxon,
      capabilities: const EegCapabilities(battery: true),
    );
    registry = EegDriverRegistry([emotiv, muse]);
    hub = EegHub(registry: registry);
  });

  tearDown(() => hub.dispose());

  group('registry', () {
    test('routes a model to its vendor driver', () {
      expect(registry.forType(EegDeviceType.emotivInsight), same(emotiv));
      expect(registry.forType(EegDeviceType.emotivEpocFlex), same(emotiv));
      expect(registry.forType(EegDeviceType.muse), same(muse));
      expect(registry.forType(EegDeviceType.openbci), isNull);
      expect(registry.forVendor(EegVendor.emotiv), same(emotiv));
    });

    test('registering a vendor twice replaces and disposes the old driver',
        () {
      final replacement = FakeEegDriver(vendor: EegVendor.emotiv);
      registry.register(replacement);
      expect(registry.forVendor(EegVendor.emotiv), same(replacement));
      expect(emotiv.disposed, isTrue);
      expect(registry.drivers.length, 2);
    });

    test('connectableTypes and reasons follow driver availability', () {
      muse.available = false;
      muse.reason = 'BLE apagado';
      expect(registry.connectableTypes,
          EegDeviceType.ofVendor(EegVendor.emotiv));
      expect(registry.unavailableReasonFor(EegDeviceType.muse), 'BLE apagado');
      expect(registry.unavailableReasonFor(EegDeviceType.emotivMn8), isNull);
      expect(registry.unavailableReasonFor(EegDeviceType.brainbit),
          contains('No hay driver'));
    });

    test('capabilities come from the driver that serves the model', () {
      expect(registry.capabilitiesFor(EegDeviceType.muse).nativeBandPower,
          isFalse);
      expect(registry.capabilitiesFor(EegDeviceType.emotivEpocX).nativeBandPower,
          isTrue);
      expect(registry.capabilitiesFor(EegDeviceType.neurosky),
          EegCapabilities.none);
    });
  });

  group('scan', () {
    test('merges every available driver, sorted by vendor', () async {
      final devices = await hub.scan();
      expect(devices.map((d) => d.vendor),
          [EegVendor.emotiv, EegVendor.interaxon]);
      expect(emotiv.scanCalls, 1);
      expect(muse.scanCalls, 1);
      expect(hub.lastScan.skipped, isEmpty);
      expect(hub.lastScan.errors, isEmpty);
    });

    test('records unavailable and failing drivers instead of throwing',
        () async {
      muse.available = false;
      muse.reason = 'sin BLE';
      final pending = EegPendingDriver.openbci();
      registry.register(pending);
      emotiv.scanError = StateError('Launcher cerrado');

      final report = await hub.scanDetailed();

      expect(report.devices, isEmpty);
      expect(report.skipped[EegVendor.interaxon], 'sin BLE');
      expect(report.skipped[EegVendor.openbci], contains('pendiente'));
      expect(report.errors[EegVendor.emotiv], isA<StateError>());
      expect(muse.scanCalls, 0);
      expect(hub.connectionState, EegConnectionState.disconnected);
    });

    test('can be narrowed to a vendor set', () async {
      await hub.scan(vendors: {EegVendor.interaxon});
      expect(emotiv.scanCalls, 0);
      expect(muse.scanCalls, 1);
    });
  });

  group('connect routing', () {
    test('connects through the driver for the device type', () async {
      final device = FakeEegDriver.device(EegDeviceType.muse);
      await hub.connect(device);

      expect(hub.activeDriver, same(muse));
      expect(hub.activeVendor, EegVendor.interaxon);
      expect(hub.connectedDevice?.id, device.id);
      expect(hub.connectionState, EegConnectionState.streaming);
      expect(emotiv.connectCalls, 0);
      expect(muse.connectCalls, 1);
    });

    test('switching headsets disconnects the previous driver', () async {
      await hub.connect(FakeEegDriver.device(EegDeviceType.muse));
      await hub.connect(FakeEegDriver.device(EegDeviceType.emotivInsight));

      expect(muse.disconnectCalls, 1);
      expect(hub.activeDriver, same(emotiv));
    });

    test('refuses models without a driver', () async {
      await expectLater(
        hub.connect(FakeEegDriver.device(EegDeviceType.openbci)),
        throwsA(isA<EegDriverUnavailableException>()
            .having((e) => e.vendor, 'vendor', EegVendor.openbci)),
      );
      expect(hub.activeDriver, isNull);
    });

    test('refuses drivers that are unavailable here, with the reason',
        () async {
      emotiv.available = false;
      emotiv.reason = 'abre EMOTIV Launcher';
      await expectLater(
        hub.connect(FakeEegDriver.device(EegDeviceType.emotivEpocX)),
        throwsA(isA<EegDriverUnavailableException>()
            .having((e) => e.message, 'message', 'abre EMOTIV Launcher')),
      );
      expect(emotiv.connectCalls, 0);
    });

    test('a failing connect leaves the hub idle in error state', () async {
      muse.connectError = const EegTimeoutException('BLE timeout');
      await expectLater(
        hub.connect(FakeEegDriver.device(EegDeviceType.muse)),
        throwsA(isA<EegTimeoutException>()),
      );
      expect(hub.activeDriver, isNull);
      expect(hub.connectionState, EegConnectionState.error);
    });

    test('connectFirst scans only that vendor and connects the match',
        () async {
      emotiv.discoverable = [
        FakeEegDriver.device(EegDeviceType.emotivEpocX, id: 'epoc'),
        FakeEegDriver.device(EegDeviceType.emotivInsight, id: 'insight'),
      ];
      final chosen = await hub.connectFirst(EegDeviceType.emotivInsight);
      expect(chosen.id, 'insight');
      expect(muse.scanCalls, 0);
      expect(hub.connectedDevice?.id, 'insight');
    });

    test('connectFirst explains when nothing is found', () async {
      muse.discoverable = [];
      await expectLater(
        hub.connectFirst(EegDeviceType.muse),
        throwsA(isA<EegDriverUnavailableException>()
            .having((e) => e.message, 'message', contains('ningún'))),
      );
    });
  });

  group('stream forwarding', () {
    test('native band power and metrics are forwarded untouched', () async {
      await hub.connect(FakeEegDriver.device(EegDeviceType.emotivInsight));
      final pow = hub.bandPowerStream.first;
      final met = hub.mentalStateStream.first;
      final status = hub.statusStream.first;

      emotiv.bandPower([bp('AF3'), bp('T7')]);
      emotiv.mental(EegMentalState(
        engagement: 0.9, relaxation: 0.1, stress: 0.2, focus: 0.8,
        excitement: 0.3, timestamp: DateTime.now(),
      ));
      emotiv.status(EegDeviceStatus(battery: 0.5, timestamp: DateTime.now()));

      expect((await pow).map((b) => b.channel), ['AF3', 'T7']);
      expect((await met).engagement, 0.9);
      expect((await status).battery, 0.5);
    });

    test('band power and metrics are derived from raw when the driver '
        'has none', () async {
      final device = FakeEegDriver.device(EegDeviceType.muse);
      await hub.connect(device);

      final frames = <List<EegBandPower>>[];
      final metrics = <EegMentalState>[];
      final subPow = hub.bandPowerStream.listen(frames.add);
      final subMet = hub.mentalStateStream.listen(metrics.add);

      // 1.5 s of a 10 Hz sine at 256 Hz on every Muse channel.
      final origin = DateTime(2026, 1, 1);
      for (var i = 0; i < 384; i++) {
        final t = i / 256.0;
        final v = 20 * sin(2 * pi * 10 * t);
        muse.raw(EegSample(
          timestamp: origin.add(Duration(microseconds: (t * 1e6).round())),
          channels: {for (final ch in device.channelLabels) ch: v},
          quality: const {},
        ));
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await subPow.cancel();
      await subMet.cancel();

      expect(frames, isNotEmpty);
      final last = frames.last;
      expect(last.map((b) => b.channel), device.channelLabels);
      expect(last.first.dominantBand, 'alpha');
      expect(metrics, isNotEmpty);
      final m = metrics.last;
      expect(m.relaxation, greaterThan(0.5), reason: 'alpha-dominant');
      expect(m.stress, lessThan(0.5));
      expect(hub.effectiveCapabilities?.nativeBandPower, isTrue);
      expect(hub.effectiveCapabilities?.nativeMentalMetrics, isTrue);
    });

    test('native drivers ignore derivation unless mode is derived', () async {
      await hub.connect(FakeEegDriver.device(EegDeviceType.emotivInsight));
      var frames = 0;
      final sub = hub.bandPowerStream.listen((_) => frames++);
      for (var i = 0; i < 128; i++) {
        emotiv.raw(EegSample(
          timestamp: DateTime(2026).add(Duration(milliseconds: i * 8)),
          channels: const {'AF3': 1.0},
          quality: const {},
        ));
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await sub.cancel();
      expect(frames, 0);
    });

    test('mode derived forces the processor even on native drivers',
        () async {
      await hub.dispose();
      emotiv = FakeEegDriver(vendor: EegVendor.emotiv);
      hub = EegHub(
        registry: EegDriverRegistry([emotiv]),
        bandPowerMode: EegBandPowerMode.derived,
      );
      final device = FakeEegDriver.device(EegDeviceType.emotivInsight);
      await hub.connect(device);

      final frames = <List<EegBandPower>>[];
      final sub = hub.bandPowerStream.listen(frames.add);
      emotiv.bandPower([bp('AF3')]); // native frame must be ignored
      for (var i = 0; i < 160; i++) {
        emotiv.raw(EegSample(
          timestamp: DateTime(2026).add(Duration(microseconds: i * 7812)),
          channels: {for (final ch in device.channelLabels) ch: sin(i / 2.0)},
          quality: const {},
        ));
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await sub.cancel();
      expect(frames, isNotEmpty);
      expect(frames.first.length, device.channels.length,
          reason: 'derived frames cover every channel, not just AF3');
    });

    test('mode native never derives, so Muse emits no band power', () async {
      await hub.dispose();
      muse = FakeEegDriver(
        vendor: EegVendor.interaxon,
        capabilities: const EegCapabilities(),
      );
      hub = EegHub(
        registry: EegDriverRegistry([muse]),
        bandPowerMode: EegBandPowerMode.native,
      );
      await hub.connect(FakeEegDriver.device(EegDeviceType.muse));
      var frames = 0;
      final sub = hub.bandPowerStream.listen((_) => frames++);
      for (var i = 0; i < 512; i++) {
        muse.raw(EegSample(
          timestamp: DateTime(2026).add(Duration(microseconds: i * 3906)),
          channels: const {'TP9': 1.0},
          quality: const {},
        ));
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await sub.cancel();
      expect(frames, 0);
      expect(hub.effectiveCapabilities?.nativeBandPower, isFalse);
    });
  });

  group('contact quality filtering', () {
    test('an electrode with no contact is dropped from band-power frames',
        () async {
      await hub.connect(FakeEegDriver.device(EegDeviceType.emotivInsight));
      final frames = <List<EegBandPower>>[];
      final sub = hub.bandPowerStream.listen(frames.add);

      // Insight with the Pz tip missing: Cortex dev reports CQ 0 for Pz.
      emotiv.status(EegDeviceStatus(
        contactQuality: const {'AF3': 1.0, 'T7': 0.75, 'Pz': 0.0, 'T8': 1.0,
          'AF4': 0.5},
        timestamp: DateTime.now(),
      ));
      await Future<void>.delayed(Duration.zero);
      emotiv.bandPower([bp('AF3'), bp('T7'), bp('Pz', alpha: 900),
        bp('T8'), bp('AF4')]);
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(hub.excludedChannels, ['Pz']);
      expect(frames.single.map((b) => b.channel), ['AF3', 'T7', 'T8', 'AF4']);
    });

    test('poor-but-present contact (CQ 1/4) is kept by default', () async {
      await hub.connect(FakeEegDriver.device(EegDeviceType.emotivInsight));
      emotiv.status(EegDeviceStatus(
        contactQuality: const {'AF3': 0.25, 'T7': 1.0},
        timestamp: DateTime.now(),
      ));
      await Future<void>.delayed(Duration.zero);
      expect(hub.excludedChannels, isEmpty);
    });

    test('derived metrics use the filtered frame', () async {
      await hub.connect(FakeEegDriver.device(EegDeviceType.muse));
      final metrics = <EegMentalState>[];
      final sub = hub.mentalStateStream.listen(metrics.add);
      muse.status(EegDeviceStatus(
        contactQuality: const {'TP9': 0.0, 'AF7': 1.0, 'AF8': 1.0, 'TP10': 1.0},
        timestamp: DateTime.now(),
      ));
      await Future<void>.delayed(Duration.zero);
      // Muse derives from raw; feed one full window with a huge beta burst on
      // the dead electrode only. If it were included, stress would spike.
      final device = FakeEegDriver.device(EegDeviceType.muse);
      for (var i = 0; i < 300; i++) {
        final t = i / 256.0;
        muse.raw(EegSample(
          timestamp: DateTime(2026).add(Duration(microseconds: (t * 1e6).round())),
          channels: {
            'TP9': 500 * sin(2 * pi * 25 * t),
            for (final ch in device.channelLabels.skip(1)) ch: 10 * sin(2 * pi * 10 * t),
          },
          quality: const {},
        ));
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await sub.cancel();
      expect(metrics, isNotEmpty);
      expect(metrics.last.stress, lessThan(0.3));
      expect(metrics.last.relaxation, greaterThan(0.5));
    });

    test('never publishes an empty frame when every electrode is off', () async {
      await hub.connect(FakeEegDriver.device(EegDeviceType.emotivMn8));
      emotiv.status(EegDeviceStatus(
        contactQuality: const {'AF7': 0.0, 'AF8': 0.0},
        timestamp: DateTime.now(),
      ));
      await Future<void>.delayed(Duration.zero);
      final next = hub.bandPowerStream.first;
      emotiv.bandPower([bp('AF7'), bp('AF8')]);
      expect((await next).length, 2);
    });

    test('minContactQuality 0 disables the filter', () async {
      await hub.dispose();
      emotiv = FakeEegDriver(vendor: EegVendor.emotiv);
      hub = EegHub(registry: EegDriverRegistry([emotiv]), minContactQuality: 0);
      await hub.connect(FakeEegDriver.device(EegDeviceType.emotivInsight));
      emotiv.status(EegDeviceStatus(
        contactQuality: const {'Pz': 0.0},
        timestamp: DateTime.now(),
      ));
      await Future<void>.delayed(Duration.zero);
      final next = hub.bandPowerStream.first;
      emotiv.bandPower([bp('AF3'), bp('Pz')]);
      expect((await next).length, 2);
      expect(hub.excludedChannels, isEmpty);
    });
  });

  group('lifecycle', () {
    test('a driver dropping on its own returns the hub to idle', () async {
      await hub.connect(FakeEegDriver.device(EegDeviceType.muse));
      final states = <EegConnectionState>[];
      final sub = hub.connectionStateStream.listen(states.add);

      muse.drop(EegConnectionState.disconnected);
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(states, contains(EegConnectionState.disconnected));
      expect(hub.activeDriver, isNull);
      expect(hub.connectionState, EegConnectionState.disconnected);

      // Data from the dropped driver no longer reaches the hub.
      var frames = 0;
      final s2 = hub.bandPowerStream.listen((_) => frames++);
      muse.bandPower([bp('TP9')]);
      await Future<void>.delayed(Duration.zero);
      await s2.cancel();
      expect(frames, 0);
    });

    test('disconnect clears the active driver', () async {
      await hub.connect(FakeEegDriver.device(EegDeviceType.emotivEpocX));
      await hub.disconnect();
      expect(hub.activeDriver, isNull);
      expect(emotiv.disconnectCalls, 1);
      expect(hub.connectionState, EegConnectionState.disconnected);
    });

    test('catalog lists every model with its availability', () {
      muse.available = false;
      muse.reason = 'sin BLE';
      final catalog = hub.catalog;
      expect(catalog.length, EegDeviceType.values.length);
      expect(catalog[EegDeviceType.emotivInsight], isNull);
      expect(catalog[EegDeviceType.muse], 'sin BLE');
      expect(catalog[EegDeviceType.brainbit], contains('No hay driver'));
    });

    test('dispose disposes every driver and rejects further use', () async {
      await hub.dispose();
      expect(emotiv.disposed, isTrue);
      expect(muse.disposed, isTrue);
      expect(() => hub.scan(), throwsA(isA<EegException>()));
    });
  });

  group('EegHub.standard', () {
    test('registers the stock drivers and pending vendors', () {
      final h = EegHub.standard(includeSimulated: true);
      expect(h.registry.vendors, containsAll([
        EegVendor.interaxon,
        EegVendor.openbci,
        EegVendor.brainbit,
        EegVendor.neurosky,
        EegVendor.simulated,
      ]));
      expect(h.registry.forVendor(EegVendor.emotiv), isNull,
          reason: 'no Emotiv credentials given');
      expect(h.catalog[EegDeviceType.openbciGanglion], contains('pendiente'));
      h.dispose();
    });

    test('adds Emotiv when configured', () {
      final h = EegHub.standard(
        emotiv: const EmotivCortexConfig(clientId: 'id', clientSecret: 'secret'),
        includeSimulated: false,
        includeMuse: false,
        includePending: false,
      );
      expect(h.registry.vendors, [EegVendor.emotiv]);
      h.dispose();
    });
  });
}

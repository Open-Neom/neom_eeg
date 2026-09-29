import 'dart:async';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:neom_core/domain/model/neom/neom_neuro_state.dart';
import 'package:neom_eeg/domain/enums/eeg_connection_state.dart';
import 'package:neom_eeg/domain/models/eeg_band_power.dart';
import 'package:neom_eeg/domain/models/eeg_device_info.dart';
import 'package:neom_eeg/domain/models/eeg_mental_state.dart';
import 'package:neom_eeg/domain/models/eeg_sample.dart';
import 'package:neom_eeg/domain/use_cases/eeg_device_service.dart';
import 'package:neom_eeg/data/hub/eeg_driver_registry.dart';
import 'package:neom_eeg/data/hub/eeg_hub.dart';
import 'package:neom_eeg/data/implementations/eeg_neuro_state_adapter.dart';
import 'package:neom_eeg/domain/enums/eeg_device_type.dart';
import 'package:neom_eeg/domain/enums/eeg_vendor.dart';

import 'support/fake_eeg_driver.dart';

/// Feeds band powers by hand so each state can be provoked deterministically.
class _FakeDevice implements EegDeviceService {
  final _bandPower = StreamController<List<EegBandPower>>.broadcast();

  @override
  Stream<List<EegBandPower>> get bandPowerStream => _bandPower.stream;

  @override
  EegConnectionState connectionState = EegConnectionState.connected;

  void emit(List<EegBandPower> readings) => _bandPower.add(readings);
  Future<void> close() => _bandPower.close();

  @override
  Stream<EegSample> get rawStream => const Stream.empty();
  @override
  Stream<EegMentalState> get mentalStateStream => const Stream.empty();
  @override
  EegDeviceInfo? get connectedDevice => null;
  @override
  Future<void> connect(EegDeviceInfo device) async {}
  @override
  Future<void> disconnect() async {}
  @override
  Future<List<EegDeviceInfo>> scan({Duration timeout = const Duration(seconds: 10)}) async => [];
}

/// A reading where [dominant] carries most of the power.
EegBandPower reading(String channel, String dominant, {double share = 10}) {
  double v(String b) => b == dominant ? share : 1.0;
  return EegBandPower(
    channel: channel,
    delta: v('delta'),
    theta: v('theta'),
    alpha: v('alpha'),
    betaLow: dominant == 'beta' ? share / 2 : 0.5,
    betaHigh: dominant == 'beta' ? share / 2 : 0.5,
    gamma: v('gamma'),
    timestamp: DateTime.now(),
  );
}

void main() {
  late _FakeDevice device;
  late EegNeuroStateAdapter adapter;

  setUp(() {
    device = _FakeDevice();
    adapter = EegNeuroStateAdapter(deviceService: device);
  });

  tearDown(() async {
    await adapter.dispose();
    await device.close();
  });

  group('band to state', () {
    Future<NeomNeuroState> stateFor(String dominant) async {
      await adapter.start();
      final next = adapter.stateStream.first;
      device.emit([reading('AF3', dominant), reading('AF4', dominant)]);
      return (await next).state;
    }

    test('delta reads as sleep', () async {
      expect(await stateFor('delta'), NeomNeuroState.sleep);
    });

    test('theta reads as creativity', () async {
      expect(await stateFor('theta'), NeomNeuroState.creativity);
    });

    test('alpha reads as calm', () async {
      expect(await stateFor('alpha'), NeomNeuroState.calm);
    });

    test('beta reads as focus', () async {
      expect(await stateFor('beta'), NeomNeuroState.focus);
    });

    test('gamma reads as integration', () async {
      expect(await stateFor('gamma'), NeomNeuroState.integration);
    });
  });

  group('snapshot', () {
    test('carries the band frequency and the state value', () async {
      await adapter.start();
      final next = adapter.stateStream.first;
      device.emit([reading('AF3', 'alpha'), reading('AF4', 'alpha')]);
      final s = await next;

      expect(s.frequency, 10.0);
      expect(s.neuro, NeomNeuroState.calm.normalizedValue);
      expect(s.amplitude, greaterThan(0));
    });

    test('leaves audio-only fields at zero', () async {
      // A headset has no source for these; inventing them would be worse.
      await adapter.start();
      final next = adapter.stateStream.first;
      device.emit([reading('AF3', 'beta'), reading('AF4', 'beta')]);
      final s = await next;

      expect(s.breath, 0.0);
      expect(s.beat, 0.0);
      expect(s.phase, 0.0);
    });

    test('agreeing channels read as coherent', () async {
      await adapter.start();
      final next = adapter.stateStream.first;
      device.emit([reading('AF3', 'alpha'), reading('AF4', 'alpha')]);

      expect((await next).coherence, greaterThan(0.9));
    });

    test('disagreeing channels lower coherence', () async {
      await adapter.start();
      final next = adapter.stateStream.first;
      device.emit([reading('AF3', 'alpha', share: 40), reading('AF4', 'alpha', share: 1.2)]);

      expect((await next).coherence, lessThan(0.9));
    });

    test('a single channel cannot establish coherence', () async {
      await adapter.start();
      final next = adapter.stateStream.first;
      device.emit([reading('AF3', 'alpha')]);

      expect((await next).coherence, 0.0);
      expect(adapter.coherenceKind, EegCoherenceKind.none);
    });

    test('without raw EEG the value is alpha power symmetry, and says so', () async {
      await adapter.start();
      final next = adapter.stateStream.first;
      device.emit([reading('AF3', 'alpha'), reading('AF4', 'alpha')]);
      expect((await next).coherence, closeTo(1.0, 1e-9));
      expect(adapter.coherenceKind, EegCoherenceKind.symmetry);
    });

    test('with a hub delivering raw EEG it is spectral coherence', () async {
      final driver = FakeEegDriver(vendor: EegVendor.emotiv);
      final hub = EegHub(registry: EegDriverRegistry([driver]));
      await hub.connect(FakeEegDriver.device(EegDeviceType.emotivInsight));
      final onHub = EegNeuroStateAdapter(deviceService: hub);
      await onHub.start();

      // Independent noise on T7 and T8: power balanced, oscillations not.
      final rnd = Random(8);
      double g() => sqrt(-2 * log(1 - rnd.nextDouble())) * cos(2 * pi * rnd.nextDouble());
      for (var i = 0; i < 4 * 128; i++) {
        driver.raw(EegSample(
          timestamp: DateTime.now(),
          channels: {for (final ch in ['AF3', 'T7', 'Pz', 'T8', 'AF4']) ch: 4200 + 5 * g()},
          quality: const {},
        ));
      }
      await Future<void>.delayed(Duration.zero);
      expect(hub.lastCoherence, isNotNull);

      final next = onHub.stateStream.first;
      driver.bandPower([
        for (final ch in ['AF3', 'T7', 'Pz', 'T8', 'AF4']) reading(ch, 'alpha'),
      ]);
      final snap = await next;
      expect(onHub.coherenceKind, EegCoherenceKind.spectral);
      // Symmetry would say 1.0; the signals do not oscillate together.
      expect(snap.coherence, lessThan(0.5));
      expect(snap.coherence, closeTo(hub.lastCoherence!.of('alpha')!, 1e-9));

      // Unplugging the headset is announced, not left as a frozen reading.
      final after = onHub.stateStream.first;
      await hub.disconnect();
      expect((await after).state, NeomNeuroState.neutral);
      expect(onHub.isActive, isFalse);

      await onHub.dispose();
      await hub.dispose();
    });
  });

  group('lifecycle', () {
    test('starts neutral', () {
      expect(adapter.currentState, NeomNeuroState.neutral);
      expect(adapter.latestSnapshot.state, NeomNeuroState.neutral);
    });

    test('latestSnapshot tracks the stream', () async {
      await adapter.start();
      final next = adapter.stateStream.first;
      device.emit([reading('AF3', 'beta'), reading('AF4', 'beta')]);
      await next;

      expect(adapter.latestSnapshot.state, NeomNeuroState.focus);
      expect(adapter.currentState, NeomNeuroState.focus);
    });

    test('is inactive until started', () {
      expect(adapter.isActive, isFalse);
    });

    test('is inactive while the headset is disconnected', () async {
      await adapter.start();
      device.connectionState = EegConnectionState.disconnected;

      expect(adapter.isActive, isFalse);
    });

    test('stop detaches from the device', () async {
      await adapter.start();
      await adapter.stop();
      device.emit([reading('AF3', 'gamma'), reading('AF4', 'gamma')]);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(adapter.currentState, NeomNeuroState.neutral);
    });

    test('empty or silent readings emit nothing', () async {
      await adapter.start();
      var emitted = 0;
      adapter.stateStream.listen((_) => emitted++);

      device.emit([]);
      device.emit([EegBandPower(channel: 'AF3', delta: 0, theta: 0, alpha: 0,
          betaLow: 0, betaHigh: 0, gamma: 0, timestamp: DateTime.now())]);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(emitted, 0);
    });
  });

  group('neurofeedback target', () {
    test('no target by default', () {
      expect(adapter.targetState, isNull);
      expect(adapter.targetProximity, isNull);
    });

    test('setNeuroState records a goal without forcing the reading', () async {
      await adapter.start();
      adapter.setNeuroState(NeomNeuroState.calm);

      final next = adapter.stateStream.first;
      device.emit([reading('AF3', 'beta'), reading('AF4', 'beta')]);
      await next;

      // The headset still reports what the brain is doing.
      expect(adapter.targetState, NeomNeuroState.calm);
      expect(adapter.currentState, NeomNeuroState.focus);
    });

    test('proximity is 1.0 when the target is being held', () async {
      await adapter.start();
      adapter.setNeuroState(NeomNeuroState.calm);

      final next = adapter.stateStream.first;
      device.emit([reading('AF3', 'alpha'), reading('AF4', 'alpha')]);
      await next;

      expect(adapter.targetProximity, closeTo(1.0, 1e-9));
    });
  });
}

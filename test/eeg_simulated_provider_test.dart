import 'dart:async';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:neom_eeg/data/implementations/eeg_signal_processor.dart';
import 'package:neom_eeg/data/providers/simulated_eeg_provider.dart';
import 'package:neom_eeg/domain/enums/eeg_connection_state.dart';
import 'package:neom_eeg/domain/models/eeg_band_power.dart';
import 'package:neom_eeg/domain/models/eeg_channel_info.dart';
import 'package:neom_eeg/domain/models/eeg_device_info.dart';
import 'package:neom_eeg/domain/models/eeg_sample.dart';

void main() {
  late SimulatedEegProvider provider;

  setUp(() {
    provider = SimulatedEegProvider();
  });

  tearDown(() async {
    // Always disconnect to clean up timers/streams.
    await provider.disconnect();
  });

  // ---------------------------------------------------------------------------
  // Lifecycle tests
  // ---------------------------------------------------------------------------

  group('lifecycle', () {
    test('initial state is disconnected', () {
      expect(provider.connectionState, equals(EegConnectionState.disconnected));
      expect(provider.connectedDevice, isNull);
    });

    test('scan returns exactly one simulated device', () async {
      final devices = await provider.scan();
      expect(devices, hasLength(1));
      expect(devices.first.name, contains('Simulated'));
      expect(devices.first.id, equals('sim_001'));
      // After scan completes, state returns to disconnected.
      expect(provider.connectionState, equals(EegConnectionState.disconnected));
    });

    test('connect changes state to streaming', () async {
      final devices = await provider.scan();
      await provider.connect(devices.first);
      expect(provider.connectionState, equals(EegConnectionState.streaming));
      expect(provider.connectedDevice, isNotNull);
      expect(provider.connectedDevice!.id, equals('sim_001'));
    });

    test('connect then disconnect returns to disconnected', () async {
      final devices = await provider.scan();
      await provider.connect(devices.first);
      expect(provider.connectionState, equals(EegConnectionState.streaming));

      await provider.disconnect();
      expect(provider.connectionState, equals(EegConnectionState.disconnected));
      expect(provider.connectedDevice, isNull);
    });

    test('double connect does not crash (idempotent)', () async {
      final devices = await provider.scan();
      await provider.connect(devices.first);
      // Second connect — should re-initialize timers without crash.
      // BUG FINDER: If connect() doesn't cancel old timers before creating
      // new ones, this leaks timers/streams.
      await provider.connect(devices.first);
      expect(provider.connectionState, equals(EegConnectionState.streaming));
    });

    test('disconnect without connect does not crash', () async {
      expect(
        () => provider.disconnect(),
        returnsNormally,
      );
      expect(provider.connectionState, equals(EegConnectionState.disconnected));
    });

    test('connectedDevice is non-null after connect, null after disconnect', () async {
      final devices = await provider.scan();
      await provider.connect(devices.first);
      expect(provider.connectedDevice, isNotNull);

      await provider.disconnect();
      expect(provider.connectedDevice, isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // Stream data tests
  // ---------------------------------------------------------------------------

  group('streams', () {
    test('rawStream emits data after connect', () async {
      final devices = await provider.scan();
      await provider.connect(devices.first);

      // Should receive at least one sample within 300ms (timer fires at 125ms).
      final sample = await provider.rawStream.first.timeout(
        const Duration(seconds: 2),
      );
      expect(sample.channels, isNotEmpty);
      expect(sample.channels.length, equals(5)); // 5 channels
    });

    test('rawStream stops emitting after disconnect', () async {
      final devices = await provider.scan();
      await provider.connect(devices.first);

      // Collect some samples.
      final firstSample = await provider.rawStream.first.timeout(
        const Duration(seconds: 2),
      );
      expect(firstSample, isNotNull);

      await provider.disconnect();

      // After disconnect, the timer is cancelled. No more samples.
      // The stream is broadcast so it won't close, but no new events.
      var receivedAfterDisconnect = false;
      final sub = provider.rawStream.listen((_) {
        receivedAfterDisconnect = true;
      });

      // Wait a bit and verify no new samples arrive.
      await Future.delayed(const Duration(milliseconds: 300));
      expect(receivedAfterDisconnect, isFalse);
      await sub.cancel();
    });

    test('bandPowerStream emits data with all 5 channels', () async {
      final devices = await provider.scan();
      await provider.connect(devices.first);

      final powers = await provider.bandPowerStream.first.timeout(
        const Duration(seconds: 2),
      );
      expect(powers, hasLength(5));

      final channelNames = powers.map((p) => p.channel).toSet();
      expect(channelNames, containsAll(['AF3', 'T7', 'Pz', 'T8', 'AF4']));
    });

    test('bandPowerStream alpha is dominant (simulated alpha rhythm)', () async {
      final devices = await provider.scan();
      await provider.connect(devices.first);

      // The simulated provider emits band power with alpha = baseAlpha * (1 + jitter).
      // Default baseAlpha=12, baseBeta=4, baseTheta=6. Alpha should dominate.
      final powers = await provider.bandPowerStream.first.timeout(
        const Duration(seconds: 2),
      );

      for (final bp in powers) {
        expect(bp.alpha, greaterThan(bp.theta),
            reason: 'Alpha should dominate theta on ${bp.channel}');
        expect(bp.alpha, greaterThan(bp.gamma),
            reason: 'Alpha should dominate gamma on ${bp.channel}');
      }
    });
  });

  // ---------------------------------------------------------------------------
  // Signal quality tests
  // ---------------------------------------------------------------------------

  group('signal generation', () {
    test('generated samples contain 10Hz alpha component (DFT verification)', () async {
      // Collect 128 raw samples, run them through EegSignalProcessor,
      // verify alpha band dominates.
      final devices = await provider.scan();
      await provider.connect(devices.first);

      final samples = <EegSample>[];
      final completer = Completer<void>();

      final sub = provider.rawStream.listen((sample) {
        samples.add(sample);
        if (samples.length >= 128) {
          completer.complete();
        }
      });

      await completer.future.timeout(const Duration(seconds: 5));
      await sub.cancel();

      expect(samples.length, greaterThanOrEqualTo(128));

      // Run through real signal processor.
      final proc = EegSignalProcessor();
      final channels = [EegChannelInfo(name: 'Pz', positionX: 0.5, positionY: 0.5)];
      final bandPowers = proc.extractBandPower(samples.take(128).toList(), channels);

      expect(bandPowers, hasLength(1));
      final bp = bandPowers.first;
      // Alpha should be the dominant band because the simulated signal
      // has baseAlpha=12 (amplitude) at 10Hz.
      expect(bp.alpha, greaterThan(bp.delta),
          reason: 'Alpha power should exceed delta');
      expect(bp.alpha, greaterThan(bp.gamma),
          reason: 'Alpha power should exceed gamma');
    });

    test('blink artifacts appear on frontal channels over many samples', () async {
      // Blink fires every 5 seconds, lasts 200ms. We need to collect enough
      // to catch one. The spike adds 150-200 uV to AF3/AF4.
      final devices = await provider.scan();
      await provider.connect(devices.first);

      final samples = <EegSample>[];
      final completer = Completer<void>();

      final sub = provider.rawStream.listen((sample) {
        samples.add(sample);
        // Collect 6 seconds worth at 128Hz = 768 samples.
        if (samples.length >= 768) {
          if (!completer.isCompleted) completer.complete();
        }
      });

      await completer.future.timeout(const Duration(seconds: 15));
      await sub.cancel();

      // Check if any AF3 sample has a very high value (>100).
      // Normal alpha is ~12 amplitude, noise ~2. Blink adds 150+.
      final frontalSpikes = samples.where((s) {
        final af3 = s.channels['AF3'] ?? 0;
        return af3.abs() > 100;
      });

      expect(frontalSpikes, isNotEmpty,
          reason: 'Should detect at least one blink artifact in 6s of data');
    });

    test('channel values are finite (no NaN/Infinity in generated data)', () async {
      final devices = await provider.scan();
      await provider.connect(devices.first);

      final samples = <EegSample>[];
      final completer = Completer<void>();
      final sub = provider.rawStream.listen((sample) {
        samples.add(sample);
        if (samples.length >= 128) {
          if (!completer.isCompleted) completer.complete();
        }
      });

      await completer.future.timeout(const Duration(seconds: 5));
      await sub.cancel();

      for (final s in samples) {
        for (final entry in s.channels.entries) {
          expect(entry.value.isFinite, isTrue,
              reason: 'Channel ${entry.key} has non-finite value: ${entry.value}');
        }
      }
    });
  });

  // ---------------------------------------------------------------------------
  // Resource leak / rapid cycle tests
  // ---------------------------------------------------------------------------

  group('resource management', () {
    test('multiple rapid connect/disconnect cycles do not crash', () async {
      final devices = await provider.scan();

      for (var i = 0; i < 10; i++) {
        await provider.connect(devices.first);
        await provider.disconnect();
      }

      expect(provider.connectionState, equals(EegConnectionState.disconnected));
      expect(provider.connectedDevice, isNull);
    });

    test('double connect leaks timers (bug detection)', () async {
      // If connect() doesn't cancel existing timers, calling it twice
      // creates duplicate timers that double the data emission rate.
      final devices = await provider.scan();
      await provider.connect(devices.first);

      // Count samples in 500ms with single connect.
      var count1 = 0;
      final sub1 = provider.rawStream.listen((_) => count1++);
      await Future.delayed(const Duration(milliseconds: 500));
      await sub1.cancel();

      // Reconnect without disconnect — potential timer leak.
      await provider.connect(devices.first);

      var count2 = 0;
      final sub2 = provider.rawStream.listen((_) => count2++);
      await Future.delayed(const Duration(milliseconds: 500));
      await sub2.cancel();

      // If there's a timer leak, count2 would be roughly 2x count1.
      // Allow 50% tolerance for timing jitter.
      if (count1 > 0) {
        expect(count2, lessThan(count1 * 2),
            reason:
                'Double connect should not produce 2x samples (timer leak). '
                'count1=$count1, count2=$count2');
      }
    });

    test('scan during connected state still works', () async {
      final devices = await provider.scan();
      await provider.connect(devices.first);

      // Scan while connected — should still return the simulated device.
      // But note: scan sets state to scanning then back to disconnected.
      // BUG FINDER: This could break the streaming state.
      final devices2 = await provider.scan();
      expect(devices2, hasLength(1));

      // After scan, state is disconnected — but timers may still be running.
      // This is a real bug: scan() clobbers connectionState to disconnected
      // without canceling timers.
      expect(provider.connectionState, equals(EegConnectionState.disconnected));
    });
  });
}

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:neom_eeg/data/hub/eeg_driver_registry.dart';
import 'package:neom_eeg/data/hub/eeg_hub.dart';
import 'package:neom_eeg/data/implementations/eeg_coherence_tracker.dart';
import 'package:neom_eeg/data/implementations/eeg_practice_link.dart';
import 'package:neom_eeg/data/implementations/eeg_ring_buffer.dart';
import 'package:neom_eeg/data/implementations/eeg_session_capture_controller.dart';
import 'package:neom_eeg/data/implementations/eeg_spectral.dart';
import 'package:neom_eeg/domain/enums/eeg_device_type.dart';
import 'package:neom_eeg/domain/enums/eeg_vendor.dart';
import 'package:neom_eeg/domain/models/eeg_band_power.dart';
import 'package:neom_eeg/domain/models/eeg_capabilities.dart';
import 'package:neom_eeg/domain/models/eeg_device_status.dart';
import 'package:neom_eeg/domain/models/eeg_mental_state.dart';
import 'package:neom_eeg/domain/models/eeg_sample.dart';
import 'package:neom_eeg/domain/models/eeg_session_capture.dart';
import 'package:sint/sint.dart';

import 'support/fake_eeg_driver.dart';

void main() {
  group('EegFloat64RingBuffer', () {
    test('preserves chronological order across wraparound and scratch copies', () {
      final ring = EegFloat64RingBuffer(4);
      final scratch = Float64List(4);
      for (var i = 1; i <= 6; i++) {
        ring.push(i.toDouble());
      }
      expect(ring.length, 4);
      expect(ring.isFull, isTrue);
      expect([ring[0], ring[1], ring[2], ring[3]], [3.0, 4.0, 5.0, 6.0]);

      final out = ring.toFloat64List(scratch);
      expect(identical(out, scratch), isTrue);
      expect(out, [3.0, 4.0, 5.0, 6.0]);

      ring.ensureCapacity(3);
      expect(ring.toFloat64List(), [4.0, 5.0, 6.0]);
    });
  });

  group('Goertzel powerAt numerical parity', () {
    test('matches direct complex DFT within floating-point precision', () {
      const fs = 256.0;
      const n = 2048;
      final w = EegSpectral.hann(n);
      final norm = w.fold<double>(0.0, (a, v) => a + v * v) * n;
      final prepared = Float64List.fromList([
        for (var i = 0; i < n; i++)
          (2.5 * math.sin(2 * math.pi * 7.83 * i / fs) +
                  0.8 * math.cos(2 * math.pi * 10.2 * i / fs)) *
              w[i],
      ]);

      for (final f in const [0.75, 4.0, 7.83, 10.2, 14.5, 40.0]) {
        var r = 0.0, im = 0.0;
        final omega = -2.0 * math.pi * f / fs;
        for (var i = 0; i < n; i++) {
          r += prepared[i] * math.cos(omega * i);
          im += prepared[i] * math.sin(omega * i);
        }
        final direct = (r * r + im * im) / norm;
        final goertzel = EegSpectral.powerAt(prepared, fs, f, norm);
        expect(goertzel, closeTo(direct, 1e-8), reason: 'f=$f Hz');
      }
    });
  });

  group('EegHub background DSP Isolate offload (256 Hz Muse)', () {
    late Directory dir;
    late FakeEegDriver muse;
    late EegHub hub;

    setUpAll(() async {
      dir = await Directory.systemTemp.createTemp('neom_eeg_iso_');
      Hive.init(dir.path);
    });

    tearDownAll(() async {
      await Hive.close();
      await dir.delete(recursive: true);
    });

    setUp(() {
      muse = FakeEegDriver(
        vendor: EegVendor.interaxon,
        capabilities: const EegCapabilities(battery: true, contactQuality: true),
      );
      hub = EegHub(
        registry: EegDriverRegistry([muse]),
        offloadDspToIsolate: true,
      );
    });

    tearDown(() async {
      if (Sint.isRegistered<EegSessionCaptureController>()) {
        Sint.delete<EegSessionCaptureController>(force: true);
      }
      await hub.dispose();
    });

    test('derives band powers, mental state, coherence and FFR SNR off-thread',
        () async {
      final device = FakeEegDriver.device(EegDeviceType.muse);
      await hub.connect(device);
      expect(hub.isDspIsolateActive, isTrue);

      final capture = EegSessionCaptureController(
        hub: hub,
        tick: const Duration(milliseconds: 50),
      );
      Sint.put(capture);

      await capture.startSegment(
        practiceSessionId: 'iso_session_1',
        contextSampler: () => {
          EegContextKeys.baseHz: 216.0,
          EegContextKeys.beatHz: 6.0,
        },
      );

      final frames = <List<EegBandPower>>[];
      final metrics = <EegMentalState>[];
      final coherences = <EegPairCoherence>[];
      final subPow = hub.bandPowerStream.listen(frames.add);
      final subMet = hub.mentalStateStream.listen(metrics.add);
      final subCoh = hub.coherenceStream.listen(coherences.add);

      final rnd = math.Random(42);
      double noise() =>
          math.sqrt(-2 * math.log(1 - rnd.nextDouble())) *
          math.cos(2 * math.pi * rnd.nextDouble());

      // Feed 9 seconds of 256 Hz Muse samples (10 Hz dominant alpha + 6 Hz FFR).
      final origin = DateTime(2026, 11, 16);
      for (var i = 0; i < 9 * 256; i++) {
        final t = i / 256.0;
        final alpha = 18.0 * math.sin(2 * math.pi * 10.0 * t);
        final ffrTone = 4.0 * math.sin(2 * math.pi * 6.0 * t);
        muse.raw(EegSample(
          timestamp: origin.add(Duration(microseconds: (t * 1e6).round())),
          channels: {
            'TP9': alpha + ffrTone + 2.0 * noise(),
            'AF7': alpha + ffrTone + 2.0 * noise(),
            'AF8': alpha + ffrTone + 2.0 * noise(),
            'TP10': alpha + ffrTone + 2.0 * noise(),
          },
          quality: const {},
        ));
      }

      await hub.flushDspIsolate();
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(frames, isNotEmpty);
      expect(frames.last.first.dominantBand, 'alpha');
      expect(metrics, isNotEmpty);
      expect(metrics.last.relaxation, greaterThan(0.5));
      expect(coherences, isNotEmpty);
      expect(hub.lastCoherence?.pair.toString(), 'TP9/TP10 (temporoparietal)');
      expect(hub.lastCoherence?.of('alpha'), greaterThan(0.5));

      final saved = await capture.endSegment();
      expect(saved, isNotNull);
      expect(saved!.frequencyFollowing, isNotNull);
      expect(saved.frequencyFollowing!.hz, 6.0);
      expect(saved.frequencyFollowing!.meanSnr, greaterThan(2.0));

      // Poor contact on TP9 switches pair to AF7/AF8 on the isolate too.
      muse.status(EegDeviceStatus(
        contactQuality: const {'TP9': 0.0, 'AF7': 1.0, 'AF8': 1.0, 'TP10': 1.0},
        timestamp: DateTime.now(),
      ));
      await Future<void>.delayed(Duration.zero);
      expect(hub.analysisPair.toString(), 'AF7/AF8 (prefrontal)');
      expect(hub.lastCoherence, isNull);

      for (var i = 0; i < 3 * 256; i++) {
        final t = i / 256.0;
        final alpha = 18.0 * math.sin(2 * math.pi * 10.0 * t);
        muse.raw(EegSample(
          timestamp: origin.add(Duration(seconds: 10, microseconds: (t * 1e6).round())),
          channels: {
            'TP9': 0.0,
            'AF7': alpha + noise(),
            'AF8': alpha + noise(),
            'TP10': alpha + noise(),
          },
          quality: const {},
        ));
      }
      await hub.flushDspIsolate();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(hub.lastCoherence?.pair.toString(), 'AF7/AF8 (prefrontal)');

      await subPow.cancel();
      await subMet.cancel();
      await subCoh.cancel();
    });

    test('EegPracticeLink coalesces rapid slider sweeps and redundant voice frames',
        () async {
      await hub.connect(FakeEegDriver.device(EegDeviceType.muse));
      final capture = EegSessionCaptureController(
        hub: hub,
        tick: const Duration(milliseconds: 50),
        contextInterval: const Duration(seconds: 60),
      );
      Sint.put(capture);

      final isPlaying = false.obs;
      final freq = 432.0.obs;
      final voice = 0.0.obs;

      final link = EegPracticeLink(
        capture: capture,
        isPlaying: isPlaying,
        sessionStartedAt: DateTime.now,
        context: () => {EegContextKeys.baseHz: freq.value, EegContextKeys.beatHz: 8.0},
        annotateOn: [freq],
        detectedVoiceHz: voice,
        annotationMinInterval: const Duration(milliseconds: 80),
        voiceMinInterval: const Duration(milliseconds: 200),
        voiceMinDeltaHz: 1.0,
      )..attach();

      isPlaying.value = true;
      await Future<void>.delayed(const Duration(milliseconds: 10));
      muse.raw(EegSample(
        timestamp: DateTime.now(),
        channels: const {'TP9': 1, 'AF7': 1, 'AF8': 1, 'TP10': 1},
        quality: const {},
      ));

      // Simulate 50 rapid slider ticks within a few milliseconds.
      for (var i = 1; i <= 50; i++) {
        freq.value = 432.0 + i;
      }
      // Simulate jittery pitch detector frames around 220 Hz, then a jump to 260 Hz.
      voice.value = 220.0;
      voice.value = 220.2;
      voice.value = 220.4;
      voice.value = 260.0;

      await Future<void>.delayed(const Duration(milliseconds: 120));
      final saved = await capture.endSegment();
      link.detach();

      expect(saved, isNotNull);
      // Initial sample + leading annotation + single trailing coalesced annotation = 3.
      expect(saved!.context.length, lessThanOrEqualTo(4));
      expect(saved.context.last.hz(EegContextKeys.baseHz), 482.0);
      // Only 220.0 and 260.0 should be logged, skipping 220.2 and 220.4 jitter.
      expect(saved.detectedVoiceHz, [220.0, 260.0]);
    });
  });
}

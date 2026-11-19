import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:neom_eeg/data/hub/eeg_driver_registry.dart';
import 'package:neom_eeg/data/hub/eeg_hub.dart';
import 'package:neom_eeg/data/implementations/eeg_practice_link.dart';
import 'package:neom_eeg/data/implementations/eeg_session_capture_controller.dart';
import 'package:neom_eeg/domain/enums/eeg_connection_state.dart';
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
  late Directory dir;
  late FakeEegDriver emotiv;
  late EegHub hub;
  late EegSessionCaptureController capture;

  const tick = Duration(milliseconds: 40);

  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('neom_eeg_capture_');
    Hive.init(dir.path);
  });

  tearDownAll(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  setUp(() async {
    emotiv = FakeEegDriver(
      vendor: EegVendor.emotiv,
      capabilities: const EegCapabilities(
        nativeBandPower: true,
        nativeMentalMetrics: true,
        contactQuality: true,
      ),
    );
    hub = EegHub(registry: EegDriverRegistry([emotiv]));
    capture = EegSessionCaptureController(
      hub: hub,
      tick: tick,
      contextInterval: const Duration(milliseconds: 60),
    );
    Sint.put(capture);
    if (Hive.isBoxOpen(EegSessionCaptureController.boxName)) {
      await Hive.box<Map>(EegSessionCaptureController.boxName).clear();
    }
  });

  tearDown(() async {
    Sint.delete<EegSessionCaptureController>(force: true);
    await hub.dispose();
  });

  EegBandPower bp(String ch, {double alpha = 10, double theta = 2}) => EegBandPower(
        channel: ch,
        delta: 1,
        theta: theta,
        alpha: alpha,
        betaLow: 3,
        betaHigh: 1,
        gamma: 0.5,
        timestamp: DateTime.now(),
      );

  Future<void> connectInsight() =>
      hub.connect(FakeEegDriver.device(EegDeviceType.emotivInsight));

  void pushSecondOfData({int samples = 128, int frames = 8, double t7 = 10, double t8 = 10}) {
    for (var i = 0; i < samples; i++) {
      emotiv.raw(EegSample(
        timestamp: DateTime.now(),
        channels: const {'AF3': 1, 'T7': 1, 'Pz': 1, 'T8': 1, 'AF4': 1},
        quality: const {},
      ));
    }
    for (var i = 0; i < frames; i++) {
      emotiv.bandPower([
        bp('AF3'), bp('T7', alpha: t7), bp('Pz'), bp('T8', alpha: t8), bp('AF4'),
      ]);
    }
  }

  Future<void> ticks(int n) => Future<void>.delayed(tick * n + const Duration(milliseconds: 15));

  group('live stats', () {
    test('report samples and frames per tick and whether data flows', () async {
      await connectInsight();
      expect(capture.liveStats.value.isFlowing, isFalse);

      pushSecondOfData(samples: 64, frames: 4);
      await ticks(1);
      final s = capture.liveStats.value;
      expect(s.samplesPerSecond, 64);
      expect(s.framesPerSecond, 4);
      expect(s.totalSamples, 64);
      expect(s.expectedSampleRate, 128);
      expect(s.isFlowing, isTrue);
      expect(capture.isCapturingLive, isTrue);

      // Nothing more arrives: the next tick shows zero and the age grows.
      await ticks(1);
      expect(capture.liveStats.value.samplesPerSecond, 0);
      expect(capture.liveStats.value.totalSamples, 64);
    });

    test('go idle when the headset disconnects', () async {
      await connectInsight();
      pushSecondOfData();
      await ticks(1);
      emotiv.drop(EegConnectionState.disconnected);
      await ticks(1);
      expect(capture.liveStats.value, same(EegLiveStats.idle));
      expect(hub.connectionState, EegConnectionState.disconnected);
    });
  });

  group('segments', () {
    test('cut a capture with EEG, symmetry, metrics, context, voice, markers',
        () async {
      await connectInsight();
      var base = 432.0;
      await capture.startSegment(
        practiceSessionId: 'practice_1',
        contextSampler: () => {
          EegContextKeys.baseHz: base,
          EegContextKeys.beatHz: 7.83,
          EegContextKeys.preset: 'Schumann',
        },
      );
      expect(capture.segmentOpen.value, isTrue);
      expect(capture.segmentPracticeId.value, 'practice_1');

      emotiv.mental(EegMentalState(
        engagement: 0.5, relaxation: 0.8, stress: 0.2, focus: 0.6, excitement: 0.3,
        timestamp: DateTime.now(),
      ));
      pushSecondOfData(t7: 10, t8: 10); // balanced → symmetry 1
      await ticks(1);
      pushSecondOfData(t7: 30, t8: 10); // asymmetric → symmetry 0.5
      capture.noteVoice(EegVoiceEventKind.captureStarted);
      capture.noteVoice(EegVoiceEventKind.detected, frequencyHz: 214.5);
      base = 528.0;
      capture.annotateContext({EegContextKeys.baseHz: base, EegContextKeys.beatHz: 7.83});
      await ticks(1);

      // A marker through the (local) recording service lands in the capture.
      await hub.recording.startRecording(title: 'x');
      await hub.recording.addMarker(label: 'aura', value: 1);
      await hub.recording.stopRecording();
      await Future<void>.delayed(Duration.zero);

      final cap = await capture.endSegment();
      expect(cap, isNotNull);
      expect(capture.segmentOpen.value, isFalse);
      expect(cap!.practiceSessionId, 'practice_1');
      expect(cap.deviceType, EegDeviceType.emotivInsight);
      expect(cap.channels, ['AF3', 'T7', 'Pz', 'T8', 'AF4']);
      expect(cap.sampleRate, 128);
      expect(cap.rows.length, greaterThanOrEqualTo(2));
      expect(cap.sampleCount, 256);
      expect(cap.frameCount, 16);
      expect(cap.rows.first.symmetry, closeTo(1.0, 1e-9));
      expect(cap.rows.where((r) => r.frames > 0).last.symmetry, closeTo(0.5, 1e-9));
      // No raw EEG went through the hub: no spectral coherence is claimed.
      expect(cap.rows.every((r) => r.coherence == null), isTrue);
      expect(cap.rows.first.relaxation, 0.8);
      expect(cap.avgBands['alpha'], greaterThan(0));
      expect(cap.dominantBand, 'alpha');
      expect(cap.context.length, greaterThanOrEqualTo(2),
          reason: 'initial sample + annotation (+ periodic ones)');
      expect(cap.context.first.hz(EegContextKeys.baseHz), 432.0);
      expect(cap.context.last.hz(EegContextKeys.baseHz), 528.0);
      final used = cap.frequenciesUsed;
      expect(used.map((u) => u.baseHz).toSet(), {432.0, 528.0});
      expect(cap.voice.map((v) => v.kind),
          [EegVoiceEventKind.captureStarted, EegVoiceEventKind.detected]);
      expect(cap.detectedVoiceHz, [214.5]);
      expect(cap.markers.single.label, 'aura');

      // Persisted and retrievable by practice id.
      final listed = await capture.listCaptures();
      expect(listed.map((c) => c.id), contains(cap.id));
      expect((await capture.capturesFor('practice_1'))?.id, cap.id);

      // JSON round trip keeps the numbers.
      final again = EegSessionCapture.fromJson(cap.toJson());
      expect(again.sampleCount, cap.sampleCount);
      expect(again.rows.first.symmetry, cap.rows.first.symmetry);
      expect(again.frequenciesUsed.length, used.length);
      expect(again.markers.single.label, 'aura');
    });

    test('an empty segment is not persisted', () async {
      await connectInsight();
      await capture.startSegment(practiceSessionId: 'nothing');
      final cap = await capture.endSegment();
      expect(cap, isNull);
      expect((await capture.listCaptures()).where((c) => c.practiceSessionId == 'nothing'),
          isEmpty);
    });

    test('a recording started from the dashboard captures on its own', () async {
      await connectInsight();
      final rec = await hub.recording.startRecording(title: 'manual');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(capture.segmentOpen.value, isTrue);
      expect(capture.segmentPracticeId.value, rec.id);

      pushSecondOfData();
      await ticks(1);
      await hub.recording.stopRecording();
      await ticks(1);

      expect(capture.segmentOpen.value, isFalse);
      final cap = await capture.capturesFor(rec.id);
      expect(cap, isNotNull);
      expect(cap!.sampleCount, 128);
    });

    test('a host segment is not closed by a recording that stops', () async {
      await connectInsight();
      await capture.startSegment(practiceSessionId: 'host', contextSampler: () => {});
      await hub.recording.startRecording(title: 'inner');
      await Future<void>.delayed(Duration.zero);
      expect(capture.segmentPracticeId.value, 'host',
          reason: 'the host segment already covers the recording');
      await hub.recording.stopRecording();
      await Future<void>.delayed(Duration.zero);
      expect(capture.segmentOpen.value, isTrue);
      pushSecondOfData();
      await ticks(1);
      expect((await capture.endSegment())?.practiceSessionId, 'host');
    });

    test('contact changes are logged inside the segment', () async {
      await connectInsight();
      await capture.startSegment(practiceSessionId: 'cq', contextSampler: () => {});
      emotiv.status(EegDeviceStatus(
        contactQuality: const {'AF3': 1, 'T7': 1, 'Pz': 0, 'T8': 1, 'AF4': 1},
        timestamp: DateTime.now(),
      ));
      pushSecondOfData();
      await ticks(2);
      final cap = await capture.endSegment();
      expect(cap!.contactChanges.map((c) => c.excluded), anyElement(equals(['Pz'])));
    });
  });

  group('EegPracticeLink', () {
    test('follows isPlaying, annotates on frequency changes and logs voice',
        () async {
      await connectInsight();
      final isPlaying = false.obs;
      final currentFreq = 432.0.obs;
      final detected = 0.0.obs;
      final micOn = false.obs;
      DateTime? startedAt;

      final link = EegPracticeLink(
        capture: capture,
        isPlaying: isPlaying,
        sessionStartedAt: () => startedAt,
        context: () => {EegContextKeys.baseHz: currentFreq.value, EegContextKeys.beatHz: 10.0},
        annotateOn: [currentFreq],
        detectedVoiceHz: detected,
        voiceCapturing: micOn,
      )..attach();

      startedAt = DateTime.now();
      isPlaying.value = true;
      await Future<void>.delayed(Duration.zero);
      expect(capture.segmentOpen.value, isTrue);
      expect(capture.segmentPracticeId.value,
          'practice_${startedAt.microsecondsSinceEpoch}');

      pushSecondOfData();
      currentFreq.value = 528.0;
      micOn.value = true;
      detected.value = 220.0;
      detected.value = 0.0; // silence is not an event
      micOn.value = false;
      await ticks(1);

      isPlaying.value = false;
      await ticks(1);
      expect(capture.segmentOpen.value, isFalse);

      final cap = await capture.capturesFor('practice_${startedAt.microsecondsSinceEpoch}');
      expect(cap, isNotNull);
      expect(cap!.context.map((c) => c.hz(EegContextKeys.baseHz)), contains(528.0));
      expect(cap.voice.map((v) => v.kind), [
        EegVoiceEventKind.captureStarted,
        EegVoiceEventKind.detected,
        EegVoiceEventKind.captureStopped,
      ]);
      expect(cap.detectedVoiceHz, [220.0]);

      link.detach();
      isPlaying.value = true;
      await Future<void>.delayed(Duration.zero);
      expect(capture.segmentOpen.value, isFalse, reason: 'detached');
    });
  });

  group('EegSessionCapture model', () {
    EegCaptureRow row(double t, {double alpha = 10, double theta = 1, int samples = 128}) =>
        EegCaptureRow(
          t: t, delta: 1, theta: theta, alpha: alpha, betaLow: 1, betaHigh: 1, gamma: 0.5,
          coherence: 0.9, samples: samples, frames: 8,
        );

    test('summaries: coverage, dominant band seconds, frequencies used', () {
      final start = DateTime(2026, 1, 1, 10);
      final cap = EegSessionCapture(
        id: 'c',
        deviceType: EegDeviceType.emotivInsight,
        deviceName: 'Insight',
        channels: const ['AF3', 'T7', 'Pz', 'T8', 'AF4'],
        sampleRate: 128,
        startedAt: start,
        endedAt: start.add(const Duration(seconds: 10)),
        rows: [
          for (var i = 0; i < 10; i++)
            row(i.toDouble(), alpha: i < 6 ? 10 : 1, theta: i < 6 ? 1 : 10,
                samples: i < 8 ? 128 : 0),
        ],
        context: const [
          EegContextSample(t: 0, values: {'baseHz': 432.0, 'beatHz': 7.83}),
          EegContextSample(t: 4, values: {'baseHz': 528.0, 'beatHz': 7.83}),
          EegContextSample(t: 8, values: {'baseHz': 432.0, 'beatHz': 7.83}),
        ],
      );
      expect(cap.duration.inSeconds, 10);
      expect(cap.sampleCount, 8 * 128);
      expect(cap.coverage, closeTo(0.8, 1e-9));
      expect(cap.secondsWithSignal, 8);
      expect(cap.dominantBandSeconds, {'alpha': 6, 'theta': 4});
      expect(cap.dominantBand, 'alpha');
      expect(cap.avgCoherence, closeTo(0.9, 1e-9));
      final used = cap.frequenciesUsed;
      expect(used.first.baseHz, 432.0);
      expect(used.first.seconds, closeTo(6, 1e-9)); // 0-4 + 8-10
      expect(used.last.baseHz, 528.0);
      expect(used.last.seconds, closeTo(4, 1e-9));
    });

    test('row list form round-trips including nulls', () {
      final r = EegCaptureRow(
        t: 3, delta: 1, theta: 2, alpha: 3, betaLow: 4, betaHigh: 5, gamma: 6,
        coherence: null, focus: 0.5, samples: 100, frames: 8,
      );
      final back = EegCaptureRow.fromList(r.toList());
      expect(back.coherence, isNull);
      expect(back.focus, 0.5);
      expect(back.relaxation, isNull);
      expect(back.samples, 100);
      expect(back.beta, 9);
      expect(back.dominantBand, 'beta');
    });

    test('sine-like alpha rows classify as alpha dominant', () {
      final rows = [
        for (var i = 0; i < 5; i++)
          EegCaptureRow(
            t: i.toDouble(), delta: 1, theta: 1, alpha: 5 + sin(i.toDouble()),
            betaLow: 1, betaHigh: 1, gamma: 1, samples: 128, frames: 8,
          ),
      ];
      expect(rows.every((r) => r.dominantBand == 'alpha'), isTrue);
    });
  });

  group('frequency-following response', () {
    /// [seconds] of raw EEG with a 6 Hz component of [amplitude] µV on
    /// every channel over ±5 µV noise, delivered as fast as possible.
    Future<void> pushRaw({required int seconds, double amplitude = 3}) async {
      final rnd = Random(4);
      double g() => sqrt(-2 * log(1 - rnd.nextDouble())) * cos(2 * pi * rnd.nextDouble());
      for (var i = 0; i < seconds * 128; i++) {
        final v = amplitude * sin(2 * pi * 6 * i / 128);
        emotiv.raw(EegSample(
          timestamp: DateTime.now(),
          channels: {for (final ch in ['AF3', 'T7', 'Pz', 'T8', 'AF4']) ch: 4200 + v + 5 * g()},
          quality: const {},
        ));
      }
      await Future<void>.delayed(Duration.zero);
    }

    test('measures the response at the beat the host is playing', () async {
      await connectInsight();
      await capture.startSegment(
        practiceSessionId: 'practice_ffr',
        contextSampler: () => {EegContextKeys.baseHz: 200.0, EegContextKeys.beatHz: 6.0},
      );
      await pushRaw(seconds: 9);
      await ticks(2);
      final cap = (await capture.endSegment())!;
      final ffr = cap.frequencyFollowing;
      expect(ffr, isNotNull);
      expect(ffr!.hz, 6.0);
      expect(ffr.meanSnr, greaterThan(2));
    });

    test('no stimulus with a beat or pulse, no response is claimed', () async {
      await connectInsight();
      await capture.startSegment(
        practiceSessionId: 'practice_plain',
        contextSampler: () => {EegContextKeys.baseHz: 432.0, EegContextKeys.beatHz: 0.0},
      );
      await pushRaw(seconds: 9);
      await ticks(2);
      final cap = (await capture.endSegment())!;
      expect(cap.frequencyFollowing, isNull);
    });

    test('an isochronic pulse takes precedence over the binaural beat', () async {
      await connectInsight();
      await capture.startSegment(
        practiceSessionId: 'practice_iso',
        contextSampler: () => {
          EegContextKeys.beatHz: 10.0,
          EegContextKeys.isochronicHz: 6.0,
        },
      );
      await pushRaw(seconds: 9);
      await ticks(2);
      final cap = (await capture.endSegment())!;
      expect(cap.frequencyFollowing!.hz, 6.0);
    });
  });
}

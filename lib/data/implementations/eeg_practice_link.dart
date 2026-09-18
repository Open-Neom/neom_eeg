import 'dart:async';

import 'package:sint/sint.dart';

import '../../domain/models/eeg_session_capture.dart';
import 'eeg_session_capture_controller.dart';

/// Binds a host's practice state to [EegSessionCaptureController] without
/// the EEG module knowing the host.
///
/// The host hands over its reactive fields — is a session playing, when did
/// it start, what is it playing, what does the microphone hear — and the
/// link opens/closes capture segments and annotates them. Cyberneom wires
/// the Cámara Neom's `NeomGeneratorController` this way; the generator
/// itself is never touched.
///
/// ```dart
/// EegPracticeLink(
///   capture: Sint.find<EegSessionCaptureController>(),
///   isPlaying: generator.isPlaying,
///   sessionStartedAt: () => generator.sessionStartedAt,
///   context: () => {
///     EegContextKeys.baseHz: generator.currentFreq.value,
///     EegContextKeys.beatHz: generator.currentBeat.value,
///     EegContextKeys.effectiveHz: generator.effectiveFrequency,
///     EegContextKeys.volume: generator.currentVol.value,
///     EegContextKeys.neuroState: generator.neuroState.value.name,
///   },
///   annotateOn: [generator.currentFreq, generator.currentBeat],
///   detectedVoiceHz: generator.detectedFrequency,
///   voiceCapturing: generator.isRecording,
/// ).attach();
/// ```
class EegPracticeLink {
  final EegSessionCaptureController capture;
  final RxBool isPlaying;
  final DateTime? Function() sessionStartedAt;
  final Map<String, dynamic> Function() context;

  /// Id the capture is filed under. Defaults to `practice_<micros>` of the
  /// session start — the id the Cámara Neom gives its practice drafts, so
  /// both records can be joined later.
  final String Function(DateTime startedAt) sessionIdOf;

  /// Observables whose change means "the host changed what it plays";
  /// each change adds a context snapshot on top of the periodic ones.
  final List<RxInterface<dynamic>> annotateOn;

  /// Vocal frequency the host's pitch detector reports (0 = nothing).
  final RxDouble? detectedVoiceHz;

  /// Whether the host is capturing the microphone.
  final RxBool? voiceCapturing;

  final _subs = <StreamSubscription<dynamic>>[];
  bool _attached = false;

  EegPracticeLink({
    required this.capture,
    required this.isPlaying,
    required this.sessionStartedAt,
    required this.context,
    String Function(DateTime startedAt)? sessionIdOf,
    this.annotateOn = const [],
    this.detectedVoiceHz,
    this.voiceCapturing,
  }) : sessionIdOf = sessionIdOf ?? _defaultSessionId;

  static String _defaultSessionId(DateTime startedAt) =>
      'practice_${startedAt.microsecondsSinceEpoch}';

  bool get isAttached => _attached;

  void attach() {
    if (_attached) return;
    _attached = true;

    _subs.add(isPlaying.listen((playing) {
      if (playing) {
        final started = sessionStartedAt() ?? DateTime.now();
        unawaited(capture.startSegment(
          practiceSessionId: sessionIdOf(started),
          contextSampler: context,
          startedAt: started,
        ));
      } else {
        unawaited(capture.endSegment());
      }
    }));

    for (final rx in annotateOn) {
      _subs.add(rx.listen((_) {
        if (capture.segmentOpen.value) capture.annotateContext(context());
      }));
    }

    final voice = detectedVoiceHz;
    if (voice != null) {
      _subs.add(voice.listen((hz) {
        if (hz > 0) {
          capture.noteVoice(EegVoiceEventKind.detected, frequencyHz: hz);
        }
      }));
    }

    final capturing = voiceCapturing;
    if (capturing != null) {
      _subs.add(capturing.listen((on) {
        capture.noteVoice(
          on ? EegVoiceEventKind.captureStarted : EegVoiceEventKind.captureStopped,
        );
      }));
    }

    // A session already running when we attach is captured from now on.
    if (isPlaying.value) {
      final started = sessionStartedAt() ?? DateTime.now();
      unawaited(capture.startSegment(
        practiceSessionId: sessionIdOf(started),
        contextSampler: context,
        startedAt: started,
      ));
    }
  }

  void detach() {
    if (!_attached) return;
    _attached = false;
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
  }
}

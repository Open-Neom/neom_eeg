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

  /// Optional minimum interval between reactive context annotations
  /// (leading + trailing throttle). Prevents 60–120 Hz slider sweeps from
  /// flooding the capture log during long meditation sessions while keeping
  /// single discrete changes immediate.
  final Duration annotationMinInterval;

  /// Optional minimum interval and pitch delta (`Hz`) for vocal pitch events.
  final Duration voiceMinInterval;
  final double voiceMinDeltaHz;

  final _subs = <StreamSubscription<dynamic>>[];
  Timer? _pendingAnnotationTimer;
  DateTime? _lastAnnotationAt;
  DateTime? _lastVoiceAt;
  double? _lastVoiceHz;
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
    this.annotationMinInterval = Duration.zero,
    this.voiceMinInterval = Duration.zero,
    this.voiceMinDeltaHz = 0.0,
  }) : sessionIdOf = sessionIdOf ?? _defaultSessionId;

  static String _defaultSessionId(DateTime startedAt) =>
      'practice_${startedAt.microsecondsSinceEpoch}';

  bool get isAttached => _attached;

  void _flushPendingAnnotation() {
    if (_pendingAnnotationTimer == null) return;
    _pendingAnnotationTimer?.cancel();
    _pendingAnnotationTimer = null;
    if (capture.segmentOpen.value) {
      _lastAnnotationAt = DateTime.now();
      capture.annotateContext(context());
    }
  }

  void _scheduleOrEmitAnnotation() {
    if (!capture.segmentOpen.value) return;
    if (annotationMinInterval <= Duration.zero) {
      capture.annotateContext(context());
      return;
    }
    final now = DateTime.now();
    final last = _lastAnnotationAt;
    if (last == null || now.difference(last) >= annotationMinInterval) {
      _pendingAnnotationTimer?.cancel();
      _pendingAnnotationTimer = null;
      _lastAnnotationAt = now;
      capture.annotateContext(context());
      return;
    }
    if (_pendingAnnotationTimer != null) return;
    final remaining = annotationMinInterval - now.difference(last);
    _pendingAnnotationTimer = Timer(remaining, () {
      _pendingAnnotationTimer = null;
      if (_attached && capture.segmentOpen.value) {
        _lastAnnotationAt = DateTime.now();
        capture.annotateContext(context());
      }
    });
  }

  void attach() {
    if (_attached) return;
    _attached = true;

    _subs.add(isPlaying.listen((playing) {
      if (playing) {
        _lastAnnotationAt = null;
        _lastVoiceAt = null;
        _lastVoiceHz = null;
        final started = sessionStartedAt() ?? DateTime.now();
        unawaited(capture.startSegment(
          practiceSessionId: sessionIdOf(started),
          contextSampler: context,
          startedAt: started,
        ));
      } else {
        _flushPendingAnnotation();
        unawaited(capture.endSegment());
      }
    }));

    for (final rx in annotateOn) {
      _subs.add(rx.listen((_) => _scheduleOrEmitAnnotation()));
    }

    final voice = detectedVoiceHz;
    if (voice != null) {
      _subs.add(voice.listen((hz) {
        if (hz <= 0 || !hz.isFinite) {
          _lastVoiceHz = null;
          return;
        }
        if (voiceMinInterval > Duration.zero || voiceMinDeltaHz > 0) {
          final now = DateTime.now();
          final withinInterval = _lastVoiceAt != null &&
              now.difference(_lastVoiceAt!) < voiceMinInterval;
          final smallDelta = _lastVoiceHz != null &&
              (hz - _lastVoiceHz!).abs() < voiceMinDeltaHz;
          if (withinInterval && smallDelta) return;
          _lastVoiceAt = now;
          _lastVoiceHz = hz;
        }
        capture.noteVoice(EegVoiceEventKind.detected, frequencyHz: hz);
      }));
    }

    final capturing = voiceCapturing;
    if (capturing != null) {
      _subs.add(capturing.listen((on) {
        _lastVoiceHz = null;
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
    _flushPendingAnnotation();
    _attached = false;
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
  }
}

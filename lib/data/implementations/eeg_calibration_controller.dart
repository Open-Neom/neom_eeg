import 'dart:async';

import 'package:hive_ce/hive_ce.dart';
import 'package:sint/sint.dart';

import '../../domain/enums/eeg_connection_state.dart';
import '../../domain/enums/eeg_device_type.dart';
import '../../domain/models/eeg_calibration.dart';
import '../../domain/models/eeg_exceptions.dart';
import '../hub/eeg_hub.dart';
import 'eeg_calibration_builder.dart';

/// Runs the resting-baseline routine on whatever headset the hub has
/// connected, and keeps one [EegCalibration] per subject and model in Hive.
///
/// The routine is two timed phases — eyes open on a fixed point, then eyes
/// closed — during which every band-power frame and raw sample the hub
/// publishes is handed to an [EegCalibrationBuilder], except during the
/// first `settle` seconds of each phase: alpha takes a moment to rise after
/// the eyes close, and the first seconds of eyes-open carry the blinks of
/// having just opened them. The result is what
/// turns fixed thresholds into personal ones everywhere else in the
/// module (watcher z-scores, hypofrontality, entrainment).
///
/// [subjectId] is asked on every run and load so the host decides who is
/// wearing the headset (a profile id, a guest tag); the module stores it
/// and nothing more.
class EegCalibrationController extends SintController {
  static const boxName = 'eeg_calibrations';

  final EegHub hub;
  final String? Function()? subjectId;

  EegCalibrationController({
    required this.hub,
    this.subjectId,
    Duration tick = const Duration(milliseconds: 250),
  }) : _tick = tick;

  final Duration _tick;

  // ── Reactive state ──────────────────────────────────────────────────
  final Rx<EegCalibrationPhase> phase = EegCalibrationPhase.idle.obs;

  /// Seconds left in the current phase.
  final RxInt remainingSeconds = 0.obs;

  /// Progress of the whole routine, `0..1`.
  final RxDouble progress = 0.0.obs;

  /// Band-power frames folded in so far.
  final RxInt frames = 0.obs;
  final RxnString error = RxnString();

  /// Baseline for the connected headset and current subject, if any.
  final Rxn<EegCalibration> current = Rxn<EegCalibration>();

  final _builder = EegCalibrationBuilder();
  final _subs = <StreamSubscription<dynamic>>[];
  StreamSubscription<EegConnectionState>? _connectionSub;
  Timer? _timer;
  Completer<EegCalibration?>? _running;
  DateTime _phaseStartedAt = DateTime.now();
  Box<Map>? _box;
  final Map<String, Map<String, dynamic>> _memoryFallback = {};
  bool _disposed = false;

  bool get isRunning => _running != null && !_running!.isCompleted;

  @override
  void onInit() {
    super.onInit();
    _connectionSub = hub.connectionStateStream.listen((state) {
      if (_disposed) return;
      if (state == EegConnectionState.streaming) {
        unawaited(load());
      } else if (state == EegConnectionState.disconnected ||
          state == EegConnectionState.error) {
        if (isRunning) _finish(null, error: 'El headset se desconectó durante la calibración');
        current.value = null;
      }
    });
    if (hub.connectionState == EegConnectionState.streaming) unawaited(load());
  }

  @override
  void onClose() {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    _connectionSub?.cancel();
    _connectionSub = null;
    _stopListening();
    final c = _running;
    _running = null;
    if (c != null && !c.isCompleted) c.complete(null);
    phase.close();
    remainingSeconds.close();
    progress.close();
    frames.close();
    error.close();
    current.close();
    super.onClose();
  }

  // ── Routine ─────────────────────────────────────────────────────────

  /// Runs the routine and returns the resulting calibration, saved and
  /// set as [current]; null when cancelled or when the headset delivered
  /// no band powers. Throws [EegException] when nothing is streaming.
  Future<EegCalibration?> run({
    Duration eyesOpen = const Duration(seconds: 60),
    Duration eyesClosed = const Duration(seconds: 30),
    bool includeEyesClosed = true,
    Duration settle = const Duration(seconds: 3),
  }) async {
    if (_disposed) return null;
    if (hub.connectionState != EegConnectionState.streaming) {
      throw const EegException('Conecta un headset antes de calibrar');
    }
    if (eyesOpen <= Duration.zero) {
      throw const EegException('La fase de ojos abiertos debe ser > 0 s');
    }
    if (isRunning) await cancel();

    final closed = includeEyesClosed && eyesClosed > Duration.zero
        ? eyesClosed
        : Duration.zero;
    final total = eyesOpen + closed;
    _builder.reset();
    frames.value = 0;
    error.value = null;
    progress.value = 0;
    _running = Completer<EegCalibration?>();

    bool settling() => DateTime.now().difference(_phaseStartedAt) < settle;
    _subs.addAll([
      hub.bandPowerStream.listen((frame) {
        if (settling()) return;
        _builder.addFrame(phase.value, frame);
        frames.value = _builder.eyesOpenFrames + _builder.eyesClosedFrames;
      }),
      hub.rawStream.listen((s) {
        if (!settling()) _builder.addRaw(phase.value, s);
      }),
    ]);

    final started = DateTime.now();
    _enterPhase(EegCalibrationPhase.eyesOpen, eyesOpen);
    _timer = Timer.periodic(_tick, (_) {
      final elapsed = DateTime.now().difference(started);
      progress.value = total.inMilliseconds == 0
          ? 1.0
          : (elapsed.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);

      if (phase.value == EegCalibrationPhase.eyesOpen) {
        final left = eyesOpen - elapsed;
        if (left > Duration.zero) {
          remainingSeconds.value = _ceilSeconds(left);
          return;
        }
        if (closed > Duration.zero) {
          _enterPhase(EegCalibrationPhase.eyesClosed, closed);
          return;
        }
      }
      if (phase.value == EegCalibrationPhase.eyesClosed) {
        final left = total - elapsed;
        if (left > Duration.zero) {
          remainingSeconds.value = _ceilSeconds(left);
          return;
        }
      }

      if (!_builder.hasData) {
        _finish(null, error: 'El headset no envió bandas de frecuencia durante la calibración');
        return;
      }
      final calibration = _builder.build(
        subjectId: subjectId?.call(),
        deviceType: hub.connectedDevice?.type,
        eyesOpenSeconds: eyesOpen.inMilliseconds / 1000.0,
        eyesClosedSeconds: closed.inMilliseconds / 1000.0,
      );
      _finish(calibration);
    });

    return _running!.future;
  }

  Future<void> cancel() async {
    if (!isRunning) return;
    _finish(null, cancelled: true);
  }

  void _enterPhase(EegCalibrationPhase p, Duration length) {
    phase.value = p;
    _phaseStartedAt = DateTime.now();
    remainingSeconds.value = _ceilSeconds(length);
  }

  void _finish(EegCalibration? result, {String? error, bool cancelled = false}) {
    _timer?.cancel();
    _timer = null;
    _stopListening();
    remainingSeconds.value = 0;
    this.error.value = error;
    phase.value = result == null
        ? (cancelled || error != null ? EegCalibrationPhase.cancelled : EegCalibrationPhase.idle)
        : EegCalibrationPhase.done;
    if (result != null) {
      progress.value = 1;
      current.value = result;
      unawaited(save(result));
    }
    final c = _running;
    _running = null;
    if (c != null && !c.isCompleted) c.complete(result);
  }

  void _stopListening() {
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
  }

  static int _ceilSeconds(Duration d) => (d.inMilliseconds / 1000).ceil();

  // ── Persistence ─────────────────────────────────────────────────────

  /// Loads the baseline for the connected model (or [type]) and the current
  /// subject into [current]. Null when none was saved.
  Future<EegCalibration?> load({EegDeviceType? type}) async {
    if (_disposed) return null;
    final t = type ?? hub.connectedDevice?.type;
    final key = EegCalibration.keyFor(subjectId?.call(), t);
    try {
      await _openBox();
      final json = (_box != null && _box!.isOpen)
          ? _box!.get(key)
          : _memoryFallback[key];
      final cal = json == null ? null : EegCalibration.fromJson(Map<String, dynamic>.from(json));
      if (!_disposed) current.value = cal;
      return cal;
    } catch (_) {
      // Hive not initialised (tests, early boot) or an older schema.
      return null;
    }
  }

  Future<void> save(EegCalibration calibration) async {
    try {
      await _openBox();
      final data = calibration.toJson();
      if (_box != null && _box!.isOpen) {
        await _box!.put(calibration.key, data);
      } else {
        _memoryFallback[calibration.key] = data;
      }
    } catch (_) {
      // Without Hive the baseline lives in [current] for this session only.
    }
  }

  /// Forgets the saved baseline for the connected model and subject.
  Future<void> clear({EegDeviceType? type}) async {
    final t = type ?? hub.connectedDevice?.type;
    final key = EegCalibration.keyFor(subjectId?.call(), t);
    await _openBox();
    if (_box != null && _box!.isOpen) {
      await _box!.delete(key);
    } else {
      _memoryFallback.remove(key);
    }
    if (!_disposed && current.value?.key == key) {
      current.value = null;
    }
  }

  /// Every saved baseline, newest first.
  Future<List<EegCalibration>> listAll() async {
    await _openBox();
    final out = <EegCalibration>[];
    final values = (_box != null && _box!.isOpen)
        ? _box!.values
        : _memoryFallback.values;
    for (final json in values) {
      try {
        out.add(EegCalibration.fromJson(Map<String, dynamic>.from(json)));
      } catch (_) {
        // Skip rows from an older schema.
      }
    }
    out.sort((a, b) => b.calibratedAt.compareTo(a.calibratedAt));
    return out;
  }

  Future<void> _openBox() async {
    if (_box != null && _box!.isOpen) return;
    if (Hive.isBoxOpen(boxName)) {
      _box = Hive.box<Map>(boxName);
      return;
    }
    final completer = Completer<Box<Map>?>();
    runZonedGuarded(
      () async {
        try {
          final box = await Hive.openBox<Map>(boxName);
          if (!completer.isCompleted) completer.complete(box);
        } catch (_) {
          if (!completer.isCompleted) completer.complete(null);
        }
      },
      (_, _) {
        if (!completer.isCompleted) completer.complete(null);
      },
    );
    _box = await completer.future;
  }
}

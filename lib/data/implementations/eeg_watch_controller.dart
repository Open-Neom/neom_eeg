import 'dart:async';

import 'package:sint/sint.dart';

import '../../domain/enums/eeg_connection_state.dart';
import '../../domain/models/eeg_band_power.dart';
import '../../domain/models/eeg_calibration.dart';
import '../../domain/models/eeg_watch_rule.dart';
import '../hub/eeg_hub.dart';
import 'eeg_indices.dart';
import 'eeg_session_capture_controller.dart';

/// Evaluates [EegWatchRule]s against every band-power frame the hub
/// publishes and raises an [EegAlert] when a condition has held for the
/// rule's `sustain`.
///
/// Thresholds are personal whenever a calibration is available: z-scored
/// rules stay dormant without one, and the asymmetry rule measures the
/// change from the subject's resting balance instead of any imbalance.
/// A firing rule with `autoMarker` pins a marker to the active recording
/// (Cortex record or local), and is noted in the open session capture
/// either way, so the report can show it afterwards.
///
/// Vendor-agnostic by construction: it only sees the hub's streams and the
/// indices `EegIndices` computes for any layout.
class EegWatchController extends SintController {
  final EegHub hub;

  /// Resolved on every frame, so a calibration finished mid-session takes
  /// effect immediately.
  final EegCalibration? Function()? calibration;

  /// Where alerts are noted; resolved on every alert.
  final EegSessionCaptureController? Function()? capture;

  /// Band the asymmetry/coherence indices are computed on.
  final String band;

  /// Minimum gap between two updates of [indices], to keep widget rebuilds
  /// below the frame rate of the headset.
  final Duration indicesInterval;

  /// Alerts kept in [alerts].
  final int historyLength;

  EegWatchController({
    required this.hub,
    List<EegWatchRule> rules = EegWatchRule.defaults,
    this.calibration,
    this.capture,
    this.band = 'alpha',
    this.indicesInterval = const Duration(milliseconds: 250),
    this.historyLength = 50,
    DateTime Function()? clock,
  })  : rules = RxList<EegWatchRule>(List.of(rules)),
        _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;

  // ── Reactive state ──────────────────────────────────────────────────
  final RxList<EegWatchRule> rules;

  /// Latest indices, refreshed at most every [indicesInterval].
  final Rx<EegLiveIndices> indices = EegLiveIndices.empty.obs;

  /// Alerts raised, newest first.
  final RxList<EegAlert> alerts = <EegAlert>[].obs;

  /// Rules whose condition currently holds and has been sustained.
  final RxSet<String> active = <String>{}.obs;

  /// Rules whose condition holds but has not reached `sustain` yet:
  /// rule id → when it started holding.
  final RxMap<String, DateTime> holding = <String, DateTime>{}.obs;

  /// Master switch for pinning markers on alerts.
  final RxBool autoMarkers = true.obs;
  final RxBool enabled = true.obs;

  final _alertController = StreamController<EegAlert>.broadcast();
  final _since = <String, DateTime>{};
  final _lastFired = <String, DateTime>{};
  DateTime? _lastIndicesAt;
  final _subs = <StreamSubscription<dynamic>>[];
  int _alertSeq = 0;

  Stream<EegAlert> get alertStream => _alertController.stream;

  @override
  void onInit() {
    super.onInit();
    _subs.addAll([
      hub.bandPowerStream.listen(_onFrame),
      hub.connectionStateStream.listen((state) {
        if (state == EegConnectionState.disconnected ||
            state == EegConnectionState.error ||
            state == EegConnectionState.streaming) {
          reset();
        }
      }),
    ]);
  }

  @override
  void onClose() {
    for (final s in _subs) {
      s.cancel();
    }
    _alertController.close();
    super.onClose();
  }

  // ── Rules ───────────────────────────────────────────────────────────

  void setRules(List<EegWatchRule> next) {
    rules.assignAll(next);
    final ids = next.map((r) => r.id).toSet();
    _since.removeWhere((id, _) => !ids.contains(id));
    active.removeWhere((id) => !ids.contains(id));
    holding.removeWhere((id, _) => !ids.contains(id));
  }

  void updateRule(EegWatchRule rule) {
    final i = rules.indexWhere((r) => r.id == rule.id);
    if (i < 0) {
      rules.add(rule);
    } else {
      rules[i] = rule;
    }
    if (!rule.enabled) _release(rule.id);
  }

  void toggleRule(String id, bool enabled) {
    final i = rules.indexWhere((r) => r.id == id);
    if (i >= 0) updateRule(rules[i].copyWith(enabled: enabled));
  }

  /// Forgets sustain timers and active states (new connection, new session).
  void reset() {
    _since.clear();
    _lastFired.clear();
    active.clear();
    holding.clear();
    indices.value = EegLiveIndices.empty;
    _lastIndicesAt = null;
  }

  /// Whether [rule] can fire right now (its metric is available).
  bool isArmed(EegWatchRule rule) =>
      rule.enabled && (!rule.needsCalibration || calibration?.call() != null);

  // ── Evaluation ──────────────────────────────────────────────────────

  void _onFrame(List<EegBandPower> frame) {
    if (!enabled.value || frame.isEmpty) return;
    evaluate(frame, at: _clock());
  }

  /// Evaluates one frame. Public so hosts and tests can drive it with their
  /// own clock; the controller calls it for every hub frame.
  void evaluate(List<EegBandPower> frame, {required DateTime at}) {
    final cal = calibration?.call();
    final idx = EegIndices.compute(
      frame,
      calibration: cal,
      band: band,
      excludedChannels: hub.excludedChannels.length,
      at: at,
    );
    if (_lastIndicesAt == null || at.difference(_lastIndicesAt!) >= indicesInterval) {
      indices.value = idx;
      _lastIndicesAt = at;
    }

    for (final rule in rules) {
      if (!rule.enabled) continue;
      final value = valueFor(rule, idx, cal);
      if (value == null) {
        _release(rule.id);
        continue;
      }
      if (!rule.holds(value)) {
        _release(rule.id);
        continue;
      }

      final since = _since.putIfAbsent(rule.id, () => at);
      if (at.difference(since) < rule.sustain) {
        holding[rule.id] = since;
        continue;
      }
      holding.remove(rule.id);
      active.add(rule.id);

      final last = _lastFired[rule.id];
      if (last != null && at.difference(last) < rule.cooldown) continue;
      _lastFired[rule.id] = at;
      unawaited(_fire(rule, value: value, since: since, at: at));
    }
  }

  /// The number a rule compares against its threshold, from [idx]; null
  /// when the frame cannot provide it (no pair, no calibration, no frontal
  /// electrode).
  double? valueFor(EegWatchRule rule, EegLiveIndices idx, EegCalibration? cal) {
    switch (rule.metric) {
      case EegWatchMetric.asymmetry:
        final a = idx.asymmetry;
        final pair = idx.pair;
        if (a == null || pair == null) return null;
        if (rule.personal && cal != null) {
          final base = cal.baselineAsymmetry(rule.band, pair.left, pair.right);
          if (base != null) return (a - base).abs();
        }
        return a.abs();
      case EegWatchMetric.coherence:
        return idx.coherence;
      case EegWatchMetric.bandZ:
        return idx.z[rule.band];
      case EegWatchMetric.bandShare:
        return idx.shares[rule.band];
      case EegWatchMetric.frontalActivation:
        return idx.frontalActivation;
      case EegWatchMetric.frontalActivationZ:
        return idx.frontalActivationZ;
      case EegWatchMetric.excludedChannels:
        return idx.excludedChannels.toDouble();
    }
  }

  void _release(String id) {
    _since.remove(id);
    holding.remove(id);
    active.remove(id);
  }

  Future<void> _fire(
    EegWatchRule rule, {
    required double value,
    required DateTime since,
    required DateTime at,
  }) async {
    var markerAdded = false;
    String? recordingId;
    if (rule.autoMarker && autoMarkers.value) {
      final recording = hub.recording;
      if (recording.isRecording) {
        try {
          final m = await recording.addMarker(
            label: rule.label,
            value: rule.markerValue,
            at: at,
            extras: {
              'rule': rule.id,
              'metric': rule.metric.name,
              'band': rule.band,
              'value': value,
              'threshold': rule.threshold,
              'sustainedS': at.difference(since).inMilliseconds / 1000.0,
              'auto': true,
            },
          );
          markerAdded = true;
          recordingId = m.recordingId ?? recording.activeRecording?.id;
        } catch (_) {
          // The recording may have stopped between the check and the call.
        }
      }
    }

    final alert = EegAlert(
      id: 'alert_${at.microsecondsSinceEpoch}_${_alertSeq++}',
      rule: rule,
      value: value,
      threshold: rule.threshold,
      startedAt: since,
      firedAt: at,
      markerAdded: markerAdded,
      recordingId: recordingId,
    );
    alerts.insert(0, alert);
    while (alerts.length > historyLength) {
      alerts.removeLast();
    }
    if (!_alertController.isClosed) _alertController.add(alert);
    capture?.call()?.noteAlert(alert);
  }
}

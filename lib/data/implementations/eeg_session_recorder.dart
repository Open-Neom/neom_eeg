import 'dart:async';

import 'package:hive/hive.dart';

import '../../domain/enums/eeg_device_type.dart';
import '../../domain/models/eeg_band_power.dart';
import '../../domain/models/eeg_session.dart';
import '../../domain/use_cases/eeg_device_service.dart';

/// Hive-based session recorder for EEG data.
///
/// Saves session metadata, 1-second-averaged band power snapshots,
/// and events (artifacts, state changes, markers). Supports CSV export.
class EegSessionRecorder {
  static const _boxName = 'eeg_sessions';

  Box<Map>? _box;
  EegSession? _activeSession;
  final List<Map<String, dynamic>> _powerSnapshots = [];
  final List<Map<String, dynamic>> _events = [];
  int _sampleCount = 0;
  Timer? _snapshotTimer;
  StreamSubscription<List<EegBandPower>>? _bandPowerSub;

  // Accumulator for 1-second averaging
  final List<List<EegBandPower>> _accumulator = [];

  Future<void> init() async {
    _box = await Hive.openBox<Map>(_boxName);
  }

  /// Start recording a new session.
  Future<EegSession> startSession({
    required EegDeviceType deviceType,
    required EegDeviceService deviceService,
  }) async {
    await init();

    _activeSession = EegSession(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      deviceType: deviceType,
      startTime: DateTime.now(),
    );
    _powerSnapshots.clear();
    _events.clear();
    _sampleCount = 0;
    _accumulator.clear();

    // Listen to band power for 1-second snapshots
    _bandPowerSub = deviceService.bandPowerStream.listen((powers) {
      _sampleCount++;
      _accumulator.add(powers);
    });

    // Average and save every 1 second
    _snapshotTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _saveSnapshot(),
    );

    return _activeSession!;
  }

  /// Stop the active session and persist it.
  Future<EegSession?> stopSession() async {
    if (_activeSession == null) return null;

    _snapshotTimer?.cancel();
    await _bandPowerSub?.cancel();
    _saveSnapshot(); // Final flush

    final completed = EegSession(
      id: _activeSession!.id,
      deviceType: _activeSession!.deviceType,
      startTime: _activeSession!.startTime,
      endTime: DateTime.now(),
      sampleCount: _sampleCount,
      events: _events,
    );

    // Persist to Hive
    await _box?.put(completed.id, {
      'session': completed.toJson(),
      'snapshots': _powerSnapshots,
    });

    _activeSession = null;
    return completed;
  }

  /// Add a marker event to the current session.
  void addEvent(String type, {Map<String, dynamic>? data}) {
    _events.add({
      'type': type,
      'timestamp': DateTime.now().toIso8601String(),
      if (data != null) ...data,
    });
  }

  /// Load all saved sessions.
  Future<List<EegSession>> getSessions() async {
    await init();
    final sessions = <EegSession>[];

    for (final key in _box?.keys ?? []) {
      final entry = _box?.get(key);
      if (entry != null && entry.containsKey('session')) {
        final json = Map<String, dynamic>.from(entry['session'] as Map);
        sessions.add(EegSession.fromJson(json));
      }
    }

    sessions.sort((a, b) => b.startTime.compareTo(a.startTime));
    return sessions;
  }

  /// Export session data as CSV string.
  String exportCsv(String sessionId) {
    final entry = _box?.get(sessionId);
    if (entry == null) return '';

    final snapshots = (entry['snapshots'] as List?)
            ?.map((e) => Map<String, dynamic>.from(e as Map))
            .toList() ??
        [];

    if (snapshots.isEmpty) return '';

    final buffer = StringBuffer();
    buffer.writeln('timestamp,channel,delta,theta,alpha,betaLow,betaHigh,gamma');

    for (final snap in snapshots) {
      final ts = snap['timestamp'] as String? ?? '';
      final powers = (snap['powers'] as List?)
              ?.map((p) => Map<String, dynamic>.from(p as Map))
              .toList() ??
          [];

      for (final p in powers) {
        buffer.writeln(
          '$ts,${p['channel']},${p['delta']},${p['theta']},'
          '${p['alpha']},${p['betaLow']},${p['betaHigh']},${p['gamma']}',
        );
      }
    }

    return buffer.toString();
  }

  // --- Private ---

  void _saveSnapshot() {
    if (_accumulator.isEmpty) return;

    // Average across accumulated samples
    final channelMap = <String, List<EegBandPower>>{};
    for (final snapshot in _accumulator) {
      for (final bp in snapshot) {
        channelMap.putIfAbsent(bp.channel, () => []).add(bp);
      }
    }

    final averaged = channelMap.entries.map((entry) {
      final list = entry.value;
      final n = list.length;
      return {
        'channel': entry.key,
        'delta': list.fold(0.0, (s, b) => s + b.delta) / n,
        'theta': list.fold(0.0, (s, b) => s + b.theta) / n,
        'alpha': list.fold(0.0, (s, b) => s + b.alpha) / n,
        'betaLow': list.fold(0.0, (s, b) => s + b.betaLow) / n,
        'betaHigh': list.fold(0.0, (s, b) => s + b.betaHigh) / n,
        'gamma': list.fold(0.0, (s, b) => s + b.gamma) / n,
      };
    }).toList();

    _powerSnapshots.add({
      'timestamp': DateTime.now().toIso8601String(),
      'powers': averaged,
    });

    _accumulator.clear();
  }
}

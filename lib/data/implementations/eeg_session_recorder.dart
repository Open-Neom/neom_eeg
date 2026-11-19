import 'dart:async';

import 'package:hive_ce/hive_ce.dart';

import '../../domain/enums/eeg_device_type.dart';
import '../../domain/models/eeg_band_power.dart';
import '../../domain/models/eeg_session.dart';
import '../../domain/use_cases/eeg_device_service.dart';

/// Hive-based session recorder for EEG data.
///
/// Saves session metadata, 1-second-averaged band power snapshots,
/// and events (artifacts, state changes, markers). Supports CSV export.
class EegSessionRecorder {
  /// Session ids are also Hive keys and recording ids: two sessions
  /// started within the same millisecond (a stop immediately followed by a
  /// start) used to share one and overwrite each other. Microseconds, and
  /// never less than the previous id.
  static int _lastIdMicros = 0;

  static String _nextId() {
    var t = DateTime.now().microsecondsSinceEpoch;
    if (t <= _lastIdMicros) t = _lastIdMicros + 1;
    _lastIdMicros = t;
    return '$t';
  }

  static const _boxName = 'eeg_sessions';
  static const int _maxSnapshots = 86400; // 24 hours at 1 Hz
  static const int _maxEvents = 10000;
  static const int _maxAccumulatorFrames = 2048;

  Box<Map>? _box;
  final Map<String, Map<String, dynamic>> _memoryFallback = {};
  EegSession? _activeSession;
  final List<Map<String, dynamic>> _powerSnapshots = [];
  final List<Map<String, dynamic>> _events = [];
  int _sampleCount = 0;
  Timer? _snapshotTimer;
  StreamSubscription<List<EegBandPower>>? _bandPowerSub;

  // Accumulator for 1-second averaging
  final List<List<EegBandPower>> _accumulator = [];

  Future<void> init() async {
    if (_box != null && _box!.isOpen) return;
    if (Hive.isBoxOpen(_boxName)) {
      _box = Hive.box<Map>(_boxName);
      return;
    }
    final completer = Completer<Box<Map>?>();
    runZonedGuarded(
      () async {
        try {
          final box = await Hive.openBox<Map>(_boxName);
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

  /// Start recording a new session.
  Future<EegSession> startSession({
    required EegDeviceType deviceType,
    required EegDeviceService deviceService,
  }) async {
    if (_activeSession != null) {
      await stopSession();
    }
    await init();

    _activeSession = EegSession(
      id: _nextId(),
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
      if (_accumulator.length < _maxAccumulatorFrames) {
        _accumulator.add(powers);
      }
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
    _snapshotTimer = null;
    await _bandPowerSub?.cancel();
    _bandPowerSub = null;
    _saveSnapshot(); // Final flush

    final completed = EegSession(
      id: _activeSession!.id,
      deviceType: _activeSession!.deviceType,
      startTime: _activeSession!.startTime,
      endTime: DateTime.now(),
      sampleCount: _sampleCount,
      events: List<Map<String, dynamic>>.from(_events),
    );

    final record = <String, dynamic>{
      'session': completed.toJson(),
      'snapshots': List<Map<String, dynamic>>.from(_powerSnapshots),
    };

    // Persist to Hive (or memory fallback when Hive is uninitialised)
    if (_box != null && _box!.isOpen) {
      await _box!.put(completed.id, record);
    } else {
      _memoryFallback[completed.id] = record;
    }

    _activeSession = null;
    return completed;
  }

  static final RegExp _controlOrBidiChars = RegExp(
    r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F-\x9F\u0085\u061C\u200B-\u200F\u2028-\u202E\u2060-\u2064\u2066-\u2069\uFEFF]',
  );
  static final RegExp _pairedInternalBlockRe = RegExp(
    r'(?:<\s*(?:think(?:ing)?|thought|memory_recall|auto_memory|system_context)\b[^>]*>[\s\S]*?<\s*/\s*(?:think(?:ing)?|thought|memory_recall|auto_memory|system_context)\s*>|\[\s*(BIOCHIP|MEMORY_RECALL|AUTO_MEMORY|SYSTEM_CONTEXT)\s*\](?:(?!\[\s*\1\s*\])[\s\S])*?\[\s*/\s*\1\s*\])',
    caseSensitive: false,
  );
  static final RegExp _standaloneInternalTagRe = RegExp(
    r'(?:\[\s*/?\s*(?:BIOCHIP(?:\s*:[^\]]*)?|MEMORY_RECALL(?:\s*:[^\]]*)?|AUTO_MEMORY(?:\s*:[^\]]*)?|SYSTEM_CONTEXT(?:\s*:[^\]]*)?)\s*\]|<\s*/?\s*(?:think(?:ing)?|thought|memory_recall|auto_memory|system_context)\b[^>]*>)',
    caseSensitive: false,
  );

  static String _sanitizeStringValue(String raw, {int maxChars = 1024}) {
    final stripped = raw
        .replaceAll(_pairedInternalBlockRe, '')
        .replaceAll(_standaloneInternalTagRe, '')
        .replaceAll(_controlOrBidiChars, '')
        .trim();
    if (stripped.length <= maxChars) return stripped;
    var end = maxChars;
    final cu = stripped.codeUnitAt(end - 1);
    if (cu >= 0xD800 && cu <= 0xDBFF) end--;
    return stripped.substring(0, end);
  }

  /// Add a marker event to the current session.
  void addEvent(String type, {Map<String, dynamic>? data}) {
    if (_events.length >= _maxEvents) return;
    final safeData = <String, dynamic>{};
    if (data != null) {
      for (final entry in data.entries.take(64)) {
        final cleanKey = entry.key.replaceAll(_controlOrBidiChars, '').trim();
        final lower = cleanKey.toLowerCase();
        if (cleanKey.isEmpty ||
            cleanKey.length > 128 ||
            lower == '__proto__' ||
            lower == 'constructor' ||
            lower == 'prototype' ||
            (lower.startsWith('__') && lower.endsWith('__'))) {
          continue;
        }
        final val = entry.value;
        safeData[cleanKey] = val is String ? _sanitizeStringValue(val) : val;
      }
    }
    _events.add({
      'type': _sanitizeStringValue(type, maxChars: 128),
      'timestamp': DateTime.now().toIso8601String(),
      ...safeData,
    });
  }

  /// Load all saved sessions.
  Future<List<EegSession>> getSessions() async {
    await init();
    final sessions = <EegSession>[];
    final entries = (_box != null && _box!.isOpen)
        ? _box!.values
        : _memoryFallback.values;

    for (final entry in entries) {
      if (entry.containsKey('session') && entry['session'] is Map) {
        try {
          final json = Map<String, dynamic>.from(entry['session'] as Map);
          sessions.add(EegSession.fromJson(json));
        } catch (_) {}
      }
    }

    sessions.sort((a, b) => b.startTime.compareTo(a.startTime));
    return sessions;
  }

  static final RegExp _numericPattern = RegExp(r'^-?\d+(\.\d+)?([eE][+-]?\d+)?$');
  static final RegExp _formulaTriggerRe = RegExp(r'^[\s\u0085\u00A0]*[=+\-@|\t\r]');

  static String _escapeCsvCell(Object? raw) {
    final value = (raw ?? '')
        .toString()
        .replaceAll(_pairedInternalBlockRe, '')
        .replaceAll(_standaloneInternalTagRe, '')
        .replaceAll(_controlOrBidiChars, '');
    if (value.isEmpty) return '';
    var sanitized = value;
    if (_formulaTriggerRe.hasMatch(sanitized) &&
        !_numericPattern.hasMatch(sanitized.trim())) {
      sanitized = "'$sanitized";
    }
    if (sanitized.contains(',') ||
        sanitized.contains('"') ||
        sanitized.contains('\n') ||
        sanitized.contains('\r')) {
      return '"${sanitized.replaceAll('"', '""')}"';
    }
    return sanitized;
  }

  /// Export session data as CSV string.
  String exportCsv(String sessionId) {
    final entry = (_box != null && _box!.isOpen)
        ? _box!.get(sessionId)
        : _memoryFallback[sessionId];
    if (entry == null) return '';

    final snapshots = (entry['snapshots'] as List?)
            ?.whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList() ??
        [];

    if (snapshots.isEmpty) return '';

    final buffer = StringBuffer();
    buffer.writeln('timestamp,channel,delta,theta,alpha,betaLow,betaHigh,gamma');

    for (final snap in snapshots) {
      final ts = _escapeCsvCell(snap['timestamp']);
      final powers = (snap['powers'] as List?)
              ?.whereType<Map>()
              .map((p) => Map<String, dynamic>.from(p))
              .toList() ??
          [];

      for (final p in powers) {
        buffer.writeln(
          '$ts,${_escapeCsvCell(p['channel'])},${_escapeCsvCell(p['delta'])},'
          '${_escapeCsvCell(p['theta'])},${_escapeCsvCell(p['alpha'])},'
          '${_escapeCsvCell(p['betaLow'])},${_escapeCsvCell(p['betaHigh'])},'
          '${_escapeCsvCell(p['gamma'])}',
        );
      }
    }

    return buffer.toString();
  }

  // --- Private ---

  static double _finite(double v) => v.isFinite ? v : 0.0;

  void _saveSnapshot() {
    if (_accumulator.isEmpty) return;
    if (_powerSnapshots.length >= _maxSnapshots) {
      _accumulator.clear();
      return;
    }

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
        'delta': list.fold(0.0, (s, b) => s + _finite(b.delta)) / n,
        'theta': list.fold(0.0, (s, b) => s + _finite(b.theta)) / n,
        'alpha': list.fold(0.0, (s, b) => s + _finite(b.alpha)) / n,
        'betaLow': list.fold(0.0, (s, b) => s + _finite(b.betaLow)) / n,
        'betaHigh': list.fold(0.0, (s, b) => s + _finite(b.betaHigh)) / n,
        'gamma': list.fold(0.0, (s, b) => s + _finite(b.gamma)) / n,
      };
    }).toList();

    _powerSnapshots.add({
      'timestamp': DateTime.now().toIso8601String(),
      'powers': averaged,
    });

    _accumulator.clear();
  }
}

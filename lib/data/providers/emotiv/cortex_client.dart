import 'dart:async';
import 'dart:convert';

import '../../../domain/models/eeg_exceptions.dart';
import 'cortex_transport.dart';

/// An asynchronous `{"warning": {...}}` notification from Cortex.
///
/// Codes this package acts on (full list at
/// https://emotiv.gitbook.io/cortex-api/warning-objects):
/// * 0 streams auto-cancelled · 1 session auto-closed · 2 user login ·
///   3 user logout · 9 app access granted · 10 app access declined ·
///   100/101 headset connection failed · 102 connection timeout ·
///   103 headset disconnected · 104 headset connected · 142 scan finished
class CortexWarning {
  final int code;
  final dynamic message;

  const CortexWarning(this.code, this.message);

  static const accessGranted = 9;
  static const accessDeclined = 10;
  static const streamsCancelled = 0;
  static const sessionClosed = 1;
  static const headsetConnectFailed = 100;
  static const headsetConnectFailedAlt = 101;
  static const headsetConnectTimeout = 102;
  static const headsetDisconnected = 103;
  static const headsetConnected = 104;
  static const scanFinished = 142;

  /// Headset id carried by connection warnings, when present.
  String? get headsetId {
    final m = message;
    if (m is Map) return m['headsetId'] as String?;
    return null;
  }

  String get text => message is Map
      ? (message['behavior'] ?? message['message'] ?? message).toString()
      : message.toString();

  @override
  String toString() => 'CortexWarning($code: $text)';
}

/// One data message from a subscribed stream, still positional.
class CortexSample {
  final String stream;
  final String sid;
  final num? time;
  final List<dynamic> values;

  const CortexSample({
    required this.stream,
    required this.sid,
    required this.time,
    required this.values,
  });
}

/// Column layout Cortex declared for a stream in the `subscribe` result.
class CortexSubscription {
  final String stream;
  final String sid;
  final List<dynamic> cols;

  const CortexSubscription({
    required this.stream,
    required this.sid,
    required this.cols,
  });
}

/// JSON-RPC 2.0 client for the Cortex API over any [CortexTransport].
///
/// Demultiplexes the single inbound message stream into request replies
/// (matched by id), warnings and data samples. Transport-agnostic, so the
/// same client drives EMOTIV Launcher on desktop and the embedded library
/// on mobile.
class CortexClient {
  final CortexTransport transport;
  final Duration requestTimeout;

  int _nextId = 0;
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  final _warnings = StreamController<CortexWarning>.broadcast();
  final _samples = StreamController<CortexSample>.broadcast();
  StreamSubscription<String>? _messagesSub;
  StreamSubscription<void>? _closedSub;

  /// Streams currently subscribed, by stream name.
  final Map<String, CortexSubscription> subscriptions = {};

  CortexClient(
    this.transport, {
    this.requestTimeout = const Duration(seconds: 15),
  });

  Stream<CortexWarning> get warnings => _warnings.stream;
  Stream<CortexSample> get samples => _samples.stream;

  /// Fires when the transport drops the connection.
  Stream<void> get onClosed => transport.onClosed;

  bool get isOpen => transport.isOpen;

  Future<void> open() async {
    if (transport.isOpen) return;
    _messagesSub ??= transport.messages.listen(_onMessage);
    _closedSub ??= transport.onClosed.listen((_) => _failPending(
          const EegException('Cortex connection closed'),
        ));
    await transport.open();
  }

  Future<void> close() async {
    _failPending(const EegException('Cortex client closed'));
    subscriptions.clear();
    await transport.close();
  }

  Future<void> dispose() async {
    await close();
    await _messagesSub?.cancel();
    await _closedSub?.cancel();
    _messagesSub = null;
    _closedSub = null;
    await _warnings.close();
    await _samples.close();
  }

  static const int maxInboundMessageChars = 4 * 1024 * 1024;
  static const int maxPendingRequests = 512;
  static const Set<String> _forbiddenKeys = <String>{
    '__proto__',
    'constructor',
    'prototype',
  };
  static final RegExp _safeMethodRe = RegExp(r'^[A-Za-z][A-Za-z0-9_.-]{0,127}$');
  static final RegExp _controlOrBidiRe = RegExp(
    r'[\x00-\x1F\x7F-\x9F\u0085\u061C\u200B-\u200F\u2028-\u202E\u2060-\u2069\uFEFF]',
  );

  static bool isValidCortexMethod(String method) {
    if (_controlOrBidiRe.hasMatch(method)) return false;
    final trimmed = method.trim();
    if (!_safeMethodRe.hasMatch(trimmed) || trimmed.contains('..')) {
      return false;
    }
    final lower = trimmed.toLowerCase();
    return !_forbiddenKeys.contains(lower) &&
        !(lower.startsWith('__') && lower.endsWith('__'));
  }

  static Object? _sanitizeRpcValue(Object? raw, [int depth = 0]) {
    if (depth > 16 || raw == null) return null;
    if (raw is Map) {
      final out = <String, dynamic>{};
      for (final entry in raw.entries.take(512)) {
        final key = entry.key?.toString() ?? '';
        final lower = key.toLowerCase();
        if (key.isEmpty ||
            _forbiddenKeys.contains(lower) ||
            (lower.startsWith('__') && lower.endsWith('__'))) {
          continue;
        }
        out[key] = _sanitizeRpcValue(entry.value, depth + 1);
      }
      return out;
    }
    if (raw is List) {
      return raw.take(4096).map((e) => _sanitizeRpcValue(e, depth + 1)).toList();
    }
    return raw;
  }

  /// Sends `method` and returns the `result` object.
  ///
  /// Throws [EegProtocolException] when Cortex answers with an `error`
  /// object and [EegTimeoutException] when nothing comes back in time.
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async {
    if (!isValidCortexMethod(method)) {
      throw EegProtocolException('Invalid Cortex RPC method: "$method"');
    }
    if (_pending.length >= maxPendingRequests) {
      throw const EegException('Too many pending Cortex requests');
    }
    _nextId = (_nextId % 0x7FFFFFFF) + 1;
    final id = _nextId;
    final cleanMethod = method.trim();
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;

    try {
      transport.send(jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'method': cleanMethod,
        'params': params,
      }));
    } catch (_) {
      _pending.remove(id);
      rethrow;
    }

    try {
      return await completer.future.timeout(requestTimeout);
    } on TimeoutException {
      _pending.remove(id);
      throw EegTimeoutException('Cortex "$cleanMethod" timed out');
    }
  }

  /// `call` for methods whose result is a bare list (e.g. `queryHeadsets`).
  Future<List<dynamic>> callList(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async {
    final result = await call(method, params);
    return (result['_list'] as List?) ?? const [];
  }

  /// Waits for the first warning accepted by [test].
  Future<CortexWarning> nextWarning(
    bool Function(CortexWarning w) test, {
    required Duration timeout,
  }) =>
      warnings.firstWhere(test).timeout(timeout);

  // ── Inbound demux ───────────────────────────────────────────────────

  void _onMessage(String raw) {
    if (raw.isEmpty || raw.length > maxInboundMessageChars) return;
    Map<String, dynamic> msg;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      msg = Map<String, dynamic>.from(decoded);
    } catch (_) {
      return; // Not JSON; nothing we can route.
    }

    // Reply to one of our requests.
    final rawId = msg['id'];
    final int? id = (rawId is num && rawId.isFinite && rawId == rawId.truncateToDouble())
        ? rawId.toInt()
        : null;
    if (id != null && _pending.containsKey(id)) {
      final completer = _pending.remove(id)!;
      final error = msg['error'];
      if (error is Map) {
        final rawCode = error['code'];
        final errCode = (rawCode is num && rawCode.isFinite) ? rawCode.toInt() : null;
        completer.completeError(EegProtocolException(
          (error['message'] ?? 'Cortex error').toString(),
          code: errCode,
        ));
        return;
      }
      final result = msg['result'];
      if (result is Map) {
        completer.complete(
          _sanitizeRpcValue(result) as Map<String, dynamic>,
        );
      } else if (result is List) {
        completer.complete({'_list': _sanitizeRpcValue(result)});
      } else {
        completer.complete({'_value': result});
      }
      return;
    }

    // Asynchronous warning.
    final warning = msg['warning'];
    if (warning is Map) {
      final code = warning['code'];
      if (code is num && code.isFinite) {
        if (!_warnings.isClosed) {
          _warnings.add(CortexWarning(code.toInt(), warning['message']));
        }
      }
      return;
    }

    // Data sample: exactly one key besides sid/time is the stream name.
    final sid = msg['sid'];
    if (sid is! String) return;
    for (final entry in msg.entries) {
      if (entry.key == 'sid' || entry.key == 'time') continue;
      if (entry.value is List) {
        if (!_samples.isClosed) {
          final rawTime = msg['time'];
          _samples.add(CortexSample(
            stream: entry.key,
            sid: sid,
            time: (rawTime is num && rawTime.isFinite) ? rawTime : null,
            values: entry.value as List<dynamic>,
          ));
        }
        return;
      }
    }
  }

  void _failPending(Object error) {
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(error);
    }
    _pending.clear();
  }
}

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

  /// Sends `method` and returns the `result` object.
  ///
  /// Throws [EegProtocolException] when Cortex answers with an `error`
  /// object and [EegTimeoutException] when nothing comes back in time.
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async {
    final id = ++_nextId;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;

    transport.send(jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    }));

    try {
      return await completer.future.timeout(requestTimeout);
    } on TimeoutException {
      _pending.remove(id);
      throw EegTimeoutException('Cortex "$method" timed out');
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
    Map<String, dynamic> msg;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return;
      msg = decoded;
    } catch (_) {
      return; // Not JSON; nothing we can route.
    }

    // Reply to one of our requests.
    final id = msg['id'];
    if (id is int && _pending.containsKey(id)) {
      final completer = _pending.remove(id)!;
      final error = msg['error'];
      if (error is Map) {
        completer.completeError(EegProtocolException(
          (error['message'] ?? 'Cortex error').toString(),
          code: error['code'] as int?,
        ));
        return;
      }
      final result = msg['result'];
      if (result is Map<String, dynamic>) {
        completer.complete(result);
      } else if (result is List) {
        completer.complete({'_list': result});
      } else {
        completer.complete({'_value': result});
      }
      return;
    }

    // Asynchronous warning.
    final warning = msg['warning'];
    if (warning is Map) {
      final code = warning['code'];
      if (code is int) _warnings.add(CortexWarning(code, warning['message']));
      return;
    }

    // Data sample: exactly one key besides sid/time is the stream name.
    final sid = msg['sid'];
    if (sid is! String) return;
    for (final entry in msg.entries) {
      if (entry.key == 'sid' || entry.key == 'time') continue;
      if (entry.value is List) {
        _samples.add(CortexSample(
          stream: entry.key,
          sid: sid,
          time: msg['time'] as num?,
          values: entry.value as List<dynamic>,
        ));
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

import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../../../domain/enums/eeg_vendor.dart';
import '../../../domain/models/eeg_exceptions.dart';
import 'cortex_socket_stub.dart' if (dart.library.io) 'cortex_socket_io.dart';
import 'cortex_transport.dart';

/// [CortexTransport] over the WebSocket exposed by EMOTIV Launcher.
///
/// Desktop and web. The platform-specific socket factory handles the
/// self-signed certificate (`cortex_socket_io.dart`) or defers to the
/// browser (`cortex_socket_stub.dart`).
class CortexWebSocketTransport implements CortexTransport {
  final Uri uri;
  final Duration connectTimeout;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  final _messages = StreamController<String>.broadcast();
  final _closed = StreamController<void>.broadcast();

  CortexWebSocketTransport({
    Uri? uri,
    this.connectTimeout = const Duration(seconds: 5),
  }) : uri = uri ?? Uri.parse('wss://localhost:6868');

  static const int maxInboundFrameChars = 4 * 1024 * 1024;
  static final RegExp _controlOrBidiChars = RegExp(
    r'[\x00-\x1F\x7F-\x9F\u0085\u061C\u200B-\u200F\u2028-\u202E\u2060\u2066-\u2069\uFEFF\\]',
  );

  /// Only local loopback `wss://` or `ws://` endpoints may carry Cortex
  /// credentials (`clientSecret`) and live EEG streams.
  static bool isAllowedCortexUri(Uri target) {
    final raw = target.toString();
    if (raw.isEmpty || raw.length > 512 || _controlOrBidiChars.hasMatch(raw)) {
      return false;
    }
    if (target.userInfo.isNotEmpty) return false;
    final scheme = target.scheme.toLowerCase();
    if (scheme != 'wss' && scheme != 'ws') return false;
    if (target.hasPort && (target.port < 1 || target.port > 65535)) {
      return false;
    }
    var host = target.host.trim().toLowerCase();
    if (host.startsWith('[') && host.endsWith(']')) {
      host = host.substring(1, host.length - 1);
    }
    while (host.endsWith('.')) {
      host = host.substring(0, host.length - 1);
    }
    return host == 'localhost' || host == '127.0.0.1' || host == '::1';
  }

  @override
  bool get isSupported => cortexServiceReachable;

  @override
  String? get unsupportedReason => cortexServiceUnsupportedReason;

  @override
  bool get isOpen => _channel != null;

  @override
  Stream<String> get messages => _messages.stream;

  @override
  Stream<void> get onClosed => _closed.stream;

  @override
  Future<void> open() async {
    if (_channel != null) return;
    if (!isAllowedCortexUri(uri)) {
      throw EegException(
        'URI de Cortex insegura (${uri.scheme}://${uri.host}): '
        'se requiere wss:// o loopback local.',
      );
    }
    if (!isSupported) {
      throw EegDriverUnavailableException(
        unsupportedReason ?? 'Cortex service not reachable',
        vendor: EegVendor.emotiv,
      );
    }

    final channel = connectCortexSocket(uri);
    try {
      await channel.ready.timeout(connectTimeout);
    } on TimeoutException {
      unawaited(channel.sink.close().catchError((_) {}));
      throw const EegTimeoutException(
        'EMOTIV Launcher no responde en wss://localhost:6868. '
        '¿Está abierto y con sesión iniciada?',
      );
    } catch (e) {
      unawaited(channel.sink.close().catchError((_) {}));
      throw EegException(
        'No se pudo abrir el WebSocket de Cortex: $e',
        cause: e,
      );
    }

    _channel = channel;
    _sub = channel.stream.listen(
      (raw) {
        if (_messages.isClosed) return;
        if (raw is String) {
          if (raw.length <= maxInboundFrameChars) {
            _messages.add(raw);
          }
        } else if (raw is List<int>) {
          if (raw.length <= maxInboundFrameChars) {
            _messages.add(utf8.decode(raw, allowMalformed: true));
          }
        }
      },
      onError: (_) => _dropChannel(),
      onDone: _dropChannel,
      cancelOnError: true,
    );
  }

  @override
  void send(String json) {
    final channel = _channel;
    if (channel == null) {
      throw const EegException('Cortex WebSocket is not open');
    }
    channel.sink.add(json);
  }

  @override
  Future<void> close() async {
    final channel = _channel;
    _channel = null;
    await _sub?.cancel();
    _sub = null;
    await channel?.sink.close();
  }

  Future<void> dispose() async {
    await close();
    if (!_messages.isClosed) await _messages.close();
    if (!_closed.isClosed) await _closed.close();
  }

  @override
  Future<String?> authenticate(String clientId) async => null;

  void _dropChannel() {
    if (_channel == null) return;
    _channel = null;
    _sub = null;
    if (!_closed.isClosed) _closed.add(null);
  }
}

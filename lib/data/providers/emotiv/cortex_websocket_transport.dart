import 'dart:async';

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
      throw const EegTimeoutException(
        'EMOTIV Launcher no responde en wss://localhost:6868. '
        '¿Está abierto y con sesión iniciada?',
      );
    } catch (e) {
      throw EegException(
        'No se pudo abrir el WebSocket de Cortex: $e',
        cause: e,
      );
    }

    _channel = channel;
    _sub = channel.stream.listen(
      (raw) {
        if (raw is String) {
          _messages.add(raw);
        } else if (raw is List<int>) {
          _messages.add(String.fromCharCodes(raw));
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

  @override
  Future<String?> authenticate(String clientId) async => null;

  void _dropChannel() {
    if (_channel == null) return;
    _channel = null;
    _sub = null;
    if (!_closed.isClosed) _closed.add(null);
  }
}

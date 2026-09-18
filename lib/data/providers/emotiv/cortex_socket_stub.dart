import 'package:web_socket_channel/web_socket_channel.dart';

/// Web build: the browser owns TLS, so the user must first visit
/// `https://localhost:6868` once and accept the Cortex self-signed
/// certificate; after that the plain channel connects.
WebSocketChannel connectCortexSocket(Uri uri) => WebSocketChannel.connect(uri);

/// Whether a local Cortex service can be reached from this platform.
bool get cortexServiceReachable => true;

String? get cortexServiceUnsupportedReason => null;

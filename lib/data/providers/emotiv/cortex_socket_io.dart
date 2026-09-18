import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'emotiv_root_ca.dart';

/// Native build. Cortex serves `wss://localhost:6868` with a certificate
/// signed by Emotiv's own root CA, so the default [HttpClient] would refuse
/// the handshake. The root is pinned ([emotivRootCaPem]) so a genuine Cortex
/// validates cleanly; only when that fails is the loopback host exempted,
/// which covers Launcher builds that rotate the chain. Anything not on
/// loopback keeps normal TLS validation.
WebSocketChannel connectCortexSocket(Uri uri) {
  final context = SecurityContext(withTrustedRoots: true);
  try {
    context.setTrustedCertificatesBytes(utf8.encode(emotivRootCaPem));
  } on TlsException {
    // Root already present in the store (macOS keychain import by the
    // Emotiv installer); nothing to add.
  }
  final client = HttpClient(context: context)
    ..badCertificateCallback = (X509Certificate cert, String host, int port) =>
        _isLoopback(host) && port == uri.port;
  return IOWebSocketChannel.connect(uri, customClient: client);
}

bool _isLoopback(String host) =>
    host == 'localhost' || host == '127.0.0.1' || host == '::1';

/// EMOTIV Launcher (which hosts the Cortex service) only ships for
/// Windows, macOS and Linux. On phones the embedded library is the path.
bool get cortexServiceReachable => switch (defaultTargetPlatform) {
      TargetPlatform.macOS ||
      TargetPlatform.windows ||
      TargetPlatform.linux =>
        true,
      _ => false,
    };

String? get cortexServiceUnsupportedReason => cortexServiceReachable
    ? null
    : 'EMOTIV Launcher no existe para ${defaultTargetPlatform.name}; '
        'en móvil se usa la Cortex Library embebida.';

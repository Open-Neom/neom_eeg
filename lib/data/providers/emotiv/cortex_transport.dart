/// Byte pipe between [CortexClient] and a Cortex endpoint.
///
/// Cortex speaks the same JSON-RPC 2.0 dialect everywhere; only the carrier
/// differs: a WebSocket to the local EMOTIV Launcher on desktop/web, or the
/// embedded Cortex library behind a platform channel on iOS/Android. Keeping
/// the carrier behind this interface lets one provider serve both.
abstract class CortexTransport {
  /// Whether this carrier can work on the current platform (without I/O).
  bool get isSupported;

  /// User-facing reason when [isSupported] is false.
  String? get unsupportedReason;

  /// Whether a session with the endpoint is currently open.
  bool get isOpen;

  /// Inbound JSON text: responses, warnings and data samples, one message
  /// per event. Broadcast; safe to subscribe before [open].
  Stream<String> get messages;

  /// Fires once when the endpoint goes away on its own.
  Stream<void> get onClosed;

  Future<void> open();

  void send(String json);

  Future<void> close();

  /// Mobile-only login step: the embedded library shows EMOTIV's OAuth
  /// page and returns an authentication code the provider exchanges with
  /// `loginWithAuthenticationCode`. Desktop transports return null because
  /// the user logs in through EMOTIV Launcher.
  Future<String?> authenticate(String clientId) async => null;
}

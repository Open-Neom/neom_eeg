import 'package:neom_core/app_properties.dart';

/// Credentials and options for the Emotiv Cortex API.
///
/// `clientId`/`clientSecret` come from the app registered at
/// https://www.emotiv.com/my-account/cortex-apps/. The same pair works for
/// the desktop Cortex service and the embedded mobile library.
///
/// Host apps normally build this with [EmotivCortexConfig.fromAppProperties]
/// so the secret lives in `properties.json` (`emotivClientId`,
/// `emotivClientSecret`, optional `emotivLicense`) instead of in code.
class EmotivCortexConfig {
  final String clientId;
  final String clientSecret;

  /// Explicit license id. Leave null to let Cortex pick the license bound
  /// to the client id.
  final String? license;

  /// Sessions to debit from the license on `authorize`, so raw EEG can be
  /// streamed offline until they are spent. Zero only allows the free
  /// streams (performance metrics, motion, device status).
  final int debit;

  /// Cortex service endpoint. The service only listens on localhost.
  final String host;
  final int port;

  /// Streams to subscribe to once a session is active. Streams the license
  /// does not cover are reported by Cortex and skipped; the rest still
  /// flow, so a free license degrades to `met`/`dev`/`eq`/`mot` instead of
  /// failing.
  final List<String> streams;

  /// How long to keep polling `requestAccess` while the user approves the
  /// app in EMOTIV Launcher.
  final Duration accessApprovalTimeout;

  /// Interval between `requestAccess` polls.
  final Duration accessPollInterval;

  /// How long to wait for a headset to report `connected` after
  /// `controlDevice connect`.
  final Duration headsetConnectTimeout;

  /// Per-request JSON-RPC timeout.
  final Duration requestTimeout;

  const EmotivCortexConfig({
    required this.clientId,
    required this.clientSecret,
    this.license,
    this.debit = 1,
    this.host = 'localhost',
    this.port = 6868,
    this.streams = const ['eeg', 'pow', 'met', 'dev', 'eq', 'mot'],
    this.accessApprovalTimeout = const Duration(seconds: 90),
    this.accessPollInterval = const Duration(seconds: 2),
    this.headsetConnectTimeout = const Duration(seconds: 25),
    this.requestTimeout = const Duration(seconds: 15),
  });

  /// Reads `emotivClientId` / `emotivClientSecret` / `emotivLicense` from the
  /// host app's properties. Returns null when the id or secret is missing,
  /// so the hub can simply not register the Emotiv driver.
  static EmotivCortexConfig? fromAppProperties() {
    final props = AppProperties.appProperties;
    if (props == null) return null;
    final id = (props['emotivClientId'] as String?)?.trim() ?? '';
    final secret = (props['emotivClientSecret'] as String?)?.trim() ?? '';
    if (id.isEmpty || secret.isEmpty) return null;
    final license = (props['emotivLicense'] as String?)?.trim();
    return EmotivCortexConfig(
      clientId: id,
      clientSecret: secret,
      license: (license == null || license.isEmpty) ? null : license,
    );
  }

  static final RegExp _controlOrBidiChars = RegExp(
    r'[\x00-\x1F\x7F-\x9F\u0085\u061C\u200B-\u200F\u2028-\u202E\u2060\u2066-\u2069\uFEFF]',
  );

  Uri get serviceUri {
    final cleanHost = host.trim();
    final safePort = (port >= 1 && port <= 65535) ? port : 6868;
    return Uri(
      scheme: 'wss',
      host: cleanHost.isEmpty ? 'localhost' : cleanHost,
      port: safePort,
    );
  }

  bool get isConfigured =>
      clientId.trim().isNotEmpty &&
      clientSecret.trim().isNotEmpty &&
      !_controlOrBidiChars.hasMatch(clientId) &&
      !_controlOrBidiChars.hasMatch(clientSecret);

  EmotivCortexConfig copyWith({
    String? clientId,
    String? clientSecret,
    String? license,
    int? debit,
    String? host,
    int? port,
    List<String>? streams,
    Duration? accessApprovalTimeout,
    Duration? accessPollInterval,
    Duration? headsetConnectTimeout,
    Duration? requestTimeout,
  }) =>
      EmotivCortexConfig(
        clientId: clientId ?? this.clientId,
        clientSecret: clientSecret ?? this.clientSecret,
        license: license ?? this.license,
        debit: debit ?? this.debit,
        host: host ?? this.host,
        port: port ?? this.port,
        streams: streams ?? this.streams,
        accessApprovalTimeout:
            accessApprovalTimeout ?? this.accessApprovalTimeout,
        accessPollInterval: accessPollInterval ?? this.accessPollInterval,
        headsetConnectTimeout:
            headsetConnectTimeout ?? this.headsetConnectTimeout,
        requestTimeout: requestTimeout ?? this.requestTimeout,
      );
}

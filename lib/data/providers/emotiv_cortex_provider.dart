import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../domain/enums/eeg_connection_state.dart';
import '../../domain/enums/eeg_device_type.dart';
import '../../domain/enums/eeg_transport.dart';
import '../../domain/enums/eeg_vendor.dart';
import '../../domain/models/eeg_capabilities.dart';
import '../../domain/models/eeg_channel_catalog.dart';
import '../../domain/models/eeg_device_info.dart';
import '../../domain/models/eeg_device_status.dart';
import '../../domain/models/eeg_exceptions.dart';
import '../../domain/models/eeg_recording.dart';
import '../../domain/models/emotiv_cortex_config.dart';
import '../../domain/use_cases/eeg_recording_service.dart';
import '../drivers/eeg_driver_base.dart';
import 'emotiv/cortex_client.dart';
import 'emotiv/cortex_models.dart';
import 'emotiv/cortex_native_transport.dart';
import 'emotiv/cortex_stream_parser.dart';
import 'emotiv/cortex_transport.dart';
import 'emotiv/cortex_websocket_transport.dart';

/// [EegDriver] for every Emotiv headset (EPOC X, EPOC+, EPOC Flex,
/// Insight, MN8) through the Cortex API.
///
/// Same JSON-RPC dialect on every platform; only the carrier changes:
/// * desktop / web → [CortexWebSocketTransport] to EMOTIV Launcher
/// * iOS / Android → [CortexNativeTransport] to the embedded Cortex library
///
/// Connection follows the documented flow — `getUserLogin` →
/// `requestAccess` (polled until the user approves the app in EMOTIV
/// Launcher) → `authorize` → `controlDevice connect` → `createSession` →
/// `subscribe` — and parses every stream by the `cols` Cortex declares, so
/// the 5-channel Insight and the 32-channel Flex go through the same code.
///
/// Cortex computes band powers and performance metrics on its side, so this
/// driver reports [EegCapabilities.nativeBandPower] and
/// [EegCapabilities.nativeMentalMetrics]; the hub does not need to run the
/// FFT for Emotiv devices.
/// Beyond streaming, the provider exposes what the rest of the Cortex API
/// offers a session: native records and markers ([EegRecordingService]),
/// license inspection ([licenseInfo]), headset configuration
/// ([updateHeadsetSettings]) and virtual headsets for testing without
/// hardware ([createVirtualHeadset], mobile library only).
class EmotivCortexProvider extends EegDriverBase implements EegRecordingService {
  final EmotivCortexConfig config;
  final CortexTransport transport;
  late final CortexClient _client;

  /// Called each time `requestAccess` comes back unapproved, with Cortex's
  /// message. UIs use it to tell the user to open EMOTIV Launcher and
  /// accept the app.
  final void Function(String message)? onAccessPending;

  String? _cortexToken;
  String? _sessionId;
  EegRecording? _activeRecording;
  final _markers = StreamController<EegMarker>.broadcast();
  final _recordingChanges = StreamController<EegRecording?>.broadcast();
  CortexLicenseInfo? _license;
  EegDeviceStatus _status = EegDeviceStatus(timestamp: DateTime.now());
  StreamSubscription<CortexSample>? _samplesSub;
  StreamSubscription<CortexWarning>? _warningsSub;
  StreamSubscription<void>? _closedSub;

  EmotivCortexProvider({
    required this.config,
    CortexTransport? transport,
    this.onAccessPending,
  }) : transport = transport ?? defaultTransport(config) {
    _client = CortexClient(this.transport, requestTimeout: config.requestTimeout);
  }

  /// Embedded library on phones, WebSocket to the Launcher elsewhere.
  static CortexTransport defaultTransport(EmotivCortexConfig config) {
    final mobile = !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.android);
    return mobile
        ? CortexNativeTransport()
        : CortexWebSocketTransport(uri: config.serviceUri);
  }

  EegTransport get activeTransport => transport is CortexNativeTransport
      ? EegTransport.cortexLibrary
      : EegTransport.cortexService;

  /// Streams Cortex accepted in the last `subscribe`. Missing `eeg`/`pow`
  /// here while `met`/`dev` are present means the license has no raw-EEG
  /// entitlement — the usual first thing to check on a new setup.
  List<String> get activeStreams => _client.subscriptions.keys.toList();

  // ── EegDriver ───────────────────────────────────────────────────────

  @override
  EegVendor get vendor => EegVendor.emotiv;

  @override
  Set<EegDeviceType> get supportedTypes =>
      EegDeviceType.ofVendor(EegVendor.emotiv).toSet();

  @override
  EegCapabilities capabilitiesFor(EegDeviceType type) {
    if (!supports(type)) return EegCapabilities.none;
    return EegCapabilities(
      nativeBandPower: true,
      nativeMentalMetrics: true,
      contactQuality: true,
      motion: true,
      battery: true,
      markers: true,
      temporalCoverage:
          EegChannelCatalog.hasTemporalCoverage(EegChannelCatalog.labelsFor(type)),
      transports: const {EegTransport.cortexService, EegTransport.cortexLibrary},
    );
  }

  @override
  bool get isAvailable => config.isConfigured && transport.isSupported;

  @override
  String? get unavailableReason {
    if (!config.isConfigured) {
      return 'Faltan emotivClientId / emotivClientSecret en properties.json.';
    }
    return transport.unsupportedReason;
  }

  @override
  Future<List<EegDeviceInfo>> scan({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final previous = connectionState;
    setConnectionState(EegConnectionState.scanning);
    try {
      await _client.open();
      await _ensureLoggedIn();

      // `refresh` restarts the Launcher's own discovery; 142 says it ended.
      await _client.call('controlDevice', {'command': 'refresh'});
      await _client
          .nextWarning((w) => w.code == CortexWarning.scanFinished,
              timeout: timeout < _maxRefreshWait ? timeout : _maxRefreshWait)
          .catchError((_) => const CortexWarning(-1, null));

      final headsets = await _client.callList('queryHeadsets');
      return [
        for (final h in headsets)
          if (h is Map<String, dynamic>) _deviceFromHeadset(h),
      ];
    } finally {
      setConnectionState(
        previous == EegConnectionState.streaming ? previous : EegConnectionState.disconnected,
      );
    }
  }

  static const _maxRefreshWait = Duration(seconds: 4);

  @override
  Future<void> connect(EegDeviceInfo device) async {
    if (!supports(device.type)) {
      throw EegDriverUnavailableException(
        '${device.type.displayName} no es un headset Emotiv',
        vendor: vendor,
        type: device.type,
      );
    }

    setConnectionState(EegConnectionState.connecting);
    setConnectedDevice(device);
    try {
      await _client.open();
      _listenLifecycle();
      await _ensureLoggedIn();
      await _ensureAccess();
      _cortexToken = await _authorize();
      final headset = await _ensureHeadsetConnected(device.id);
      // Cortex knows the real sensor list and rate; prefer it to the
      // catalog defaults the scan may have used.
      setConnectedDevice(_deviceFromHeadset(headset, fallback: device));
      _sessionId = await _createSession(device.id);
      // Official practice (cortex-example, Dec 2025): sync clocks right after
      // the session opens so record/marker timestamps line up with the EEG.
      try {
        clockAdjustment = await syncClock();
      } catch (_) {
        clockAdjustment = null; // Older Cortex builds: markers still work.
      }
      await _subscribe();
      _listenSamples();
      setConnectionState(EegConnectionState.streaming);
    } catch (e) {
      setConnectionState(EegConnectionState.error);
      setConnectedDevice(null);
      await _teardownSession();
      rethrow;
    }
  }

  @override
  Future<void> disconnect() async {
    await _teardownSession();
    setConnectedDevice(null);
    setConnectionState(EegConnectionState.disconnected);
  }

  @override
  Future<void> dispose() async {
    await disconnect();
    await _warningsSub?.cancel();
    await _closedSub?.cancel();
    await _client.dispose();
    await _markers.close();
    await _recordingChanges.close();
    await super.dispose();
  }

  // ── Session-scoped API: records, markers, license, headset ──────────

  /// Token/session guard for the calls below.
  ({String token, String session}) _requireSession() {
    final token = _cortexToken;
    final session = _sessionId;
    if (token == null || session == null || !isStreaming) {
      throw const EegException(
        'Conecta el headset antes de usar records, markers o ajustes',
      );
    }
    return (token: token, session: session);
  }

  @override
  EegRecordingBackend get backend => EegRecordingBackend.native;

  @override
  bool get isRecording => _activeRecording != null;

  @override
  EegRecording? get activeRecording => _activeRecording;

  @override
  Stream<EegMarker> get markerStream => _markers.stream;

  @override
  Stream<EegRecording?> get activeRecordingStream => _recordingChanges.stream;

  /// EMOTIV Launcher writes the files itself; the embedded library has no
  /// export at all.
  @override
  bool get canExportToFolder => activeTransport == EegTransport.cortexService;

  @override
  Future<EegRecording> startRecording({
    required String title,
    String? description,
    String? subject,
    List<String> tags = const [],
  }) async {
    final s = _requireSession();
    if (_activeRecording != null) await stopRecording();
    final result = await _client.call('createRecord', {
      'cortexToken': s.token,
      'session': s.session,
      'title': title,
      'description': ?description,
      'subjectName': ?subject,
      if (tags.isNotEmpty) 'tags': tags,
    });
    final record = (result['record'] as Map?)?.cast<String, dynamic>() ?? result;
    _activeRecording = _recordingFrom(record, fallbackTitle: title);
    _recordingChanges.add(_activeRecording);
    return _activeRecording!;
  }

  @override
  Future<EegRecording?> stopRecording() async {
    final active = _activeRecording;
    if (active == null) return null;
    final s = _requireSession();
    final result = await _client.call('stopRecord', {
      'cortexToken': s.token,
      'session': s.session,
    });
    _activeRecording = null;
    _recordingChanges.add(null);
    final record = (result['record'] as Map?)?.cast<String, dynamic>();
    return record == null
        ? active.copyWith(endedAt: DateTime.now())
        : _recordingFrom(record, fallbackTitle: active.title)
            .copyWith(markerCount: active.markerCount);
  }

  @override
  Future<EegMarker> addMarker({
    required String label,
    Object value = 1,
    DateTime? at,
    String port = 'Software',
    Map<String, dynamic> extras = const {},
  }) async {
    final s = _requireSession();
    final active = _activeRecording;
    if (active == null) {
      throw const EegException(
        'Cortex sólo acepta markers dentro de un record: inicia la grabación',
      );
    }
    if (value is int && value < 0) {
      throw const EegException('Cortex requiere valores de marker ≥ 0');
    }
    final when = at ?? DateTime.now();
    final result = await _client.call('injectMarker', {
      'cortexToken': s.token,
      'session': s.session,
      'time': when.millisecondsSinceEpoch,
      'value': value,
      'label': label,
      'port': port,
      if (extras.isNotEmpty) 'extras': extras,
    });
    final m = (result['marker'] as Map?)?.cast<String, dynamic>() ?? {};
    final marker = EegMarker(
      id: (m['uuid'] ?? m['id'] ?? '${active.id}-${when.millisecondsSinceEpoch}')
          .toString(),
      label: label,
      value: value,
      at: when,
      port: port,
      extras: extras,
      recordingId: (result['recordId'] as String?) ?? active.id,
    );
    _activeRecording = active.copyWith(markerCount: active.markerCount + 1);
    _markers.add(marker);
    return marker;
  }

  @override
  Future<List<EegRecording>> listRecordings({int limit = 50}) async {
    final token = _cortexToken ?? await _tokenForQueries();
    final result = await _client.call('queryRecords', {
      'cortexToken': token,
      'query': <String, dynamic>{},
      'orderBy': [
        {'startDatetime': 'DESC'},
      ],
      'limit': limit,
      'offset': 0,
    });
    return [
      for (final r in (result['records'] as List?) ?? const [])
        if (r is Map) _recordingFrom(r.cast<String, dynamic>()),
    ];
  }

  @override
  Future<EegExportResult> exportRecordings({
    required List<String> ids,
    required String folder,
    EegExportFormat format = EegExportFormat.csv,
    Set<EegExportStream> streams = const {
      EegExportStream.eeg,
      EegExportStream.bandPower,
      EegExportStream.performanceMetrics,
    },
  }) async {
    if (!canExportToFolder) {
      return EegExportResult(
        exported: const [],
        failed: {
          for (final id in ids)
            id: 'La Cortex Library móvil no exporta; usa EMOTIV Launcher o '
                'EmotivPRO en escritorio',
        },
        folder: folder,
        format: format,
      );
    }
    final token = _cortexToken ?? await _tokenForQueries();
    final result = await _client.call('exportRecord', {
      'cortexToken': token,
      'recordIds': ids,
      'folder': folder,
      'format': format.cortexName,
      'streamTypes': [for (final s in streams) s.cortexName],
      'version': 'V2',
    });
    final ok = <String>[];
    final failed = <String, String>{};
    for (final e in (result['success'] as List?) ?? const []) {
      if (e is Map && e['recordId'] != null) ok.add(e['recordId'].toString());
    }
    for (final e in (result['failure'] as List?) ?? const []) {
      if (e is Map && e['recordId'] != null) {
        failed[e['recordId'].toString()] = (e['message'] ?? e['code']).toString();
      }
    }
    return EegExportResult(exported: ok, failed: failed, folder: folder, format: format);
  }

  /// License bound to the app's client id. Cached after the first call;
  /// pass `refresh: true` to ask Cortex again.
  Future<CortexLicenseInfo> licenseInfo({bool refresh = false}) async {
    if (_license != null && !refresh) return _license!;
    final token = _cortexToken ?? await _tokenForQueries();
    final result = await _client.call('getLicenseInfo', {'cortexToken': token});
    return _license = CortexLicenseInfo.fromResult(result);
  }

  /// Version of the Cortex service / library we are talking to.
  Future<CortexInfo> cortexInfo() async {
    await _client.open();
    return CortexInfo.fromResult(await _client.call('getCortexInfo'));
  }

  /// Changes sampling rates / mode on the connected headset. Returns the
  /// headset object Cortex reports afterwards; the connected device info is
  /// refreshed from it.
  Future<EegDeviceInfo> updateHeadsetSettings(CortexHeadsetSettings settings) async {
    final s = _requireSession();
    final device = connectedDevice!;
    await _client.call('updateHeadset', {
      'cortexToken': s.token,
      'headset': device.id,
      'setting': settings.toJson(),
    });
    final headset = await _queryHeadset(device.id) ?? {'id': device.id};
    final updated = _deviceFromHeadset(headset, fallback: device);
    setConnectedDevice(updated);
    return updated;
  }

  /// Offset (seconds) between the headset clock and this machine as
  /// reported by the last [syncClock]; null before the first sync.
  double? clockAdjustment;

  /// Process-monotonic clock, the counterpart of Python's
  /// `time.monotonic()` that Emotiv's examples send as `monotonicTime`.
  static final _monotonic = Stopwatch()..start();

  /// Asks Cortex to relate its headset clock to this machine's clocks, so
  /// marker timestamps line up with the EEG samples. Called automatically
  /// after `createSession`; call again if the machine sleeps mid-session.
  Future<double> syncClock() async {
    final device = connectedDevice;
    if (device == null) throw const EegException('Sin headset conectado');
    final result = await _client.call('syncWithHeadsetClock', {
      'headset': device.id,
      'monotonicTime': _monotonic.elapsedMicroseconds / 1e6,
      'systemTime': DateTime.now().millisecondsSinceEpoch / 1000.0,
    });
    return clockAdjustment = (result['adjustment'] as num?)?.toDouble() ?? 0.0;
  }

  /// Creates a simulated headset inside the embedded Cortex library so a
  /// phone can exercise the full flow without hardware. Mobile only —
  /// the desktop service rejects the method.
  Future<EegDeviceInfo> createVirtualHeadset(
    EegDeviceType type, {
    String? name,
    bool powerOn = true,
    int battery = 4,
  }) async {
    final cortexType = switch (type) {
      EegDeviceType.emotivInsight => 'INSIGHT',
      EegDeviceType.emotivEpocX => 'EPOCX',
      EegDeviceType.emotivEpocPlus => 'EPOCPLUS',
      EegDeviceType.emotivEpocFlex => 'EPOCFLEX',
      EegDeviceType.emotivMn8 => 'MN8',
      _ => throw EegDriverUnavailableException(
          '${type.displayName} no es un modelo Emotiv',
          vendor: vendor,
          type: type,
        ),
    };
    final token = _cortexToken ?? await _tokenForQueries();
    final result = await _client.call('createVirtualHeadset', {
      'cortexToken': token,
      'type': cortexType,
      'name': ?name,
      'powerOn': powerOn,
      'battery': battery,
    });
    return _deviceFromHeadset(result);
  }

  /// Token for calls that do not need a session (queries, license). Runs
  /// the access/authorize steps if no connection did it yet.
  Future<String> _tokenForQueries() async {
    await _client.open();
    _listenLifecycle();
    await _ensureLoggedIn();
    await _ensureAccess();
    return _cortexToken = await _authorize();
  }

  EegRecording _recordingFrom(Map<String, dynamic> r, {String? fallbackTitle}) {
    DateTime parse(dynamic v) =>
        v is String ? (DateTime.tryParse(v) ?? DateTime.now()) : DateTime.now();
    final markers = r['markers'];
    return EegRecording(
      id: (r['uuid'] ?? r['id'] ?? '').toString(),
      title: (r['title'] as String?) ?? fallbackTitle ?? '',
      description: r['description'] as String?,
      subject: r['subjectName'] as String?,
      tags: (r['tags'] as List?)?.map((e) => e.toString()).toList() ?? const [],
      startedAt: parse(r['startDatetime'] ?? r['createdTime']),
      endedAt: r['endDatetime'] is String ? parse(r['endDatetime']) : null,
      backend: EegRecordingBackend.native,
      sampleRate: (r['samplingRate'] as num?)?.toInt(),
      markerCount: markers is List ? markers.length : 0,
      metadata: {
        for (final k in ['uuid', 'exportIds', 'fileType', 'licenseId', 'headsetId'])
          if (r[k] != null) k: r[k],
      },
    );
  }

  // ── Handshake steps ─────────────────────────────────────────────────

  Future<void> _ensureLoggedIn() async {
    final users = await _client.callList('getUserLogin');
    if (users.isNotEmpty) return;

    // Phones have no Launcher: the embedded library runs EMOTIV's OAuth
    // page and gives back a code we exchange for a login.
    final code = await transport.authenticate(config.clientId);
    if (code == null) {
      throw const EegAccessDeniedException(
        'Nadie ha iniciado sesión en EMOTIV Launcher. '
        'Abre el Launcher e inicia sesión con tu EmotivID.',
      );
    }
    await _client.call('loginWithAuthenticationCode', {
      'clientId': config.clientId,
      'clientSecret': config.clientSecret,
      'code': code,
    });
  }

  Future<void> _ensureAccess() async {
    final deadline = DateTime.now().add(config.accessApprovalTimeout);
    while (true) {
      final result = await _client.call('requestAccess', {
        'clientId': config.clientId,
        'clientSecret': config.clientSecret,
      });
      if (result['accessGranted'] == true) return;

      final message = (result['message'] ?? '').toString();
      onAccessPending?.call(message);
      if (DateTime.now().isAfter(deadline)) {
        throw EegAccessDeniedException(
          'La app no fue aprobada en EMOTIV Launcher a tiempo. $message',
        );
      }

      // Either the user clicks "approve" (warning 9/10) or we poll again.
      try {
        final w = await _client.nextWarning(
          (w) =>
              w.code == CortexWarning.accessGranted ||
              w.code == CortexWarning.accessDeclined,
          timeout: config.accessPollInterval,
        );
        if (w.code == CortexWarning.accessDeclined) {
          throw const EegAccessDeniedException(
            'El usuario rechazó la app en EMOTIV Launcher.',
          );
        }
        return;
      } on TimeoutException {
        // Poll again.
      }
    }
  }

  Future<String> _authorize() async {
    final result = await _client.call('authorize', {
      'clientId': config.clientId,
      'clientSecret': config.clientSecret,
      if (config.license != null) 'license': config.license,
      'debit': config.debit,
    });
    final warning = result['warning'];
    if (warning is Map) {
      // EULA not accepted: Cortex hands back a URL the user must visit.
      throw EegAccessDeniedException(
        '${warning['message']} ${warning['licenseUrl'] ?? ''}'.trim(),
      );
    }
    final token = result['cortexToken'] as String?;
    if (token == null || token.isEmpty) {
      throw const EegProtocolException('authorize devolvió sin cortexToken');
    }
    return token;
  }

  /// Returns the headset object once Cortex reports it `connected`.
  Future<Map<String, dynamic>> _ensureHeadsetConnected(String id) async {
    var headset = await _queryHeadset(id);
    if (headset?['status'] == 'connected') return headset!;

    await _client.call('controlDevice', {'command': 'connect', 'headset': id});

    final deadline = DateTime.now().add(config.headsetConnectTimeout);
    final failure = _client
        .nextWarning(
          (w) =>
              (w.headsetId == null || w.headsetId == id) &&
              (w.code == CortexWarning.headsetConnectFailed ||
                  w.code == CortexWarning.headsetConnectFailedAlt ||
                  w.code == CortexWarning.headsetConnectTimeout),
          timeout: config.headsetConnectTimeout,
        )
        .then<CortexWarning?>((w) => w, onError: (_) => null);

    // Poll rather than wait for warning 104 alone: on some Cortex builds
    // the warning precedes our listener, and the status is authoritative.
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 800));
      headset = await _queryHeadset(id);
      if (headset?['status'] == 'connected') return headset!;
      final failed = await failure.timeout(Duration.zero, onTimeout: () => null);
      if (failed != null) {
        throw EegException('Cortex no pudo conectar $id: ${failed.text}');
      }
    }
    throw EegTimeoutException('El headset $id no llegó a "connected"');
  }

  Future<Map<String, dynamic>?> _queryHeadset(String id) async {
    final list = await _client.callList('queryHeadsets', {'id': id});
    for (final h in list) {
      if (h is Map<String, dynamic> && h['id'] == id) return h;
    }
    return null;
  }

  Future<String> _createSession(String headsetId) async {
    Map<String, dynamic> result;
    try {
      result = await _client.call('createSession', {
        'cortexToken': _cortexToken,
        'headset': headsetId,
        'status': 'active',
      });
    } on EegProtocolException {
      // No session left on the license: an "open" session still serves the
      // free streams (met/dev/eq/mot); raw EEG will show up in `failure`.
      result = await _client.call('createSession', {
        'cortexToken': _cortexToken,
        'headset': headsetId,
        'status': 'open',
      });
    }
    final id = result['id'] as String?;
    if (id == null) {
      throw const EegProtocolException('createSession devolvió sin id');
    }
    return id;
  }

  Future<void> _subscribe() async {
    final result = await _client.call('subscribe', {
      'cortexToken': _cortexToken,
      'session': _sessionId,
      'streams': config.streams,
    });

    _client.subscriptions.clear();
    for (final s in (result['success'] as List?) ?? const []) {
      if (s is! Map) continue;
      final name = s['streamName'] as String?;
      final sid = s['sid'] as String?;
      final cols = s['cols'] as List?;
      if (name == null || sid == null || cols == null) continue;
      _client.subscriptions[name] =
          CortexSubscription(stream: name, sid: sid, cols: cols);
    }

    if (_client.subscriptions.isEmpty) {
      final failures = (result['failure'] as List?)
              ?.map((f) => f is Map ? '${f['streamName']}: ${f['message']}' : '$f')
              .join('; ') ??
          '';
      throw EegAccessDeniedException(
        'Cortex rechazó todas las suscripciones ($failures). '
        'Revisa la licencia de la app.',
      );
    }
  }

  Future<void> _teardownSession() async {
    await _samplesSub?.cancel();
    _samplesSub = null;
    // Cortex closes the record with the session; mirror that locally.
    if (_activeRecording != null) {
      _activeRecording = null;
      if (!_recordingChanges.isClosed) _recordingChanges.add(null);
    }

    if (_client.isOpen && _cortexToken != null && _sessionId != null) {
      try {
        await _client.call('updateSession', {
          'cortexToken': _cortexToken,
          'session': _sessionId,
          'status': 'close',
        });
      } catch (_) {
        // Session already gone; the close was the point.
      }
    }
    _sessionId = null;
    await _client.close();
  }

  // ── Inbound data ────────────────────────────────────────────────────

  void _listenLifecycle() {
    _warningsSub ??= _client.warnings.listen(_onWarning);
    _closedSub ??= _client.onClosed.listen((_) {
      if (connectionState == EegConnectionState.streaming ||
          connectionState == EegConnectionState.connecting) {
        _sessionId = null;
        setConnectionState(EegConnectionState.disconnected);
      }
    });
  }

  void _onWarning(CortexWarning w) {
    switch (w.code) {
      case CortexWarning.headsetDisconnected:
        if (w.headsetId == null || w.headsetId == connectedDevice?.id) {
          setConnectionState(EegConnectionState.error);
        }
      case CortexWarning.sessionClosed:
      case CortexWarning.streamsCancelled:
        if (connectionState == EegConnectionState.streaming) {
          _sessionId = null;
          setConnectionState(EegConnectionState.disconnected);
        }
    }
  }

  void _listenSamples() {
    _samplesSub?.cancel();
    _samplesSub = _client.samples.listen((sample) {
      final sub = _client.subscriptions[sample.stream];
      if (sub == null) return;

      switch (sample.stream) {
        case 'eeg':
          final s = CortexStreamParser.parseEeg(
            cols: sub.cols,
            values: sample.values,
            time: sample.time,
            quality: _status.contactQuality,
          );
          if (s != null) emitRaw(s);
        case 'pow':
          emitBandPower(CortexStreamParser.parsePow(
            cols: sub.cols,
            values: sample.values,
            time: sample.time,
          ));
        case 'met':
          final m = CortexStreamParser.parseMet(
            cols: sub.cols,
            values: sample.values,
            time: sample.time,
          );
          if (m != null) emitMentalState(m);
        case 'dev':
          _status = CortexStreamParser.parseDev(
            cols: sub.cols,
            values: sample.values,
            time: sample.time,
          ).copyWith(overallQuality: _status.overallQuality);
          emitStatus(_status);
        case 'eq':
          _status = CortexStreamParser.parseEq(
            cols: sub.cols,
            values: sample.values,
            time: sample.time,
            previous: _status,
          );
          emitStatus(_status);
        // `mot` is subscribed so the session keeps motion data for
        // records, but no consumer models it yet.
      }
    });
  }

  // ── Mapping ─────────────────────────────────────────────────────────

  EegDeviceInfo _deviceFromHeadset(
    Map<String, dynamic> h, {
    EegDeviceInfo? fallback,
  }) {
    final id = (h['id'] as String?) ?? fallback?.id ?? '';
    final settings = h['settings'] as Map<String, dynamic>? ?? const {};
    final type = EegDeviceType.fromCortexId((settings['mode'] as String?) ?? '') ??
        EegDeviceType.fromCortexId(id) ??
        fallback?.type ??
        EegDeviceType.emotivEpocX;

    final sensors = (h['sensors'] as List?)?.whereType<String>().toList();
    final channels = (sensors != null && sensors.isNotEmpty)
        ? EegChannelCatalog.fromLabels(sensors)
        : fallback?.channels ?? EegChannelCatalog.forType(type);

    final status = h['status'] as String?;
    return EegDeviceInfo(
      id: id,
      name: (h['customName'] as String?)?.trim().isNotEmpty == true
          ? h['customName'] as String
          : id,
      type: type,
      channels: channels,
      sampleRate: (settings['eegRate'] as num?)?.toInt() ?? type.sampleRate,
      battery: fallback?.battery ?? 0,
      signalQuality: status == 'connected' ? 1.0 : 0.5,
      firmwareVersion: h['firmware']?.toString(),
      transport: activeTransport,
      metadata: {
        'status': ?status,
        if (h['connectedBy'] != null) 'connectedBy': h['connectedBy'],
        if (h['dongle'] != null) 'dongle': h['dongle'],
        if (settings['mode'] != null) 'mode': settings['mode'],
        if (settings['memsRate'] != null) 'memsRate': settings['memsRate'],
        if (h['motionSensors'] != null) 'motionSensors': h['motionSensors'],
      },
    );
  }
}

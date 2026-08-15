import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../../domain/enums/eeg_connection_state.dart';
import '../../domain/models/eeg_band_power.dart';
import '../../domain/models/eeg_channel_info.dart';
import '../../domain/models/eeg_device_info.dart';
import '../../domain/models/eeg_mental_state.dart';
import '../../domain/models/eeg_sample.dart';
import '../../domain/enums/eeg_device_type.dart';
import '../../domain/use_cases/eeg_device_service.dart';

/// Implements [EegDeviceService] via Emotiv Cortex WebSocket API.
///
/// Connects to the local Cortex service at `wss://localhost:6868`
/// using JSON-RPC 2.0 protocol. Handles the full lifecycle:
/// authorize → createSession → subscribe to eeg/pow/met streams.
class EmotivCortexProvider implements EegDeviceService {
  final String clientId;
  final String clientSecret;

  WebSocketChannel? _channel;
  String? _cortexToken;
  String? _sessionId;
  int _requestId = 0;

  EegConnectionState _connectionState = EegConnectionState.disconnected;
  EegDeviceInfo? _connectedDevice;

  final _rawController = StreamController<EegSample>.broadcast();
  final _bandPowerController =
      StreamController<List<EegBandPower>>.broadcast();
  final _mentalStateController =
      StreamController<EegMentalState>.broadcast();
  final _completerMap = <int, Completer<Map<String, dynamic>>>{};

  EmotivCortexProvider({
    required this.clientId,
    required this.clientSecret,
  });

  @override
  EegConnectionState get connectionState => _connectionState;

  @override
  EegDeviceInfo? get connectedDevice => _connectedDevice;

  @override
  Stream<EegSample> get rawStream => _rawController.stream;

  @override
  Stream<List<EegBandPower>> get bandPowerStream =>
      _bandPowerController.stream;

  @override
  Stream<EegMentalState> get mentalStateStream =>
      _mentalStateController.stream;

  @override
  Future<List<EegDeviceInfo>> scan({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    _connectionState = EegConnectionState.scanning;
    await _ensureWebSocket();
    final result = await _sendRequest('queryHeadsets', {});
    _connectionState = EegConnectionState.disconnected;

    final headsets = result['result'] as List? ?? [];
    return headsets.map((h) {
      final map = h as Map<String, dynamic>;
      return EegDeviceInfo(
        id: map['id'] as String? ?? '',
        name: map['id'] as String? ?? 'Emotiv',
        type: _resolveDeviceType(map['id'] as String? ?? ''),
        channels: EegChannelInfo.emotivInsightChannels(),
        sampleRate: 128,
        battery: (map['battery'] as int?) ?? 0,
        signalQuality: 1.0,
        firmwareVersion: map['firmware'] as String?,
      );
    }).toList();
  }

  @override
  Future<void> connect(EegDeviceInfo device) async {
    _connectionState = EegConnectionState.connecting;
    _connectedDevice = device;

    await _ensureWebSocket();
    await _authorize();
    await _createSession(device.id);
    await _subscribe();

    _connectionState = EegConnectionState.streaming;
  }

  @override
  Future<void> disconnect() async {
    if (_sessionId != null && _cortexToken != null) {
      await _sendRequest('updateSession', {
        'cortexToken': _cortexToken,
        'session': _sessionId,
        'status': 'close',
      });
    }
    _channel?.sink.close();
    _channel = null;
    _cortexToken = null;
    _sessionId = null;
    _connectedDevice = null;
    _connectionState = EegConnectionState.disconnected;
  }

  // --- Private helpers ---

  Future<void> _ensureWebSocket() async {
    if (_channel != null) return;
    _channel = WebSocketChannel.connect(
      Uri.parse('wss://localhost:6868'),
    );
    _channel!.stream.listen(
      _handleMessage,
      onError: (_) {
        _connectionState = EegConnectionState.error;
      },
      onDone: () {
        _connectionState = EegConnectionState.disconnected;
      },
    );
  }

  Future<void> _authorize() async {
    final result = await _sendRequest('authorize', {
      'clientId': clientId,
      'clientSecret': clientSecret,
      'debit': 1,
    });
    _cortexToken =
        (result['result'] as Map<String, dynamic>?)?['cortexToken'] as String?;
  }

  Future<void> _createSession(String headsetId) async {
    final result = await _sendRequest('createSession', {
      'cortexToken': _cortexToken,
      'headset': headsetId,
      'status': 'active',
    });
    _sessionId =
        (result['result'] as Map<String, dynamic>?)?['id'] as String?;
  }

  Future<void> _subscribe() async {
    await _sendRequest('subscribe', {
      'cortexToken': _cortexToken,
      'session': _sessionId,
      'streams': ['eeg', 'pow', 'met'],
    });
  }

  Future<Map<String, dynamic>> _sendRequest(
    String method,
    Map<String, dynamic> params,
  ) async {
    final id = ++_requestId;
    final completer = Completer<Map<String, dynamic>>();
    _completerMap[id] = completer;

    final request = jsonEncode({
      'jsonrpc': '2.0',
      'method': method,
      'params': params,
      'id': id,
    });

    _channel?.sink.add(request);

    return completer.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () {
        _completerMap.remove(id);
        return <String, dynamic>{};
      },
    );
  }

  void _handleMessage(dynamic raw) {
    final data = jsonDecode(raw as String) as Map<String, dynamic>;

    // JSON-RPC response
    if (data.containsKey('id')) {
      final id = data['id'] as int;
      _completerMap.remove(id)?.complete(data);
      return;
    }

    // Stream data
    final streamName = data['sid'] as String? ?? '';

    if (streamName.contains('eeg')) {
      _parseRawEeg(data);
    } else if (streamName.contains('pow')) {
      _parseBandPower(data);
    } else if (streamName.contains('met')) {
      _parseMentalState(data);
    }
  }

  void _parseRawEeg(Map<String, dynamic> data) {
    final values = data['eeg'] as List? ?? [];
    if (values.isEmpty) return;

    final channels = <String, double>{};
    final channelNames = ['AF3', 'T7', 'Pz', 'T8', 'AF4'];
    for (var i = 0; i < channelNames.length && i < values.length; i++) {
      channels[channelNames[i]] = (values[i] as num).toDouble();
    }

    _rawController.add(EegSample(
      timestamp: DateTime.now(),
      channels: channels,
      quality: {},
    ));
  }

  void _parseBandPower(Map<String, dynamic> data) {
    final pow = data['pow'] as List? ?? [];
    if (pow.isEmpty) return;

    final now = DateTime.now();
    final channelNames = ['AF3', 'T7', 'Pz', 'T8', 'AF4'];
    final bandsPerChannel = 5;
    final bandPowers = <EegBandPower>[];

    for (var ch = 0; ch < channelNames.length; ch++) {
      final offset = ch * bandsPerChannel;
      if (offset + bandsPerChannel > pow.length) break;

      bandPowers.add(EegBandPower(
        channel: channelNames[ch],
        delta: (pow[offset] as num).toDouble(),
        theta: (pow[offset + 1] as num).toDouble(),
        alpha: (pow[offset + 2] as num).toDouble(),
        betaLow: (pow[offset + 3] as num).toDouble(),
        betaHigh: (pow[offset + 3] as num).toDouble() * 0.6,
        gamma: (pow[offset + 4] as num).toDouble(),
        timestamp: now,
      ));
    }

    _bandPowerController.add(bandPowers);
  }

  void _parseMentalState(Map<String, dynamic> data) {
    final met = data['met'] as List? ?? [];
    if (met.length < 5) return;

    _mentalStateController.add(EegMentalState(
      engagement: (met[0] as num).toDouble(),
      excitement: (met[1] as num).toDouble(),
      stress: (met[2] as num).toDouble(),
      relaxation: (met[3] as num).toDouble(),
      focus: (met[4] as num).toDouble(),
      timestamp: DateTime.now(),
    ));
  }

  EegDeviceType _resolveDeviceType(String headsetId) {
    final lower = headsetId.toLowerCase();
    if (lower.contains('insight')) return EegDeviceType.emotivInsight;
    if (lower.contains('mn8')) return EegDeviceType.emotivMn8;
    return EegDeviceType.emotivEpocX;
  }
}

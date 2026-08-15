import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../../domain/enums/eeg_connection_state.dart';
import '../../domain/enums/eeg_device_type.dart';
import '../../domain/models/eeg_band_power.dart';
import '../../domain/models/eeg_channel_info.dart';
import '../../domain/models/eeg_device_info.dart';
import '../../domain/models/eeg_mental_state.dart';
import '../../domain/models/eeg_sample.dart';
import '../../domain/use_cases/eeg_device_service.dart';

/// BLE provider for Muse and NeuroSky headsets.
///
/// Scans for devices by known service UUIDs (Muse) or name prefix
/// (NeuroSky MindWave). Parses raw BLE notifications into [EegSample].
class BleGenericEegProvider implements EegDeviceService {
  static const _museServiceUuid = '0000fe8d-0000-1000-8000-00805f9b34fb';
  static const _neuroSkyPrefix = 'MindWave';

  EegConnectionState _connectionState = EegConnectionState.disconnected;
  EegDeviceInfo? _connectedDevice;
  BluetoothDevice? _bleDevice;
  StreamSubscription<List<int>>? _notifySub;

  final _rawController = StreamController<EegSample>.broadcast();
  final _bandPowerController =
      StreamController<List<EegBandPower>>.broadcast();
  final _mentalStateController =
      StreamController<EegMentalState>.broadcast();

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

    final devices = <EegDeviceInfo>[];
    final completer = Completer<List<EegDeviceInfo>>();

    final sub = FlutterBluePlus.scanResults.listen((results) {
      for (final result in results) {
        final name = result.device.platformName;
        final serviceUuids =
            result.advertisementData.serviceUuids.map((e) => e.toString());

        EegDeviceType? deviceType;

        if (serviceUuids.contains(_museServiceUuid)) {
          deviceType = EegDeviceType.muse;
        } else if (name.startsWith(_neuroSkyPrefix)) {
          deviceType = EegDeviceType.neurosky;
        }

        if (deviceType != null) {
          final existing = devices.any(
            (d) => d.id == result.device.remoteId.toString(),
          );
          if (!existing) {
            devices.add(EegDeviceInfo(
              id: result.device.remoteId.toString(),
              name: name.isNotEmpty ? name : deviceType.displayName,
              type: deviceType,
              channels: _channelsForType(deviceType),
              sampleRate: deviceType.sampleRate,
              battery: 0,
              signalQuality: result.rssi > -70 ? 1.0 : 0.5,
            ));
          }
        }
      }
    });

    await FlutterBluePlus.startScan(timeout: timeout);
    await Future<void>.delayed(timeout);
    await sub.cancel();

    _connectionState = EegConnectionState.disconnected;

    if (!completer.isCompleted) {
      completer.complete(devices);
    }
    return devices;
  }

  @override
  Future<void> connect(EegDeviceInfo device) async {
    _connectionState = EegConnectionState.connecting;
    _connectedDevice = device;

    _bleDevice = BluetoothDevice.fromId(device.id);
    await _bleDevice!.connect(timeout: const Duration(seconds: 10));

    final services = await _bleDevice!.discoverServices();
    for (final service in services) {
      for (final char in service.characteristics) {
        if (char.properties.notify) {
          await char.setNotifyValue(true);
          _notifySub = char.lastValueStream.listen(_handleNotification);
          break;
        }
      }
    }

    _connectionState = EegConnectionState.streaming;
  }

  @override
  Future<void> disconnect() async {
    await _notifySub?.cancel();
    _notifySub = null;
    await _bleDevice?.disconnect();
    _bleDevice = null;
    _connectedDevice = null;
    _connectionState = EegConnectionState.disconnected;
  }

  // --- BLE notification parsing ---

  void _handleNotification(List<int> data) {
    if (data.isEmpty) return;

    final device = _connectedDevice;
    if (device == null) return;

    final channels = <String, double>{};
    final channelInfos = device.channels;

    // Parse raw bytes as 16-bit signed values (little-endian)
    for (var i = 0; i < channelInfos.length; i++) {
      final byteIndex = i * 2;
      if (byteIndex + 1 < data.length) {
        final raw = data[byteIndex] | (data[byteIndex + 1] << 8);
        final signed = raw > 32767 ? raw - 65536 : raw;
        // Convert to microvolts (approximate scaling)
        channels[channelInfos[i].name] = signed * 0.48828125;
      }
    }

    _rawController.add(EegSample(
      timestamp: DateTime.now(),
      channels: channels,
      quality: {for (final ch in channelInfos) ch.name: 1.0},
    ));
  }

  List<EegChannelInfo> _channelsForType(EegDeviceType type) {
    switch (type) {
      case EegDeviceType.muse:
        return const [
          EegChannelInfo(name: 'TP9', positionX: 0.15, positionY: 0.55),
          EegChannelInfo(name: 'AF7', positionX: 0.25, positionY: 0.2),
          EegChannelInfo(name: 'AF8', positionX: 0.75, positionY: 0.2),
          EegChannelInfo(name: 'TP10', positionX: 0.85, positionY: 0.55),
        ];
      case EegDeviceType.neurosky:
        return const [
          EegChannelInfo(name: 'FP1', positionX: 0.4, positionY: 0.15),
        ];
      default:
        return EegChannelInfo.emotivInsightChannels();
    }
  }
}

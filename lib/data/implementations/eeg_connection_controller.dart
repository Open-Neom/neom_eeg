import 'dart:async';

import 'package:sint/sint.dart';

import '../../domain/enums/eeg_connection_state.dart';
import '../../domain/models/eeg_device_info.dart';
import '../../domain/use_cases/eeg_device_service.dart';

/// SintController managing EEG device connection lifecycle.
///
/// Delegates to the active provider (emotiv/ble/simulated) and
/// exposes reactive state for UI binding. Includes auto-reconnect
/// logic (3 retries with 5 s delay).
class EegConnectionController extends SintController {
  final EegDeviceService provider;

  // --- Observable state ---
  final Rx<EegConnectionState> state =
      EegConnectionState.disconnected.obs;
  final Rxn<EegDeviceInfo> connectedDevice = Rxn<EegDeviceInfo>();
  final RxList<EegDeviceInfo> foundDevices = <EegDeviceInfo>[].obs;
  final RxBool isScanning = false.obs;

  int _reconnectAttempts = 0;
  static const _maxReconnectAttempts = 3;
  static const _reconnectDelay = Duration(seconds: 5);
  Timer? _reconnectTimer;

  EegConnectionController({required this.provider});

  @override
  void onInit() {
    super.onInit();
    // Sync state from provider periodically
    ever(state, (_) => update());
  }

  /// Scan for available devices.
  Future<void> scanDevices({Duration? timeout}) async {
    isScanning.value = true;
    state.value = EegConnectionState.scanning;
    update();

    try {
      final devices = await provider.scan(
        timeout: timeout ?? const Duration(seconds: 10),
      );
      foundDevices.assignAll(devices);
    } catch (e) {
      state.value = EegConnectionState.error;
    } finally {
      isScanning.value = false;
      state.value = provider.connectionState;
      update();
    }
  }

  /// Connect to a device.
  Future<void> connectDevice(EegDeviceInfo device) async {
    state.value = EegConnectionState.connecting;
    _reconnectAttempts = 0;
    update();

    try {
      await provider.connect(device);
      connectedDevice.value = device;
      state.value = EegConnectionState.streaming;
    } catch (e) {
      state.value = EegConnectionState.error;
      _scheduleReconnect(device);
    }
    update();
  }

  /// Disconnect from the current device.
  Future<void> disconnectDevice() async {
    _reconnectTimer?.cancel();
    _reconnectAttempts = 0;

    await provider.disconnect();
    connectedDevice.value = null;
    state.value = EegConnectionState.disconnected;
    update();
  }

  /// Whether data streams are active.
  bool get isStreaming => state.value == EegConnectionState.streaming;

  // --- Auto-reconnect ---

  void _scheduleReconnect(EegDeviceInfo device) {
    if (_reconnectAttempts >= _maxReconnectAttempts) return;

    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(_reconnectDelay, () async {
      _reconnectAttempts++;
      try {
        await provider.connect(device);
        connectedDevice.value = device;
        state.value = EegConnectionState.streaming;
        _reconnectAttempts = 0;
      } catch (_) {
        _scheduleReconnect(device);
      }
      update();
    });
  }

  @override
  void onClose() {
    _reconnectTimer?.cancel();
    provider.disconnect();
    super.onClose();
  }
}

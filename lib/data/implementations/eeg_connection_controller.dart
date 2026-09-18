import 'dart:async';

import 'package:sint/sint.dart';

import '../../domain/enums/eeg_connection_state.dart';
import '../../domain/enums/eeg_device_type.dart';
import '../../domain/enums/eeg_vendor.dart';
import '../../domain/models/eeg_device_info.dart';
import '../../domain/models/eeg_device_status.dart';
import '../../domain/use_cases/eeg_device_service.dart';
import '../hub/eeg_hub.dart';

/// SintController managing EEG device connection lifecycle.
///
/// Wraps any [EegDeviceService] — normally an [EegHub], so one controller
/// covers every vendor — and exposes reactive state for UI binding.
/// Includes auto-reconnect logic (3 retries with 5 s delay).
class EegConnectionController extends SintController {
  final EegDeviceService provider;

  // --- Observable state ---
  final Rx<EegConnectionState> state =
      EegConnectionState.disconnected.obs;
  final Rxn<EegDeviceInfo> connectedDevice = Rxn<EegDeviceInfo>();
  final RxList<EegDeviceInfo> foundDevices = <EegDeviceInfo>[].obs;
  final RxBool isScanning = false.obs;

  /// Latest battery / contact-quality report of the connected headset.
  final Rxn<EegDeviceStatus> status = Rxn<EegDeviceStatus>();

  /// Vendors the last scan could not query, with the reason (Emotiv
  /// without Launcher, pending drivers…). Empty for plain providers.
  final RxMap<EegVendor, String> skippedVendors = <EegVendor, String>{}.obs;

  /// Vendors whose scan failed, with the error text.
  final RxMap<EegVendor, String> failedVendors = <EegVendor, String>{}.obs;

  /// Message from the vendor SDK while it waits for the user (Cortex
  /// "approve this app in EMOTIV Launcher"). Null when nothing is pending.
  final RxnString pendingMessage = RxnString();

  /// Last connection error, user-readable. Null when none.
  final RxnString lastError = RxnString();

  int _reconnectAttempts = 0;
  static const _maxReconnectAttempts = 3;
  static const _reconnectDelay = Duration(seconds: 5);
  Timer? _reconnectTimer;
  StreamSubscription<EegDeviceStatus>? _statusSub;
  StreamSubscription<EegConnectionState>? _stateSub;

  EegConnectionController({required this.provider});

  /// The hub behind [provider], when it is one.
  EegHub? get hub => provider is EegHub ? provider as EegHub : null;

  @override
  void onInit() {
    super.onInit();
    ever(state, (_) => update());

    final h = hub;
    if (h != null) {
      _statusSub = h.statusStream.listen((s) => status.value = s);
      _stateSub = h.connectionStateStream.listen((s) {
        // Drops detected by the driver itself (headset off, Launcher
        // closed) reach the UI through here.
        if (s == EegConnectionState.disconnected ||
            s == EegConnectionState.error) {
          if (state.value == EegConnectionState.streaming) {
            state.value = s;
            final device = connectedDevice.value;
            connectedDevice.value = null;
            if (s == EegConnectionState.error && device != null) {
              _scheduleReconnect(device);
            }
          }
        }
      });
    }
  }

  /// Scan for available devices, across every vendor the hub can reach.
  Future<void> scanDevices({Duration? timeout, Set<EegVendor>? vendors}) async {
    isScanning.value = true;
    state.value = EegConnectionState.scanning;
    lastError.value = null;
    update();

    try {
      final h = hub;
      if (h != null) {
        final report = await h.scanDetailed(
          timeout: timeout ?? const Duration(seconds: 10),
          vendors: vendors,
        );
        foundDevices.assignAll(report.devices);
        skippedVendors.assignAll(report.skipped);
        failedVendors.assignAll(
          report.errors.map((v, e) => MapEntry(v, e.toString())),
        );
      } else {
        foundDevices.assignAll(await provider.scan(
          timeout: timeout ?? const Duration(seconds: 10),
        ));
      }
    } catch (e) {
      lastError.value = e.toString();
      state.value = EegConnectionState.error;
    } finally {
      isScanning.value = false;
      if (state.value != EegConnectionState.error) {
        state.value = provider.connectionState;
      }
      update();
    }
  }

  /// Connect to a device. The hub picks the driver from `device.type`.
  Future<void> connectDevice(EegDeviceInfo device) async {
    state.value = EegConnectionState.connecting;
    lastError.value = null;
    pendingMessage.value = null;
    _reconnectAttempts = 0;
    update();

    try {
      await provider.connect(device);
      connectedDevice.value = provider.connectedDevice ?? device;
      state.value = EegConnectionState.streaming;
    } catch (e) {
      lastError.value = e.toString();
      state.value = EegConnectionState.error;
      _scheduleReconnect(device);
    }
    pendingMessage.value = null;
    update();
  }

  /// Scan for one model and connect the first unit found — for flows
  /// where the app already knows which headset the user owns.
  Future<void> connectFirst(EegDeviceType type, {Duration? timeout}) async {
    final h = hub;
    if (h == null) {
      await scanDevices(timeout: timeout);
      final match = foundDevices.where((d) => d.type == type).firstOrNull;
      if (match != null) await connectDevice(match);
      return;
    }

    state.value = EegConnectionState.connecting;
    lastError.value = null;
    update();
    try {
      final device = await h.connectFirst(
        type,
        timeout: timeout ?? const Duration(seconds: 10),
      );
      connectedDevice.value = h.connectedDevice ?? device;
      state.value = EegConnectionState.streaming;
    } catch (e) {
      lastError.value = e.toString();
      state.value = EegConnectionState.error;
    }
    update();
  }

  /// Disconnect from the current device.
  Future<void> disconnectDevice() async {
    _reconnectTimer?.cancel();
    _reconnectAttempts = 0;

    await provider.disconnect();
    connectedDevice.value = null;
    status.value = null;
    state.value = EegConnectionState.disconnected;
    update();
  }

  /// Whether data streams are active.
  bool get isStreaming => state.value == EegConnectionState.streaming;

  /// Forwarded from the Emotiv driver so the picker can show "aprueba la
  /// app en EMOTIV Launcher" while the handshake waits.
  void reportPending(String message) => pendingMessage.value = message;

  // --- Auto-reconnect ---

  void _scheduleReconnect(EegDeviceInfo device) {
    if (_reconnectAttempts >= _maxReconnectAttempts) return;

    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(_reconnectDelay, () async {
      _reconnectAttempts++;
      try {
        await provider.connect(device);
        connectedDevice.value = provider.connectedDevice ?? device;
        state.value = EegConnectionState.streaming;
        lastError.value = null;
        _reconnectAttempts = 0;
      } catch (e) {
        lastError.value = e.toString();
        _scheduleReconnect(device);
      }
      update();
    });
  }

  @override
  void onClose() {
    _reconnectTimer?.cancel();
    _statusSub?.cancel();
    _stateSub?.cancel();
    provider.disconnect();
    super.onClose();
  }
}

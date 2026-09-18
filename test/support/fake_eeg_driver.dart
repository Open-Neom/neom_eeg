import 'package:neom_eeg/data/drivers/eeg_driver_base.dart';
import 'package:neom_eeg/domain/enums/eeg_connection_state.dart';
import 'package:neom_eeg/domain/enums/eeg_device_type.dart';
import 'package:neom_eeg/domain/enums/eeg_transport.dart';
import 'package:neom_eeg/domain/enums/eeg_vendor.dart';
import 'package:neom_eeg/domain/models/eeg_band_power.dart';
import 'package:neom_eeg/domain/models/eeg_capabilities.dart';
import 'package:neom_eeg/domain/models/eeg_channel_catalog.dart';
import 'package:neom_eeg/domain/models/eeg_device_info.dart';
import 'package:neom_eeg/domain/models/eeg_device_status.dart';
import 'package:neom_eeg/domain/models/eeg_mental_state.dart';
import 'package:neom_eeg/domain/models/eeg_sample.dart';

/// Scriptable driver for hub/registry tests: fixed vendor and models,
/// configurable capabilities and availability, public emitters.
class FakeEegDriver extends EegDriverBase {
  @override
  final EegVendor vendor;

  @override
  final Set<EegDeviceType> supportedTypes;

  EegCapabilities capabilities;
  bool available;
  String? reason;

  /// Devices returned by [scan].
  List<EegDeviceInfo> discoverable;

  /// Thrown by [scan] when set.
  Object? scanError;

  /// Thrown by [connect] when set.
  Object? connectError;

  int connectCalls = 0;
  int disconnectCalls = 0;
  int scanCalls = 0;
  bool disposed = false;

  FakeEegDriver({
    required this.vendor,
    Set<EegDeviceType>? types,
    this.capabilities = const EegCapabilities(
      nativeBandPower: true,
      nativeMentalMetrics: true,
      transports: {EegTransport.simulated},
    ),
    this.available = true,
    this.reason,
    List<EegDeviceInfo>? discoverable,
  })  : supportedTypes = types ?? EegDeviceType.ofVendor(vendor).toSet(),
        discoverable = discoverable ?? [] {
    if (this.discoverable.isEmpty) {
      this.discoverable = [device(supportedTypes.first)];
    }
  }

  static EegDeviceInfo device(EegDeviceType type, {String? id}) =>
      EegDeviceInfo(
        id: id ?? '${type.name}-1',
        name: type.displayName,
        type: type,
        channels: EegChannelCatalog.forType(type),
        sampleRate: type.sampleRate,
        battery: 80,
        signalQuality: 1.0,
      );

  @override
  EegCapabilities capabilitiesFor(EegDeviceType type) =>
      supports(type) ? capabilities : EegCapabilities.none;

  @override
  bool get isAvailable => available;

  @override
  String? get unavailableReason => available ? null : reason;

  @override
  Future<List<EegDeviceInfo>> scan({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    scanCalls++;
    if (scanError != null) throw scanError!;
    return discoverable;
  }

  @override
  Future<void> connect(EegDeviceInfo device) async {
    connectCalls++;
    setConnectionState(EegConnectionState.connecting);
    if (connectError != null) {
      setConnectionState(EegConnectionState.error);
      throw connectError!;
    }
    setConnectedDevice(device);
    setConnectionState(EegConnectionState.streaming);
  }

  @override
  Future<void> disconnect() async {
    disconnectCalls++;
    setConnectedDevice(null);
    setConnectionState(EegConnectionState.disconnected);
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await super.dispose();
  }

  // Public emitters for tests.
  void raw(EegSample s) => emitRaw(s);
  void bandPower(List<EegBandPower> p) => emitBandPower(p);
  void mental(EegMentalState m) => emitMentalState(m);
  void status(EegDeviceStatus s) => emitStatus(s);
  void drop(EegConnectionState state) {
    setConnectedDevice(null);
    setConnectionState(state);
  }
}

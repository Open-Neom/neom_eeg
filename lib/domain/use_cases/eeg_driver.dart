import '../enums/eeg_connection_state.dart';
import '../enums/eeg_device_type.dart';
import '../enums/eeg_vendor.dart';
import '../models/eeg_capabilities.dart';
import '../models/eeg_device_status.dart';
import 'eeg_device_service.dart';

/// A vendor backend the hub can route to.
///
/// Extends [EegDeviceService] (the streaming contract every consumer relies
/// on) with what the hub needs to pick a driver without the caller knowing
/// the vendor: which models it serves, what each model can deliver, whether
/// it can run on this platform, and the health telemetry that does not fit
/// the three data streams.
///
/// One driver instance serves one vendor and at most one connected headset.
abstract class EegDriver implements EegDeviceService {
  EegVendor get vendor;

  /// Models this driver can connect to.
  Set<EegDeviceType> get supportedTypes;

  /// What this driver delivers for [type]. Return [EegCapabilities.none] for
  /// models it does not support.
  EegCapabilities capabilitiesFor(EegDeviceType type);

  /// Whether the driver can operate on the current platform and setup
  /// (SDK present, companion service reachable, transport supported).
  ///
  /// Drivers should answer without doing I/O; the hub asks this before every
  /// scan and reports the reason instead of surfacing a raw error.
  bool get isAvailable;

  /// Why [isAvailable] is false, in user-readable form. Null when available.
  String? get unavailableReason;

  /// Connection lifecycle as a stream, so UIs can react to drops the driver
  /// detects on its own (headset switched off, service stopped).
  Stream<EegConnectionState> get connectionStateStream;

  /// Battery / link / contact quality of the connected headset.
  Stream<EegDeviceStatus> get statusStream;

  /// Most recent status, or null before the first report.
  EegDeviceStatus? get lastStatus;

  bool supports(EegDeviceType type) => supportedTypes.contains(type);

  /// Release sockets, BLE subscriptions and stream controllers. The driver
  /// cannot be used after this.
  Future<void> dispose();
}

import '../../domain/enums/eeg_device_type.dart';
import '../../domain/enums/eeg_transport.dart';
import '../../domain/enums/eeg_vendor.dart';
import '../../domain/models/eeg_capabilities.dart';
import '../../domain/models/eeg_channel_catalog.dart';
import '../../domain/models/eeg_device_info.dart';
import '../../domain/models/eeg_exceptions.dart';
import '../drivers/eeg_driver_base.dart';

/// Placeholder [EegDriver] for vendors whose transport is not implemented
/// yet. It never discovers anything and refuses to connect with a message
/// that says what is missing, so the registry stays complete (every
/// [EegVendor] resolves to a driver) and UIs can list the model as
/// "coming soon" instead of crashing.
///
/// Replacing one of these with a real driver is the whole job of adding a
/// vendor: nothing else in the hub or the consumers changes.
class EegPendingDriver extends EegDriverBase {
  @override
  final EegVendor vendor;

  /// What a real driver would need (SDK, transport, licence).
  final String note;

  final EegCapabilities _capabilities;

  EegPendingDriver({
    required this.vendor,
    required this.note,
    EegCapabilities capabilities = EegCapabilities.none,
  }) : _capabilities = capabilities;

  /// OpenBCI Cyton/Ganglion. Cyton is a USB serial dongle; Ganglion is BLE
  /// with 18/19-bit delta-compressed packets. Both are also reachable via
  /// the OpenBCI GUI's networking widget (UDP/LSL), which would be the
  /// simplest transport for a Flutter driver.
  factory EegPendingDriver.openbci() => EegPendingDriver(
        vendor: EegVendor.openbci,
        note: 'Cyton requiere puerto serie (dongle USB) y Ganglion el '
            'protocolo BLE comprimido; alternativa: relay UDP/LSL desde '
            'OpenBCI GUI.',
        capabilities: const EegCapabilities(
          battery: true,
          motion: true,
          transports: {EegTransport.serial, EegTransport.ble, EegTransport.network},
        ),
      );

  /// BrainBit / BrainBit Flex. BLE, but the packet format is only
  /// documented through Neurotech's proprietary `neurosdk2` (native libs
  /// for iOS/Android/desktop).
  factory EegPendingDriver.brainbit() => EegPendingDriver(
        vendor: EegVendor.brainbit,
        note: 'Requiere neurosdk2 (librería nativa de Neurotech) o '
            'ingeniería inversa del GATT.',
        capabilities: const EegCapabilities(
          contactQuality: true,
          battery: true,
          temporalCoverage: true,
          transports: {EegTransport.ble},
        ),
      );

  /// NeuroSky MindWave Mobile. Bluetooth Classic SPP (ThinkGear stream),
  /// not BLE, so flutter_blue_plus cannot reach it; needs a serial/RFCOMM
  /// plugin.
  factory EegPendingDriver.neurosky() => EegPendingDriver(
        vendor: EegVendor.neurosky,
        note: 'MindWave usa Bluetooth Classic (SPP/ThinkGear), fuera del '
            'alcance de BLE; requiere plugin RFCOMM.',
        capabilities: const EegCapabilities(
          nativeBandPower: true,
          nativeMentalMetrics: true,
          contactQuality: true,
          transports: {EegTransport.serial},
        ),
      );

  @override
  Set<EegDeviceType> get supportedTypes =>
      EegDeviceType.ofVendor(vendor).toSet();

  @override
  EegCapabilities capabilitiesFor(EegDeviceType type) => supports(type)
      ? _capabilities.copyWith(
          temporalCoverage: EegChannelCatalog.hasTemporalCoverage(
            EegChannelCatalog.labelsFor(type),
          ),
        )
      : EegCapabilities.none;

  @override
  bool get isAvailable => false;

  @override
  String? get unavailableReason =>
      'Driver ${vendor.displayName} pendiente: $note';

  @override
  Future<List<EegDeviceInfo>> scan({
    Duration timeout = const Duration(seconds: 10),
  }) async =>
      const [];

  @override
  Future<void> connect(EegDeviceInfo device) async {
    throw EegDriverUnavailableException(
      unavailableReason!,
      vendor: vendor,
      type: device.type,
    );
  }

  @override
  Future<void> disconnect() async {}
}

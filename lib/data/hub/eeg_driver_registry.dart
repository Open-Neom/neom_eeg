import '../../domain/enums/eeg_device_type.dart';
import '../../domain/enums/eeg_vendor.dart';
import '../../domain/models/eeg_capabilities.dart';
import '../../domain/use_cases/eeg_driver.dart';

/// Vendor → driver table the hub routes through.
///
/// One driver per vendor. Registering a vendor twice replaces the earlier
/// driver (and disposes it), which is how a host swaps the simulator for
/// real hardware without rebuilding the hub.
class EegDriverRegistry {
  final _drivers = <EegVendor, EegDriver>{};

  EegDriverRegistry([Iterable<EegDriver> drivers = const []]) {
    for (final d in drivers) {
      register(d);
    }
  }

  List<EegDriver> get drivers => List.unmodifiable(_drivers.values);

  List<EegVendor> get vendors => List.unmodifiable(_drivers.keys);

  /// Drivers that can run here and now.
  List<EegDriver> get available =>
      _drivers.values.where((d) => d.isAvailable).toList();

  void register(EegDriver driver) {
    final previous = _drivers[driver.vendor];
    if (identical(previous, driver)) return;
    _drivers[driver.vendor] = driver;
    previous?.dispose();
  }

  EegDriver? unregister(EegVendor vendor) => _drivers.remove(vendor);

  EegDriver? forVendor(EegVendor vendor) => _drivers[vendor];

  /// Driver that serves [type], regardless of availability.
  EegDriver? forType(EegDeviceType type) {
    final byVendor = _drivers[type.vendor];
    if (byVendor != null && byVendor.supports(type)) return byVendor;
    for (final d in _drivers.values) {
      if (d.supports(type)) return d;
    }
    return null;
  }

  EegCapabilities capabilitiesFor(EegDeviceType type) =>
      forType(type)?.capabilitiesFor(type) ?? EegCapabilities.none;

  /// Models a consumer can offer on this platform.
  List<EegDeviceType> get connectableTypes => [
        for (final t in EegDeviceType.values)
          if (forType(t)?.isAvailable == true) t,
      ];

  /// Why [type] cannot be connected here, or null when it can.
  String? unavailableReasonFor(EegDeviceType type) {
    final d = forType(type);
    if (d == null) return 'No hay driver registrado para ${type.vendor.displayName}';
    return d.isAvailable ? null : d.unavailableReason;
  }

  Future<void> dispose() async {
    final all = _drivers.values.toList();
    _drivers.clear();
    for (final d in all) {
      await d.dispose();
    }
  }
}

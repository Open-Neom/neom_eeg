import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../domain/enums/eeg_connection_state.dart';
import '../../domain/enums/eeg_device_type.dart';
import '../../domain/enums/eeg_vendor.dart';
import '../../domain/models/eeg_band_power.dart';
import '../../domain/models/eeg_capabilities.dart';
import '../../domain/models/eeg_device_info.dart';
import '../../domain/models/eeg_device_status.dart';
import '../../domain/models/eeg_exceptions.dart';
import '../../domain/models/eeg_mental_state.dart';
import '../../domain/models/eeg_sample.dart';
import '../../domain/models/emotiv_cortex_config.dart';
import '../../domain/use_cases/eeg_device_service.dart';
import '../../domain/use_cases/eeg_driver.dart';
import '../../domain/use_cases/eeg_processor_service.dart';
import '../../domain/use_cases/eeg_recording_service.dart';
import '../implementations/eeg_band_power_deriver.dart';
import '../implementations/eeg_metrics_estimator.dart';
import '../implementations/eeg_signal_processor.dart';
import '../implementations/local_eeg_recording_service.dart';
import '../providers/eeg_pending_driver.dart';
import '../providers/emotiv/cortex_transport.dart';
import '../providers/emotiv_cortex_provider.dart';
import '../providers/muse_ble_provider.dart';
import '../providers/simulated_eeg_provider.dart';
import 'eeg_driver_registry.dart';

/// Where band powers come from when the hub could either forward the
/// device's own or compute them from raw EEG.
enum EegBandPowerMode {
  /// Device-computed when the driver has them, derived otherwise.
  auto,

  /// Only device-computed; devices without them emit no band power.
  native,

  /// Always run the signal processor over the raw stream, even for
  /// devices with native powers (gives Emotiv a delta band, and one
  /// consistent algorithm across vendors for research comparisons).
  derived,
}

/// Outcome of an aggregated scan: what was found and which vendors were
/// skipped or failed, so a UI can say "Emotiv: abre EMOTIV Launcher"
/// instead of showing an empty list.
class EegScanReport {
  final List<EegDeviceInfo> devices;

  /// Vendors whose driver reported itself unavailable, with the reason.
  final Map<EegVendor, String> skipped;

  /// Vendors whose scan threw, with the error.
  final Map<EegVendor, Object> errors;

  const EegScanReport({
    required this.devices,
    this.skipped = const {},
    this.errors = const {},
  });

  static const empty = EegScanReport(devices: []);
}

/// The single entry point consumers use for any EEG headset.
///
/// Implements [EegDeviceService], so everything written against a single
/// provider (controllers, adapters, widgets) works unchanged; underneath,
/// it holds one [EegDriver] per vendor in an [EegDriverRegistry] and:
///
/// * `scan()` asks every available driver at once and merges the results;
/// * `connect(device)` routes to the driver for `device.type` — the caller
///   never names Emotiv, Muse or OpenBCI;
/// * the three data streams are always populated: when a driver lacks
///   native band powers or metrics ([EegCapabilities]), the hub derives
///   them with [EegBandPowerDeriver] / [EegMetricsEstimator].
///
/// ```dart
/// final hub = EegHub.standard(emotiv: EmotivCortexConfig.fromAppProperties());
/// final devices = await hub.scan();
/// await hub.connect(devices.first);   // Insight, EPOC X, Muse… same call
/// hub.bandPowerStream.listen(...);
/// ```
class EegHub implements EegDeviceService {
  final EegDriverRegistry registry;
  final EegBandPowerMode bandPowerMode;
  final EegProcessorService processor;

  /// Electrodes whose latest contact quality is below this are dropped from
  /// band-power frames (native or derived) so a sensor with no contact — a
  /// lost Insight tip, a lifted Muse pad — does not pollute the whole-head
  /// averages consumers compute. `0..1`; 0.25 is Cortex CQ 1 of 4, so only
  /// "no contact" (0) is removed by default. Set to 0 to disable. Raw
  /// samples are never filtered; their `quality` map carries the CQ instead.
  final double minContactQuality;
  final EegBandPowerDeriver _deriver;
  final EegMetricsEstimator _estimator;

  EegDriver? _active;
  EegConnectionState _ownState = EegConnectionState.disconnected;
  Set<String> _excluded = const {};
  LocalEegRecordingService? _localRecording;
  EegScanReport _lastScan = EegScanReport.empty;
  final _forwarders = <StreamSubscription<dynamic>>[];
  bool _disposed = false;

  final _raw = StreamController<EegSample>.broadcast();
  final _bandPower = StreamController<List<EegBandPower>>.broadcast();
  final _mental = StreamController<EegMentalState>.broadcast();
  final _status = StreamController<EegDeviceStatus>.broadcast();
  final _connection = StreamController<EegConnectionState>.broadcast();

  EegHub({
    required this.registry,
    this.bandPowerMode = EegBandPowerMode.auto,
    this.minContactQuality = 0.25,
    EegProcessorService? processor,
    Duration derivedWindow = const Duration(seconds: 1),
    Duration derivedHop = const Duration(milliseconds: 250),
    EegMetricsEstimator? estimator,
  })  : processor = processor ?? EegSignalProcessor(),
        _deriver = EegBandPowerDeriver(
          processor: processor ?? EegSignalProcessor(),
          window: derivedWindow,
          hop: derivedHop,
        ),
        _estimator = estimator ?? EegMetricsEstimator();

  /// Hub with the stock drivers.
  ///
  /// * Emotiv is registered when [emotiv] is configured (desktop/web via
  ///   EMOTIV Launcher, mobile via the embedded library if the host bridges
  ///   it — see [CortexNativeTransport]).
  /// * Muse over BLE.
  /// * Pending drivers for OpenBCI, BrainBit and NeuroSky so the catalog
  ///   is complete and their models explain what they need.
  /// * The simulator, on by default in debug builds only.
  factory EegHub.standard({
    EmotivCortexConfig? emotiv,
    CortexTransport? emotivTransport,
    void Function(String message)? onEmotivAccessPending,
    bool includeMuse = true,
    bool includePending = true,
    bool includeSimulated = kDebugMode,
    EegBandPowerMode bandPowerMode = EegBandPowerMode.auto,
    double minContactQuality = 0.25,
    EegProcessorService? processor,
  }) {
    final registry = EegDriverRegistry([
      if (emotiv != null)
        EmotivCortexProvider(
          config: emotiv,
          transport: emotivTransport,
          onAccessPending: onEmotivAccessPending,
        ),
      if (includeMuse) MuseBleProvider(),
      if (includePending) ...[
        EegPendingDriver.openbci(),
        EegPendingDriver.brainbit(),
        EegPendingDriver.neurosky(),
      ],
      if (includeSimulated) SimulatedEegProvider(),
    ]);
    return EegHub(
      registry: registry,
      bandPowerMode: bandPowerMode,
      minContactQuality: minContactQuality,
      processor: processor,
    );
  }

  // ── Introspection ───────────────────────────────────────────────────

  /// Driver currently connected (or connecting), if any.
  EegDriver? get activeDriver => _active;

  EegVendor? get activeVendor => _active?.vendor;

  EegScanReport get lastScan => _lastScan;

  /// Capabilities of the connected device as the hub exposes them — i.e.
  /// with band power and metrics marked available when the hub derives
  /// them.
  EegCapabilities? get effectiveCapabilities {
    final device = connectedDevice;
    final driver = _active;
    if (device == null || driver == null) return null;
    final native = driver.capabilitiesFor(device.type);
    return native.copyWith(
      nativeBandPower: native.nativeBandPower ||
          bandPowerMode != EegBandPowerMode.native,
      nativeMentalMetrics: true,
    );
  }

  /// Electrodes currently dropped from band-power frames because their
  /// contact quality is below [minContactQuality].
  List<String> get excludedChannels => _excluded.toList();

  /// Recording and markers for whatever is connected: the driver's own
  /// service when it has one (Emotiv → Cortex records, visible in
  /// EmotivPRO and embedded in EDF exports), otherwise the local Hive
  /// recorder fed by this hub's streams. Resolve it when you need it rather
  /// than caching it: it follows the active driver.
  EegRecordingService get recording {
    final driver = _active;
    if (driver is EegRecordingService) return driver as EegRecordingService;
    return _localRecording ??= LocalEegRecordingService(
      source: this,
      deviceTypeOf: () => connectedDevice?.type ?? EegDeviceType.simulated,
    );
  }

  /// Models a UI can offer here, with the reason for the ones it cannot.
  Map<EegDeviceType, String?> get catalog => {
        for (final t in EegDeviceType.values)
          t: registry.unavailableReasonFor(t),
      };

  // ── EegDeviceService ────────────────────────────────────────────────

  @override
  EegConnectionState get connectionState =>
      _active?.connectionState ?? _ownState;

  @override
  EegDeviceInfo? get connectedDevice => _active?.connectedDevice;

  @override
  Stream<EegSample> get rawStream => _raw.stream;

  @override
  Stream<List<EegBandPower>> get bandPowerStream => _bandPower.stream;

  @override
  Stream<EegMentalState> get mentalStateStream => _mental.stream;

  Stream<EegDeviceStatus> get statusStream => _status.stream;

  Stream<EegConnectionState> get connectionStateStream => _connection.stream;

  EegDeviceStatus? get lastStatus => _active?.lastStatus;

  /// Scans every available driver (or only [vendors]) in parallel and
  /// merges what they found. Per-vendor failures are recorded in
  /// [lastScan] rather than thrown, so one missing SDK never hides the
  /// headsets another vendor did find.
  @override
  Future<List<EegDeviceInfo>> scan({
    Duration timeout = const Duration(seconds: 10),
    Set<EegVendor>? vendors,
  }) async {
    final report = await scanDetailed(timeout: timeout, vendors: vendors);
    return report.devices;
  }

  Future<EegScanReport> scanDetailed({
    Duration timeout = const Duration(seconds: 10),
    Set<EegVendor>? vendors,
  }) async {
    _checkNotDisposed();
    final skipped = <EegVendor, String>{};
    final errors = <EegVendor, Object>{};
    final found = <EegDeviceInfo>[];

    final targets = registry.drivers
        .where((d) => vendors == null || vendors.contains(d.vendor))
        .toList();

    if (_active == null) _setOwnState(EegConnectionState.scanning);
    try {
      await Future.wait(targets.map((driver) async {
        if (!driver.isAvailable) {
          skipped[driver.vendor] = driver.unavailableReason ?? 'no disponible';
          return;
        }
        try {
          found.addAll(await driver.scan(timeout: timeout));
        } catch (e) {
          errors[driver.vendor] = e;
        }
      }));
    } finally {
      if (_active == null) _setOwnState(EegConnectionState.disconnected);
    }

    found.sort((a, b) {
      final v = a.vendor.index.compareTo(b.vendor.index);
      return v != 0 ? v : a.name.compareTo(b.name);
    });
    _lastScan = EegScanReport(devices: found, skipped: skipped, errors: errors);
    return _lastScan;
  }

  /// Connects [device] through the driver that serves its model. Any
  /// previously connected headset is disconnected first.
  @override
  Future<void> connect(EegDeviceInfo device) async {
    _checkNotDisposed();
    final driver = registry.forType(device.type);
    if (driver == null) {
      throw EegDriverUnavailableException(
        'No hay driver para ${device.type.displayName}',
        vendor: device.vendor,
        type: device.type,
      );
    }
    if (!driver.isAvailable) {
      throw EegDriverUnavailableException(
        driver.unavailableReason ?? '${driver.vendor.displayName} no disponible',
        vendor: driver.vendor,
        type: device.type,
      );
    }

    if (_active != null) await disconnect();

    _active = driver;
    _attach(driver, device);
    try {
      await driver.connect(device);
    } catch (_) {
      _detach();
      _active = null;
      _setOwnState(EegConnectionState.error);
      rethrow;
    }
  }

  /// Scan for [type] only and connect the first headset found.
  Future<EegDeviceInfo> connectFirst(
    EegDeviceType type, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final report = await scanDetailed(timeout: timeout, vendors: {type.vendor});
    final match = report.devices.where((d) => d.type == type).firstOrNull ??
        report.devices.firstOrNull;
    if (match == null) {
      final reason = report.skipped[type.vendor] ??
          report.errors[type.vendor]?.toString() ??
          'ningún ${type.displayName} encontrado';
      throw EegDriverUnavailableException(reason, vendor: type.vendor, type: type);
    }
    await connect(match);
    return match;
  }

  @override
  Future<void> disconnect() async {
    final driver = _active;
    _detach();
    _active = null;
    if (driver != null) await driver.disconnect();
    _setOwnState(EegConnectionState.disconnected);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    await disconnect();
    _disposed = true;
    await _localRecording?.dispose();
    await registry.dispose();
    await Future.wait([
      _raw.close(),
      _bandPower.close(),
      _mental.close(),
      _status.close(),
      _connection.close(),
    ]);
  }

  // ── Forwarding ──────────────────────────────────────────────────────

  void _attach(EegDriver driver, EegDeviceInfo device) {
    final caps = driver.capabilitiesFor(device.type);
    final deriveBandPower = switch (bandPowerMode) {
      EegBandPowerMode.native => false,
      EegBandPowerMode.derived => true,
      EegBandPowerMode.auto => !caps.nativeBandPower,
    };
    final estimateMetrics = !caps.nativeMentalMetrics;

    _deriver.reset();
    _estimator.reset();
    _excluded = const {};

    _forwarders.add(driver.rawStream.listen((sample) {
      _raw.add(sample);
      if (!deriveBandPower) return;
      final channels = driver.connectedDevice?.channels ?? device.channels;
      final rate = driver.connectedDevice?.sampleRate ?? device.sampleRate;
      final frame = _deriver.push(sample, channels, rate);
      if (frame != null) _publishBandPower(frame, estimateMetrics);
    }));

    if (!deriveBandPower) {
      _forwarders.add(driver.bandPowerStream.listen(
        (frame) => _publishBandPower(frame, estimateMetrics),
      ));
    }

    if (!estimateMetrics) {
      _forwarders.add(driver.mentalStateStream.listen(_mental.add));
    }

    _forwarders.add(driver.statusStream.listen((status) {
      _excluded = minContactQuality <= 0
          ? const {}
          : status.poorContacts(threshold: minContactQuality).toSet();
      _status.add(status);
    }));
    _forwarders.add(driver.connectionStateStream.listen((state) {
      _connection.add(state);
      // A driver that drops on its own (headset off, service closed) is no
      // longer the active one; the hub goes back to idle.
      if (identical(_active, driver) &&
          (state == EegConnectionState.disconnected ||
              state == EegConnectionState.error)) {
        _detach();
        _active = null;
        _ownState = state;
      }
    }));
  }

  void _publishBandPower(List<EegBandPower> frame, bool estimateMetrics) {
    var published = frame;
    if (_excluded.isNotEmpty) {
      final kept = frame.where((b) => !_excluded.contains(b.channel)).toList();
      // Never publish an empty frame: with every electrode off the head the
      // unfiltered data is still more useful than silence.
      if (kept.isNotEmpty) published = kept;
    }
    _bandPower.add(published);
    if (estimateMetrics) {
      final m = _estimator.estimate(published);
      if (m != null) _mental.add(m);
    }
  }

  void _detach() {
    for (final s in _forwarders) {
      s.cancel();
    }
    _forwarders.clear();
  }

  void _setOwnState(EegConnectionState state) {
    _ownState = state;
    if (!_disposed) _connection.add(state);
  }

  void _checkNotDisposed() {
    if (_disposed) throw const EegException('EegHub has been disposed');
  }
}

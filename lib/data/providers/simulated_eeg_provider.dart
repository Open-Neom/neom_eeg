import 'dart:async';
import 'dart:math';

import '../../domain/enums/eeg_connection_state.dart';
import '../../domain/enums/eeg_device_type.dart';
import '../../domain/enums/eeg_transport.dart';
import '../../domain/enums/eeg_vendor.dart';
import '../../domain/models/eeg_band_power.dart';
import '../../domain/models/eeg_capabilities.dart';
import '../../domain/models/eeg_channel_catalog.dart';
import '../../domain/models/eeg_device_info.dart';
import '../../domain/models/eeg_device_status.dart';
import '../../domain/models/eeg_mental_state.dart';
import '../../domain/models/eeg_sample.dart';
import '../drivers/eeg_driver_base.dart';

/// Mock EEG driver for testing and development.
///
/// Generates realistic alpha rhythm (10 Hz base + noise) with periodic
/// eye blink artifacts on frontal channels (~every 5 s). Runs at a
/// simulated 128 Hz sample rate (emits batches of 16 samples per timer).
///
/// Advertises native band power and metrics so the hub streams what the
/// simulator produces instead of re-deriving it; pass
/// `nativeAnalytics: false` to exercise the hub's derivation path.
class SimulatedEegProvider extends EegDriverBase {
  final double baseAlpha;
  final double baseTheta;
  final double baseBeta;
  final bool nativeAnalytics;

  Timer? _sampleTimer;
  Timer? _blinkTimer;
  int _sampleIndex = 0;
  bool _blinkActive = false;
  final _random = Random();

  static const _channelNames = ['AF3', 'T7', 'Pz', 'T8', 'AF4'];
  static const _sampleRate = 128;
  static const _batchSize = 16;

  SimulatedEegProvider({
    this.baseAlpha = 12.0,
    this.baseTheta = 6.0,
    this.baseBeta = 4.0,
    this.nativeAnalytics = true,
  });

  @override
  EegVendor get vendor => EegVendor.simulated;

  @override
  Set<EegDeviceType> get supportedTypes => const {EegDeviceType.simulated};

  @override
  EegCapabilities capabilitiesFor(EegDeviceType type) => supports(type)
      ? EegCapabilities(
          nativeBandPower: nativeAnalytics,
          nativeMentalMetrics: nativeAnalytics,
          contactQuality: true,
          battery: true,
          temporalCoverage: true,
          transports: const {EegTransport.simulated},
        )
      : EegCapabilities.none;

  @override
  Future<List<EegDeviceInfo>> scan({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final previous = connectionState;
    setConnectionState(EegConnectionState.scanning);
    await Future<void>.delayed(const Duration(seconds: 1));
    setConnectionState(
      previous == EegConnectionState.streaming ? previous : EegConnectionState.disconnected,
    );

    return [
      EegDeviceInfo(
        id: 'sim_001',
        name: 'Simulated EEG',
        type: EegDeviceType.simulated,
        channels: EegChannelCatalog.forType(EegDeviceType.simulated),
        sampleRate: _sampleRate,
        battery: 100,
        signalQuality: 1.0,
        firmwareVersion: '1.0.0-sim',
        transport: EegTransport.simulated,
      ),
    ];
  }

  @override
  Future<void> connect(EegDeviceInfo device) async {
    // Cancel any existing timers to prevent leaks on double-connect.
    _sampleTimer?.cancel();
    _blinkTimer?.cancel();

    setConnectionState(EegConnectionState.connecting);
    setConnectedDevice(device);
    await Future<void>.delayed(const Duration(milliseconds: 500));

    setConnectionState(EegConnectionState.streaming);
    _sampleIndex = 0;

    emitStatus(EegDeviceStatus(
      battery: 1.0,
      wirelessSignal: 1.0,
      contactQuality: {for (final ch in _channelNames) ch: 1.0},
      overallQuality: 1.0,
      timestamp: DateTime.now(),
    ));

    // Emit batches at ~125ms intervals (16 samples at 128Hz)
    _sampleTimer = Timer.periodic(
      const Duration(milliseconds: 125),
      (_) => _emitBatch(),
    );

    // Periodic blink artifact every ~5 seconds
    _blinkTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _triggerBlink(),
    );
  }

  @override
  Future<void> disconnect() async {
    _sampleTimer?.cancel();
    _blinkTimer?.cancel();
    _sampleTimer = null;
    _blinkTimer = null;
    setConnectedDevice(null);
    setConnectionState(EegConnectionState.disconnected);
  }

  @override
  Future<void> dispose() async {
    await disconnect();
    await super.dispose();
  }

  // --- Signal generation ---

  void _emitBatch() {
    final now = DateTime.now();

    for (var i = 0; i < _batchSize; i++) {
      final t = _sampleIndex / _sampleRate;
      final channels = <String, double>{};

      for (final ch in _channelNames) {
        double value = _generateSignal(t, ch);
        // Add blink artifact to frontal channels
        if (_blinkActive && (ch == 'AF3' || ch == 'AF4')) {
          value += 150.0 + _random.nextDouble() * 50.0;
        }
        channels[ch] = value;
      }

      emitRaw(EegSample(
        timestamp: now.add(Duration(
          microseconds: (i * 1000000 / _sampleRate).round(),
        )),
        channels: channels,
        quality: {for (final ch in _channelNames) ch: 1.0},
      ));

      _sampleIndex++;
    }

    if (!nativeAnalytics) return;

    // Emit band power every batch
    _emitBandPower(now);

    // Emit mental state every ~4 batches (~500ms)
    if (_sampleIndex % (_batchSize * 4) == 0) {
      _emitMentalState(now);
    }
  }

  double _generateSignal(double t, String channel) {
    // 10 Hz alpha rhythm
    final alpha = baseAlpha * sin(2 * pi * 10 * t);
    // 6 Hz theta
    final theta = baseTheta * 0.5 * sin(2 * pi * 6 * t);
    // 20 Hz beta
    final beta = baseBeta * 0.3 * sin(2 * pi * 20 * t);
    // Random noise
    final noise = (_random.nextDouble() - 0.5) * 4.0;

    // Channel-specific variation
    final channelOffset = channel.hashCode % 5 * 0.1;
    return alpha + theta + beta + noise + channelOffset;
  }

  void _emitBandPower(DateTime now) {
    final powers = _channelNames.map((ch) {
      final jitter = _random.nextDouble() * 0.2;
      return EegBandPower(
        channel: ch,
        delta: 2.0 + _random.nextDouble() * 1.5,
        theta: baseTheta * 0.8 + jitter,
        alpha: baseAlpha * (1.0 + jitter),
        betaLow: baseBeta * 0.6 + jitter,
        betaHigh: baseBeta * 0.4 + jitter,
        gamma: 1.0 + _random.nextDouble() * 0.5,
        timestamp: now,
      );
    }).toList();

    emitBandPower(powers);
  }

  void _emitMentalState(DateTime now) {
    emitMentalState(EegMentalState(
      engagement: 0.5 + _random.nextDouble() * 0.3,
      relaxation: 0.6 + _random.nextDouble() * 0.2,
      stress: 0.2 + _random.nextDouble() * 0.15,
      focus: 0.55 + _random.nextDouble() * 0.25,
      excitement: 0.3 + _random.nextDouble() * 0.2,
      timestamp: now,
    ));
  }

  void _triggerBlink() {
    _blinkActive = true;
    Future.delayed(const Duration(milliseconds: 200), () {
      _blinkActive = false;
    });
  }
}

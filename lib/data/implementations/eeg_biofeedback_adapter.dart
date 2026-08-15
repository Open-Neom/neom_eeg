import 'dart:async';

import 'package:neom_biofeedback/neom_biofeedback.dart';

import '../../domain/models/eeg_band_power.dart';
import '../../domain/use_cases/eeg_device_service.dart';

/// Bridges EEG band power data to the [BiofeedbackProvider] interface.
///
/// Listens to [EegDeviceService.bandPowerStream] and classifies
/// dominant band activity into [BiofeedbackEvent] types:
/// - alpha dominant → [BreathEvent] (proxy for relaxation)
/// - beta dominant → [MovementEvent] (proxy for analytical activity)
/// - delta spike → [SilenceEvent] (proxy for drowsiness)
class EegBiofeedbackAdapter implements BiofeedbackProvider {
  final EegDeviceService deviceService;

  bool _isActive = false;
  bool _isCalibrated = false;
  BiofeedbackCalibration? _calibration;
  StreamSubscription<List<EegBandPower>>? _bandPowerSub;

  final _eventController = StreamController<BiofeedbackEvent>.broadcast();

  // Baseline band powers recorded during calibration
  final _baselinePowers = <String, double>{};

  EegBiofeedbackAdapter({required this.deviceService});

  @override
  Stream<BiofeedbackEvent> get eventStream => _eventController.stream;

  @override
  bool get isActive => _isActive;

  @override
  bool get isCalibrated => _isCalibrated;

  @override
  BiofeedbackCalibration? get calibration => _calibration;

  @override
  Future<void> start() async {
    if (_isActive) return;
    _isActive = true;

    _bandPowerSub = deviceService.bandPowerStream.listen(_onBandPower);
  }

  @override
  Future<void> stop() async {
    _isActive = false;
    await _bandPowerSub?.cancel();
    _bandPowerSub = null;
  }

  @override
  Future<BiofeedbackCalibration> calibrate({
    Duration duration = const Duration(seconds: 10),
  }) async {
    final samples = <List<EegBandPower>>[];

    final sub = deviceService.bandPowerStream.listen((powers) {
      samples.add(powers);
    });

    await Future<void>.delayed(duration);
    await sub.cancel();

    // Average each band across all samples
    if (samples.isNotEmpty) {
      var totalDelta = 0.0;
      var totalTheta = 0.0;
      var totalAlpha = 0.0;
      var totalBeta = 0.0;
      var totalGamma = 0.0;
      var count = 0;

      for (final snapshot in samples) {
        for (final bp in snapshot) {
          totalDelta += bp.delta;
          totalTheta += bp.theta;
          totalAlpha += bp.alpha;
          totalBeta += bp.betaLow + bp.betaHigh;
          totalGamma += bp.gamma;
          count++;
        }
      }

      if (count > 0) {
        _baselinePowers['delta'] = totalDelta / count;
        _baselinePowers['theta'] = totalTheta / count;
        _baselinePowers['alpha'] = totalAlpha / count;
        _baselinePowers['beta'] = totalBeta / count;
        _baselinePowers['gamma'] = totalGamma / count;
      }
    }

    _calibration = BiofeedbackCalibration(
      noiseFloorDb: -60.0,
      gateThresholdDb: -56.0,
      calibratedAt: DateTime.now(),
    );
    _isCalibrated = true;

    return _calibration!;
  }

  // --- Classification ---

  void _onBandPower(List<EegBandPower> powers) {
    if (powers.isEmpty) return;

    // Average across channels
    var avgAlpha = 0.0;
    var avgBeta = 0.0;
    var avgDelta = 0.0;

    for (final bp in powers) {
      avgAlpha += bp.alpha;
      avgBeta += bp.betaLow + bp.betaHigh;
      avgDelta += bp.delta;
    }
    avgAlpha /= powers.length;
    avgBeta /= powers.length;
    avgDelta /= powers.length;

    final now = DateTime.now();

    // Classify dominant band
    if (avgAlpha > avgBeta && avgAlpha > avgDelta) {
      // Alpha dominant → relaxed state (mapped to BreathEvent)
      _eventController.add(BreathEvent(
        timestamp: now,
        cycleDurationMs: 4000.0,
        regularity: _normalizeToBaseline(avgAlpha, 'alpha'),
        amplitude: avgAlpha / (avgAlpha + avgBeta + avgDelta),
      ));
    } else if (avgBeta > avgAlpha && avgBeta > avgDelta) {
      // Beta dominant → focused/analytical (mapped to MovementEvent)
      _eventController.add(MovementEvent(
        timestamp: now,
        amplitude: avgBeta / (avgAlpha + avgBeta + avgDelta),
        attackMs: 50.0,
      ));
    } else if (avgDelta > avgAlpha * 1.5) {
      // Delta spike → drowsy (mapped to SilenceEvent)
      _eventController.add(SilenceEvent(
        timestamp: now,
        durationMs: 1000.0,
      ));
    }
  }

  double _normalizeToBaseline(double value, String band) {
    final baseline = _baselinePowers[band];
    if (baseline == null || baseline == 0) return 0.5;
    final ratio = value / baseline;
    return (ratio).clamp(0.0, 1.0);
  }
}

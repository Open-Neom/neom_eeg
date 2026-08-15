import 'dart:async';

import 'package:sint/sint.dart';

import '../../domain/models/eeg_band_power.dart';
import '../../domain/use_cases/eeg_device_service.dart';
import '../../domain/use_cases/eeg_neurofeedback_service.dart';

/// SintController for closed-loop neurofeedback.
///
/// Listens to [EegDeviceService.bandPowerStream], compares current
/// band power against a target, and emits a normalized feedback
/// signal (0.0-1.0). Exposes callbacks for neom_generator integration.
class EegNeurofeedbackController extends SintController
    implements EegNeurofeedbackService {
  final EegDeviceService deviceService;

  // --- Observable state ---
  final RxBool loopActive = false.obs;
  final RxDouble currentFeedback = 0.0.obs;
  final RxString targetBand = 'alpha'.obs;
  final RxDouble targetPowerValue = 10.0.obs;

  StreamSubscription<List<EegBandPower>>? _bandPowerSub;
  final _feedbackController = StreamController<double>.broadcast();

  // Baseline for normalization (set during first few seconds)
  double _baselinePower = 0.0;
  int _baselineSamples = 0;
  static const _baselineWindowSize = 8;

  // Callbacks for neom_generator
  void Function(double targetHz)? onTargetHzChanged;
  void Function(double intensity)? onIntensityChanged;

  EegNeurofeedbackController({required this.deviceService});

  @override
  bool get isLoopActive => loopActive.value;

  @override
  Stream<double> get feedbackStream => _feedbackController.stream;

  @override
  void startFeedbackLoop({
    required String targetBand,
    required double targetPower,
  }) {
    this.targetBand.value = targetBand;
    targetPowerValue.value = targetPower;
    loopActive.value = true;
    _baselinePower = 0.0;
    _baselineSamples = 0;
    update();

    _bandPowerSub?.cancel();
    _bandPowerSub = deviceService.bandPowerStream.listen(_onBandPower);
  }

  @override
  void stopFeedbackLoop() {
    loopActive.value = false;
    _bandPowerSub?.cancel();
    _bandPowerSub = null;
    update();
  }

  // --- Internal processing ---

  void _onBandPower(List<EegBandPower> powers) {
    if (powers.isEmpty || !loopActive.value) return;

    // Average target band across all channels
    double sum = 0.0;
    for (final bp in powers) {
      sum += _getBandValue(bp, targetBand.value);
    }
    final avgPower = sum / powers.length;

    // Build baseline from first N samples
    if (_baselineSamples < _baselineWindowSize) {
      _baselinePower =
          (_baselinePower * _baselineSamples + avgPower) /
              (_baselineSamples + 1);
      _baselineSamples++;
      return;
    }

    // Compute feedback: how close current power is to target
    final distance = (avgPower - targetPowerValue.value).abs();
    final maxDistance =
        (targetPowerValue.value - _baselinePower).abs().clamp(0.1, 100.0);
    final feedback = (1.0 - (distance / maxDistance)).clamp(0.0, 1.0);

    currentFeedback.value = feedback;
    _feedbackController.add(feedback);
    update();

    // Default neom_generator integration:
    // If alpha target and current alpha < baseline → output 10Hz + intensity
    if (targetBand.value == 'alpha') {
      onTargetHzChanged?.call(10.0);
      onIntensityChanged?.call(avgPower < _baselinePower ? 0.4 : 0.2);
    }
  }

  double _getBandValue(EegBandPower bp, String band) {
    switch (band) {
      case 'delta':
        return bp.delta;
      case 'theta':
        return bp.theta;
      case 'alpha':
        return bp.alpha;
      case 'betaLow':
        return bp.betaLow;
      case 'betaHigh':
        return bp.betaHigh;
      case 'gamma':
        return bp.gamma;
      default:
        return bp.alpha;
    }
  }

  @override
  void onClose() {
    _bandPowerSub?.cancel();
    _feedbackController.close();
    super.onClose();
  }
}

/// Abstract interface for the closed-loop neurofeedback bridge.
///
/// Monitors a target frequency band and computes a normalized
/// feedback signal (0-1) indicating how close the user is to
/// the desired brain state.
abstract class EegNeurofeedbackService {
  /// Start the feedback loop targeting a specific band and power level.
  void startFeedbackLoop({
    required String targetBand,
    required double targetPower,
  });

  /// Stop the active feedback loop.
  void stopFeedbackLoop();

  /// Whether a feedback loop is currently active.
  bool get isLoopActive;

  /// Stream of feedback values (0.0 = far from target, 1.0 = at target).
  Stream<double> get feedbackStream;
}

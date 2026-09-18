import '../../domain/models/eeg_band_power.dart';
import '../../domain/models/eeg_mental_state.dart';

/// Heuristic cognitive metrics from band-power ratios, for headsets whose
/// SDK does not provide them (Muse, OpenBCI, BrainBit…).
///
/// The ratios are the ones the neurofeedback literature uses most:
/// * engagement — `β / (α + θ)` (Pope et al., 1995)
/// * focus      — `β / θ`, the inverse of the ADHD "theta/beta ratio"
/// * relaxation — `α / (α + β)`
/// * stress     — `β_high / α`, frontal high-beta dominance
/// * excitement — share of `β_high + γ` in the total
///
/// Each ratio is squashed to `0..1` with `x / (x + k)` where `k` is the
/// value at which the metric reads 0.5, then smoothed with an exponential
/// moving average so a single noisy window does not flip the state.
///
/// These are *not* Emotiv's proprietary detections and are not clinically
/// validated; they exist so every device fills the same [EegMentalState]
/// and consumers do not branch on vendor.
class EegMetricsEstimator {
  /// Smoothing factor of the EMA (1 = no smoothing).
  final double smoothing;

  EegMentalState? _previous;

  EegMetricsEstimator({this.smoothing = 0.3});

  EegMentalState? get last => _previous;

  void reset() => _previous = null;

  /// Averages the bands across channels and maps the ratios to metrics.
  EegMentalState? estimate(List<EegBandPower> powers) {
    if (powers.isEmpty) return null;

    var theta = 0.0, alpha = 0.0, betaL = 0.0, betaH = 0.0, gamma = 0.0;
    for (final p in powers) {
      theta += p.theta;
      alpha += p.alpha;
      betaL += p.betaLow;
      betaH += p.betaHigh;
      gamma += p.gamma;
    }
    final n = powers.length.toDouble();
    theta /= n;
    alpha /= n;
    betaL /= n;
    betaH /= n;
    gamma /= n;
    final beta = betaL + betaH;
    final total = theta + alpha + beta + gamma;
    if (total <= 0) return null;

    final raw = EegMentalState(
      engagement: _squash(beta / _nz(alpha + theta), 0.8),
      focus: _squash(beta / _nz(theta), 1.5),
      relaxation: alpha / _nz(alpha + beta),
      stress: _squash(betaH / _nz(alpha), 0.6),
      excitement: (betaH + gamma) / total,
      timestamp: powers.first.timestamp,
    );

    final prev = _previous;
    final smoothed = prev == null
        ? raw
        : EegMentalState(
            engagement: _ema(prev.engagement, raw.engagement),
            focus: _ema(prev.focus, raw.focus),
            relaxation: _ema(prev.relaxation, raw.relaxation),
            stress: _ema(prev.stress, raw.stress),
            excitement: _ema(prev.excitement, raw.excitement),
            timestamp: raw.timestamp,
          );
    _previous = smoothed;
    return smoothed;
  }

  double _ema(double prev, double next) =>
      prev + smoothing * (next - prev);

  static double _squash(double x, double half) =>
      x.isFinite ? (x / (x + half)).clamp(0.0, 1.0) : 0.0;

  static double _nz(double v) => v <= 0 ? 1e-9 : v;
}

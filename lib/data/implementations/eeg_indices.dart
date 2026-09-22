import '../../domain/models/eeg_band_power.dart';
import '../../domain/models/eeg_calibration.dart';
import '../../domain/models/eeg_channel_catalog.dart';

/// Whole-head indices computed from one band-power frame, optionally
/// z-scored against a personal [EegCalibration]. Immutable; produced by
/// [EegIndices.compute] and consumed by the watcher, the dashboard and the
/// session report.
class EegLiveIndices {
  final DateTime at;

  /// Band the asymmetry and coherence were computed on.
  final String band;

  /// Left/right pair used, or null when the frame had none.
  final EegHemisphericPair? pair;

  /// `(left − right) / (left + right)` of [band] on [pair]; `-1..1`.
  final double? asymmetry;

  /// `1 − |asymmetry|`; `0..1`.
  final double? coherence;

  /// Share of each band in the whole-head total (`beta` is low + high).
  final Map<String, double> shares;

  /// Whole-head z-score per band against the calibration; empty without one.
  final Map<String, double> z;

  /// Frontal β ÷ (α + θ) — the engagement index of Pope et al. (1995)
  /// restricted to prefrontal/frontal electrodes. Higher = more analytic
  /// activity. Null when the frame has no frontal channel.
  final double? frontalActivation;

  /// [frontalActivation] z-scored against the resting value; null without
  /// calibration.
  final double? frontalActivationZ;

  /// How far frontal activation has dropped below the personal resting
  /// level: `(baseline − current) / baseline`, clamped to `0..1`. 0 = at
  /// baseline or above, 1 = frontal β gone. Null without calibration.
  final double? hypofrontality;

  /// Share of alpha over posterior electrodes; null when there are none.
  final double? posteriorAlphaShare;

  /// Electrodes the hub dropped for poor contact when this frame was built.
  final int excludedChannels;

  const EegLiveIndices({
    required this.at,
    this.band = 'alpha',
    this.pair,
    this.asymmetry,
    this.coherence,
    this.shares = const {},
    this.z = const {},
    this.frontalActivation,
    this.frontalActivationZ,
    this.hypofrontality,
    this.posteriorAlphaShare,
    this.excludedChannels = 0,
  });

  static final empty = EegLiveIndices(at: DateTime.fromMillisecondsSinceEpoch(0));

  bool get isEmpty => shares.isEmpty;

  bool get isCalibrated => z.isNotEmpty;
}

/// Pure functions over band-power frames. Everything the watcher alerts
/// on and the report scores is defined here, once, so a threshold means
/// the same thing on an Insight, a Muse or the simulator.
class EegIndices {
  EegIndices._();

  static const bands = ['delta', 'theta', 'alpha', 'beta', 'gamma'];

  /// Value of [band] in [b]; `beta` merges low and high.
  static double bandValue(EegBandPower b, String band) => switch (band) {
        'delta' => b.delta,
        'theta' => b.theta,
        'alpha' => b.alpha,
        'betaLow' => b.betaLow,
        'betaHigh' => b.betaHigh,
        'beta' => b.betaLow + b.betaHigh,
        'gamma' => b.gamma,
        _ => 0.0,
      };

  /// Whole-head mean of [band] over [frame].
  static double mean(Iterable<EegBandPower> frame, String band) {
    var sum = 0.0;
    var n = 0;
    for (final b in frame) {
      sum += bandValue(b, band);
      n++;
    }
    return n == 0 ? 0.0 : sum / n;
  }

  /// Share of each of [bands] in the total power of [frame].
  static Map<String, double> shares(Iterable<EegBandPower> frame) {
    final totals = {for (final b in bands) b: 0.0};
    for (final r in frame) {
      for (final b in bands) {
        totals[b] = totals[b]! + bandValue(r, b);
      }
    }
    final total = totals.values.fold(0.0, (a, b) => a + b);
    if (total <= 0) return const {};
    return totals.map((b, v) => MapEntry(b, v / total));
  }

  /// Asymmetry index of [band] on the best pair in [frame], with the pair.
  static ({EegHemisphericPair pair, double index})? asymmetry(
    Iterable<EegBandPower> frame, {
    String band = 'alpha',
  }) {
    final byChannel = {for (final b in frame) b.channel: b};
    final pair = EegChannelCatalog.bestPair(byChannel.keys);
    if (pair == null) return null;
    final l = bandValue(byChannel[pair.left]!, band);
    final r = bandValue(byChannel[pair.right]!, band);
    final sum = l + r;
    return (pair: pair, index: sum <= 0 ? 0.0 : (l - r) / sum);
  }

  /// Frontal β ÷ (α + θ); null when [frame] has no frontal electrode or
  /// the denominator is zero.
  static double? frontalActivation(Iterable<EegBandPower> frame) {
    var beta = 0.0, slow = 0.0;
    var any = false;
    for (final b in frame) {
      if (!EegChannelCatalog.isFrontal(b.channel)) continue;
      any = true;
      beta += b.betaLow + b.betaHigh;
      slow += b.alpha + b.theta;
    }
    if (!any || slow <= 0) return null;
    return beta / slow;
  }

  /// Alpha share over posterior electrodes; null when there are none.
  static double? posteriorAlphaShare(Iterable<EegBandPower> frame) {
    var alpha = 0.0, total = 0.0;
    for (final b in frame) {
      if (!EegChannelCatalog.isPosterior(b.channel)) continue;
      alpha += b.alpha;
      total += b.totalPower;
    }
    if (total <= 0) return null;
    return alpha / total;
  }

  /// Everything at once, z-scored when [calibration] is given.
  static EegLiveIndices compute(
    List<EegBandPower> frame, {
    EegCalibration? calibration,
    String band = 'alpha',
    int excludedChannels = 0,
    DateTime? at,
  }) {
    if (frame.isEmpty) return EegLiveIndices.empty;
    final asym = asymmetry(frame, band: band);
    final fa = frontalActivation(frame);

    final z = <String, double>{};
    double? faZ;
    double? hypo;
    if (calibration != null) {
      for (final b in bands) {
        final v = calibration.zScore(b, mean(frame, b));
        if (v != null) z[b] = v;
      }
      if (fa != null) {
        faZ = calibration.indexZ(EegCalibration.frontalActivationIndex, fa);
        final base = calibration.indexMeans[EegCalibration.frontalActivationIndex];
        if (base != null && base > 0) {
          hypo = ((base - fa) / base).clamp(0.0, 1.0);
        }
      }
    }

    return EegLiveIndices(
      at: at ?? DateTime.now(),
      band: band,
      pair: asym?.pair,
      asymmetry: asym?.index,
      coherence: asym == null ? null : (1.0 - asym.index.abs()).clamp(0.0, 1.0),
      shares: shares(frame),
      z: z,
      frontalActivation: fa,
      frontalActivationZ: faZ,
      hypofrontality: hypo,
      posteriorAlphaShare: posteriorAlphaShare(frame),
      excludedChannels: excludedChannels,
    );
  }
}

import '../../domain/models/eeg_band_power.dart';
import '../../domain/models/eeg_calibration.dart';
import '../../domain/models/eeg_channel_catalog.dart';
import 'eeg_coherence_tracker.dart';

/// Whole-head indices of one band-power frame, optionally z-scored against
/// a personal [EegCalibration]. Produced by [EegIndices.compute] and read by
/// the watcher, the dashboard and the session capture.
///
/// Two different hemispheric numbers, never confused:
/// * [symmetry] — `1 − |asymmetry|` of band **power**: do both sides carry
///   the same amount of the rhythm?
/// * [coherence] — spectral coherence (MSC) of the raw signals of the same
///   pair: do both sides oscillate **together**? Comes from the hub's
///   coherence tracker; null without raw EEG.
class EegLiveIndices {
  final DateTime at;

  /// Band the hemispheric numbers refer to ([EegIndices.hemisphericBand]).
  final String band;

  /// Left/right pair used, or null when the frame had none.
  final EegHemisphericPair? pair;

  /// `(left − right) / (left + right)` of [band] power on [pair]; `-1..1`.
  final double? asymmetry;

  /// `1 − |asymmetry|`; `0..1`.
  final double? symmetry;

  /// The hub's coherence reading for [pair], when it matches and is fresh.
  final EegPairCoherence? pairCoherence;

  /// Share of each band in the whole-head total (`beta` is low + high).
  final Map<String, double> shares;

  /// Whole-head z per band against the calibration, in σ of the whole-head
  /// quantity ([EegCalibration.headZ]); empty without a usable baseline.
  final Map<String, double> z;

  /// Frontal β ÷ (α + θ) — the engagement index of Pope et al. (1995)
  /// restricted to prefrontal/frontal electrodes. Null without one.
  final double? frontalActivation;

  /// [frontalActivation] z-scored against rest (log domain).
  final double? frontalActivationZ;

  /// How far frontal activation has dropped below the personal resting
  /// level: `1 − current / rest`, clamped to `0..1`.
  final double? hypofrontality;

  /// Share of alpha over posterior electrodes; null when there are none.
  final double? posteriorAlphaShare;

  /// Electrodes the hub dropped for poor contact when this frame was built.
  final int excludedChannels;

  const EegLiveIndices({
    required this.at,
    this.band = EegIndices.hemisphericBand,
    this.pair,
    this.asymmetry,
    this.symmetry,
    this.pairCoherence,
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

  /// Spectral coherence of [band] on [pair]; null without raw EEG.
  double? get coherence => pairCoherence?.of(band);

  /// Imaginary coherence of [band] (robust to the shared reference).
  double? get imaginaryCoherence => pairCoherence?.imaginary[band];

  bool get coherenceSignificant => pairCoherence?.isSignificant(band) ?? false;
}

/// Pure functions over band-power frames. Every threshold the watcher
/// applies and every number the report shows is defined here, once, so it
/// means the same thing on an Insight, a Muse or the simulator.
class EegIndices {
  EegIndices._();

  /// The band hemispheric symmetry and coherence are reported on across
  /// the module (dashboard, capture, neuro state, watcher defaults).
  static const hemisphericBand = 'alpha';

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

  /// Asymmetry index of [band] on [pair] (the best pair in [frame] when
  /// omitted), with the pair used. Null when the pair is not in the frame.
  static ({EegHemisphericPair pair, double index})? asymmetry(
    Iterable<EegBandPower> frame, {
    String band = hemisphericBand,
    EegHemisphericPair? pair,
  }) {
    final byChannel = {for (final b in frame) b.channel: b};
    final p = pair ?? EegChannelCatalog.bestPair(byChannel.keys);
    if (p == null) return null;
    final left = byChannel[p.left];
    final right = byChannel[p.right];
    if (left == null || right == null) return null;
    final l = bandValue(left, band);
    final r = bandValue(right, band);
    final sum = l + r;
    return (pair: p, index: sum <= 0 ? 0.0 : (l - r) / sum);
  }

  /// `1 − |asymmetry|` of [band]; same pair rules as [asymmetry].
  static double? symmetry(
    Iterable<EegBandPower> frame, {
    String band = hemisphericBand,
    EegHemisphericPair? pair,
  }) {
    final a = asymmetry(frame, band: band, pair: pair);
    return a == null ? null : (1.0 - a.index.abs()).clamp(0.0, 1.0);
  }

  /// Frontal β ÷ (α + θ); null without a frontal electrode or when the
  /// denominator is zero.
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

  /// Everything at once. [coherence] is the hub's latest reading; it is
  /// attached only when it belongs to the same pair as this frame.
  static EegLiveIndices compute(
    List<EegBandPower> frame, {
    EegCalibration? calibration,
    EegPairCoherence? coherence,
    String band = hemisphericBand,
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
        final v = calibration.headZ(b, frame);
        if (v != null) z[b] = v;
      }
      if (fa != null) {
        faZ = calibration.frontalActivationZ(fa);
        final rest = calibration.frontalActivationRest;
        if (rest != null && rest > 0 && calibration.supportsZ) {
          hypo = (1 - fa / rest).clamp(0.0, 1.0);
        }
      }
    }

    return EegLiveIndices(
      at: at ?? DateTime.now(),
      band: band,
      pair: asym?.pair,
      asymmetry: asym?.index,
      symmetry: asym == null ? null : (1.0 - asym.index.abs()).clamp(0.0, 1.0),
      pairCoherence: coherence != null && coherence.pair == asym?.pair ? coherence : null,
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

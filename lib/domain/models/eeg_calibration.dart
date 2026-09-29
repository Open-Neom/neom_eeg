import 'dart:math' as math;

import '../enums/eeg_device_type.dart';
import 'eeg_band_power.dart';
import 'eeg_channel_catalog.dart';

/// Personal resting baseline of one subject on one headset.
///
/// Produced by the calibration routine (eyes open, then eyes closed) and
/// consumed by everything that needs a *personal* threshold instead of a
/// fixed one: the watcher's band z-scores, the hypofrontality index, the
/// asymmetry rule.
///
/// **Statistics are in log₁₀ power.** Band power is heavy-tailed (a blink
/// multiplies frontal delta by ten), so a mean ± SD of raw power is
/// dominated by a few frames; in log space it is close to Gaussian and a
/// z-score means what it says.
///
/// **Whole-head z is in real σ.** [headZ] averages the per-channel z of the
/// electrodes present in both the live frame and the calibration, then
/// divides by [headDeviations] — the spread that same average showed at
/// rest. Channels are correlated (shared reference, volume conduction), so
/// neither "per-channel σ" nor "σ/√n" is right; measuring it is.
///
/// Tables are `band → channel → value`. `beta` (low + high) has its own
/// entries in the log tables. [baselines] / [deviations] keep the linear
/// means and SDs (band shares, alpha reactivity) plus a `raw` entry: the DC
/// level and noise of the raw signal per channel, for artifact detection.
class EegCalibration {
  /// Bump when the statistics change meaning; older baselines stay
  /// readable but [supportsZ] turns false until the user recalibrates.
  static const currentSchema = 2;

  static const bands = ['delta', 'theta', 'alpha', 'betaLow', 'betaHigh', 'gamma'];

  /// Bands with log statistics (the six plus merged `beta`).
  static const statBands = [...bands, 'beta'];
  static const rawKey = 'raw';

  /// Key of [indexMeans] / [indexDeviations]: frontal β/(α+θ), in log₁₀.
  static const frontalActivationIndex = 'frontalActivation';

  /// Prefix of the asymmetry indices (linear, `-1..1`), per band.
  static const asymmetryIndexPrefix = 'asymmetry:';

  /// Floor for log₁₀ of a power value (Emotiv reports no delta: 0).
  static const _logFloor = 1e-12;

  final int schemaVersion;
  final String id;

  /// Whoever the host says was wearing the headset; null for a device-only
  /// baseline.
  final String? subjectId;
  final EegDeviceType? deviceType;
  final List<String> channels;

  /// Linear `band → channel → mean` during eyes-open rest, plus [rawKey].
  final Map<String, Map<String, double>> baselines;

  /// Linear `band → channel → SD` during eyes-open rest, plus [rawKey].
  final Map<String, Map<String, double>> deviations;

  /// Linear `band → channel → mean` during eyes-closed rest; empty when the
  /// phase was skipped.
  final Map<String, Map<String, double>> eyesClosed;

  /// `band → channel → mean of log₁₀(power)` at rest (eyes open).
  final Map<String, Map<String, double>> logMeans;

  /// `band → channel → SD of log₁₀(power)` at rest (eyes open).
  final Map<String, Map<String, double>> logDeviations;

  /// `band →` SD of the channel-averaged z at rest — the σ of the
  /// whole-head quantity [headZ] reports.
  final Map<String, double> headDeviations;

  /// Whole-head indices at rest: [frontalActivationIndex] (log₁₀) and
  /// `asymmetry:<band>` for the best pair (linear).
  final Map<String, double> indexMeans;
  final Map<String, double> indexDeviations;

  /// Mean SD of the raw signal around its DC level (µV).
  final double noiseFloor;

  /// Raw excursion from the DC level considered an artifact (µV).
  final double artifactThreshold;
  final DateTime calibratedAt;
  final double eyesOpenSeconds;
  final double eyesClosedSeconds;

  /// Band-power frames the statistics were computed from (kept ones).
  final int frames;

  /// Frames discarded as artifacts (blinks, jaw, movement).
  final int rejectedFrames;

  const EegCalibration({
    this.schemaVersion = currentSchema,
    this.id = '',
    this.subjectId,
    this.deviceType,
    this.channels = const [],
    required this.baselines,
    this.deviations = const {},
    this.eyesClosed = const {},
    this.logMeans = const {},
    this.logDeviations = const {},
    this.headDeviations = const {},
    this.indexMeans = const {},
    this.indexDeviations = const {},
    required this.noiseFloor,
    required this.artifactThreshold,
    required this.calibratedAt,
    this.eyesOpenSeconds = 0,
    this.eyesClosedSeconds = 0,
    this.frames = 0,
    this.rejectedFrames = 0,
  });

  static double log10(double power) =>
      math.log(power < _logFloor ? _logFloor : power) / math.ln10;

  /// Storage key for one subject on one model.
  static String keyFor(String? subjectId, EegDeviceType? type) =>
      '${subjectId ?? 'local'}|${type?.name ?? 'any'}';

  String get key => keyFor(subjectId, deviceType);

  bool get isCurrentSchema => schemaVersion >= currentSchema;

  /// Whether z-scored rules can use this baseline. False for baselines of
  /// an older schema (they were computed on linear power) — recalibrate.
  bool get supportsZ => isCurrentSchema && logMeans.isNotEmpty && headDeviations.isNotEmpty;

  bool get hasEyesClosed => eyesClosed.isNotEmpty;

  bool get hasDeviations => deviations.values.any((m) => m.isNotEmpty);

  Duration get age => DateTime.now().difference(calibratedAt);

  /// Older than [maxAge]: resting rhythms drift with sleep, caffeine and
  /// medication, so a baseline should be refreshed regularly.
  bool isStale({Duration maxAge = const Duration(days: 30)}) => age > maxAge;

  /// Whether every one of [labels] has a baseline.
  bool covers(Iterable<String> labels) {
    final have = baselines['alpha']?.keys.map((c) => c.toUpperCase()).toSet() ?? const {};
    return labels.every((l) => have.contains(l.toUpperCase()));
  }

  double? baseline(String band, String channel) => _lookup(baselines, band, channel);

  double? deviation(String band, String channel) => _lookup(deviations, band, channel);

  /// Linear mean of [band] across [channels] (all calibrated by default).
  double? meanBaseline(String band, {Iterable<String>? channels}) {
    if (band == 'beta') {
      final lo = meanBaseline('betaLow', channels: channels);
      final hi = meanBaseline('betaHigh', channels: channels);
      return lo == null || hi == null ? null : lo + hi;
    }
    final row = baselines[band];
    if (row == null || row.isEmpty) return null;
    final picks = channels == null
        ? row.values.toList()
        : [for (final c in channels) ?_lookup(baselines, band, c)];
    if (picks.isEmpty) return null;
    return picks.fold(0.0, (a, b) => a + b) / picks.length;
  }

  /// z of one channel's [power] in [band] against its resting log power.
  double? channelZ(String band, String channel, double power) {
    if (!supportsZ) return null;
    final mean = _lookup(logMeans, band, channel);
    final sd = _lookup(logDeviations, band, channel);
    if (mean == null || sd == null || sd <= 1e-9) return null;
    return (log10(power) - mean) / sd;
  }

  /// Whole-head z of [band] for a live [frame], in σ of the whole-head
  /// quantity: mean per-channel z over the electrodes present in both the
  /// frame and the calibration, divided by [headDeviations]. Null when no
  /// electrode overlaps or the band was flat at rest (Emotiv delta).
  double? headZ(String band, Iterable<EegBandPower> frame) {
    if (!supportsZ) return null;
    final sd = headDeviations[band];
    if (sd == null || sd <= 1e-9) return null;
    var sum = 0.0;
    var n = 0;
    for (final b in frame) {
      final z = channelZ(band, b.channel, _bandOf(b, band));
      if (z == null) continue;
      sum += z;
      n++;
    }
    return n == 0 ? null : (sum / n) / sd;
  }

  /// Resting frontal activation β/(α+θ) as a ratio (geometric mean).
  double? get frontalActivationRest {
    final m = indexMeans[frontalActivationIndex];
    return m == null ? null : math.pow(10, m).toDouble();
  }

  /// z of a live frontal activation ratio against rest (log domain).
  double? frontalActivationZ(double ratio) {
    if (!supportsZ || ratio <= 0) return null;
    final mean = indexMeans[frontalActivationIndex];
    final sd = indexDeviations[frontalActivationIndex];
    if (mean == null || sd == null || sd <= 1e-9) return null;
    return (log10(ratio) - mean) / sd;
  }

  /// z of a linear index recorded in [indexMeans] (asymmetries).
  double? indexZ(String index, double value) {
    final mean = indexMeans[index];
    final sd = indexDeviations[index];
    if (mean == null || sd == null || sd <= 0) return null;
    return (value - mean) / sd;
  }

  /// Eyes-closed alpha ÷ eyes-open alpha over posterior electrodes (Pz, O1,
  /// O2…), or over every channel when the headset has none. Healthy resting
  /// alpha rises clearly with closed eyes (typically 1.5–3×); a value near 1
  /// means poor contact or no alpha reactivity.
  double? get alphaReactivity {
    if (!hasEyesClosed) return null;
    final open = baselines['alpha'];
    final closed = eyesClosed['alpha'];
    if (open == null || closed == null) return null;
    var picks = open.keys.where((c) => closed.containsKey(c) && EegChannelCatalog.isPosterior(c));
    if (picks.isEmpty) picks = open.keys.where(closed.containsKey);
    if (picks.isEmpty) return null;
    var o = 0.0, c = 0.0;
    for (final ch in picks) {
      o += open[ch]!;
      c += closed[ch]!;
    }
    return o <= 0 ? null : c / o;
  }

  /// Share of each band in the resting spectrum (sums to 1).
  Map<String, double> get bandShares {
    final means = {for (final b in bands) b: meanBaseline(b) ?? 0.0};
    final total = means.values.fold(0.0, (a, b) => a + b);
    if (total <= 0) return const {};
    return means.map((b, v) => MapEntry(b, v / total));
  }

  /// The resting spectrum as a band-power frame, one entry per channel.
  List<EegBandPower> get baselineFrame {
    final alpha = baselines['alpha'];
    if (alpha == null) return const [];
    return [
      for (final ch in alpha.keys)
        EegBandPower(
          channel: ch,
          delta: baseline('delta', ch) ?? 0,
          theta: baseline('theta', ch) ?? 0,
          alpha: alpha[ch]!,
          betaLow: baseline('betaLow', ch) ?? 0,
          betaHigh: baseline('betaHigh', ch) ?? 0,
          gamma: baseline('gamma', ch) ?? 0,
          timestamp: calibratedAt,
        ),
    ];
  }

  /// Resting asymmetry index of [band] between [left] and [right], so the
  /// watcher can flag *changes* from the subject's habitual balance.
  double? baselineAsymmetry(String band, String left, String right) {
    final l = _linearBand(band, left);
    final r = _linearBand(band, right);
    if (l == null || r == null) return null;
    final sum = l + r;
    return sum <= 0 ? 0.0 : (l - r) / sum;
  }

  double? _linearBand(String band, String channel) {
    if (band == 'beta') {
      final lo = baseline('betaLow', channel);
      final hi = baseline('betaHigh', channel);
      return lo == null || hi == null ? null : lo + hi;
    }
    return baseline(band, channel);
  }

  static double _bandOf(EegBandPower b, String band) => switch (band) {
        'delta' => b.delta,
        'theta' => b.theta,
        'alpha' => b.alpha,
        'betaLow' => b.betaLow,
        'betaHigh' => b.betaHigh,
        'beta' => b.betaLow + b.betaHigh,
        'gamma' => b.gamma,
        _ => 0.0,
      };

  static double? _lookup(Map<String, Map<String, double>> table, String band, String channel) {
    final row = table[band];
    if (row == null) return null;
    if (row.containsKey(channel)) return row[channel];
    final u = channel.toUpperCase();
    for (final e in row.entries) {
      if (e.key.toUpperCase() == u) return e.value;
    }
    return null;
  }

  EegCalibration copyWith({String? id, String? subjectId}) => EegCalibration(
        schemaVersion: schemaVersion,
        id: id ?? this.id,
        subjectId: subjectId ?? this.subjectId,
        deviceType: deviceType,
        channels: channels,
        baselines: baselines,
        deviations: deviations,
        eyesClosed: eyesClosed,
        logMeans: logMeans,
        logDeviations: logDeviations,
        headDeviations: headDeviations,
        indexMeans: indexMeans,
        indexDeviations: indexDeviations,
        noiseFloor: noiseFloor,
        artifactThreshold: artifactThreshold,
        calibratedAt: calibratedAt,
        eyesOpenSeconds: eyesOpenSeconds,
        eyesClosedSeconds: eyesClosedSeconds,
        frames: frames,
        rejectedFrames: rejectedFrames,
      );

  Map<String, dynamic> toJson() => {
        'schema': schemaVersion,
        'id': id,
        'subjectId': subjectId,
        'deviceType': deviceType?.name,
        'channels': channels,
        'baselines': baselines,
        'deviations': deviations,
        'eyesClosed': eyesClosed,
        'logMeans': logMeans,
        'logDeviations': logDeviations,
        'headDeviations': headDeviations,
        'indexMeans': indexMeans,
        'indexDeviations': indexDeviations,
        'noiseFloor': noiseFloor,
        'artifactThreshold': artifactThreshold,
        'calibratedAt': calibratedAt.toIso8601String(),
        'eyesOpenSeconds': eyesOpenSeconds,
        'eyesClosedSeconds': eyesClosedSeconds,
        'frames': frames,
        'rejectedFrames': rejectedFrames,
      };

  /// Reads every schema: the original one (baselines, noise floor,
  /// threshold, date), v1 (linear statistics, no `schema` key) and v2.
  factory EegCalibration.fromJson(Map<String, dynamic> json) => EegCalibration(
        schemaVersion: (json['schema'] as num?)?.toInt() ?? 1,
        id: json['id'] as String? ?? '',
        subjectId: json['subjectId'] as String?,
        deviceType: json['deviceType'] != null
            ? EegDeviceType.values.byName(json['deviceType'] as String)
            : null,
        channels: (json['channels'] as List?)?.cast<String>() ?? const [],
        baselines: _table(json['baselines']),
        deviations: _table(json['deviations']),
        eyesClosed: _table(json['eyesClosed']),
        logMeans: _table(json['logMeans']),
        logDeviations: _table(json['logDeviations']),
        headDeviations: _row(json['headDeviations']),
        indexMeans: _row(json['indexMeans']),
        indexDeviations: _row(json['indexDeviations']),
        noiseFloor: (json['noiseFloor'] as num).toDouble(),
        artifactThreshold: (json['artifactThreshold'] as num).toDouble(),
        calibratedAt: DateTime.parse(json['calibratedAt'] as String),
        eyesOpenSeconds: (json['eyesOpenSeconds'] as num?)?.toDouble() ?? 0,
        eyesClosedSeconds: (json['eyesClosedSeconds'] as num?)?.toDouble() ?? 0,
        frames: (json['frames'] as num?)?.toInt() ?? 0,
        rejectedFrames: (json['rejectedFrames'] as num?)?.toInt() ?? 0,
      );

  static Map<String, Map<String, double>> _table(Object? raw) => raw == null
      ? const {}
      : (raw as Map).map((band, channels) => MapEntry(band as String, _row(channels)));

  static Map<String, double> _row(Object? raw) => raw == null
      ? const {}
      : (raw as Map).map((k, v) => MapEntry(k as String, (v as num).toDouble()));
}

import 'dart:math' as math;

import '../enums/eeg_device_type.dart';
import 'eeg_band_power.dart';
import 'eeg_channel_catalog.dart';

/// Personal resting baseline of one subject on one headset.
///
/// Produced by the calibration routine (eyes open, then eyes closed) and
/// consumed by everything that needs a *personal* threshold instead of a
/// fixed one: the watcher's band z-scores, the hypofrontality index, the
/// entrainment score of a session. Band values are in the same units the
/// headset (or the hub's deriver) publishes, so a z-score compares like
/// with like.
///
/// `baselines` / `deviations` are `band → channel → value` over the
/// eyes-open phase. Besides the six bands they carry a `raw` entry: the
/// DC level and standard deviation of the raw signal per channel, which
/// artifact detection reads. `eyesClosed` holds the band means of the
/// eyes-closed phase when it ran; `alphaReactivity` compares the two.
class EegCalibration {
  static const bands = ['delta', 'theta', 'alpha', 'betaLow', 'betaHigh', 'gamma'];
  static const rawKey = 'raw';

  /// Keys of [indexMeans] / [indexDeviations].
  static const frontalActivationIndex = 'frontalActivation';
  static const asymmetryIndexPrefix = 'asymmetry:';

  final String id;

  /// Whoever the host says was wearing the headset; null for a device-only
  /// baseline.
  final String? subjectId;
  final EegDeviceType? deviceType;
  final List<String> channels;

  /// `band → channel → mean` during eyes-open rest, plus [rawKey].
  final Map<String, Map<String, double>> baselines;

  /// `band → channel → standard deviation` during eyes-open rest, plus [rawKey].
  final Map<String, Map<String, double>> deviations;

  /// `band → channel → mean` during eyes-closed rest; empty when the phase
  /// was skipped.
  final Map<String, Map<String, double>> eyesClosed;

  /// Whole-head indices at rest (eyes open): `frontalActivation`,
  /// `asymmetry:<band>` for the best pair… mean and standard deviation, so
  /// the watcher can z-score them too.
  final Map<String, double> indexMeans;
  final Map<String, double> indexDeviations;

  /// Mean standard deviation of the raw signal around its DC level (µV).
  final double noiseFloor;

  /// Raw excursion from the DC level considered an artifact (µV).
  final double artifactThreshold;
  final DateTime calibratedAt;
  final double eyesOpenSeconds;
  final double eyesClosedSeconds;

  /// Band-power frames the statistics were computed from.
  final int frames;

  const EegCalibration({
    this.id = '',
    this.subjectId,
    this.deviceType,
    this.channels = const [],
    required this.baselines,
    this.deviations = const {},
    this.eyesClosed = const {},
    this.indexMeans = const {},
    this.indexDeviations = const {},
    required this.noiseFloor,
    required this.artifactThreshold,
    required this.calibratedAt,
    this.eyesOpenSeconds = 0,
    this.eyesClosedSeconds = 0,
    this.frames = 0,
  });

  /// Storage key for one subject on one model.
  static String keyFor(String? subjectId, EegDeviceType? type) =>
      '${subjectId ?? 'local'}|${type?.name ?? 'any'}';

  String get key => keyFor(subjectId, deviceType);

  bool get hasEyesClosed => eyesClosed.isNotEmpty;

  bool get hasDeviations => deviations.values.any((m) => m.isNotEmpty);

  Duration get age => DateTime.now().difference(calibratedAt);

  /// Older than [maxAge]: resting rhythms drift with sleep, caffeine and
  /// medication, so a baseline should be refreshed regularly.
  bool isStale({Duration maxAge = const Duration(days: 30)}) => age > maxAge;

  /// Whether every one of [labels] has a baseline — i.e. this calibration
  /// was taken on a layout that includes the connected headset's channels.
  bool covers(Iterable<String> labels) {
    final have = baselines['alpha']?.keys.map((c) => c.toUpperCase()).toSet() ?? const {};
    return labels.every((l) => have.contains(l.toUpperCase()));
  }

  double? baseline(String band, String channel) => _lookup(baselines, band, channel);

  double? deviation(String band, String channel) => _lookup(deviations, band, channel);

  /// Mean of [band] across [channels] (all calibrated channels by default).
  double? meanBaseline(String band, {Iterable<String>? channels}) =>
      _meanOver(baselines, band, channels);

  /// Mean standard deviation of [band] across channels. It approximates the
  /// spread of the whole-head average the watcher tracks; per-channel
  /// values are available through [deviation].
  double? meanDeviation(String band, {Iterable<String>? channels}) =>
      _meanOver(deviations, band, channels, quadrature: true);

  /// How many standard deviations [value] sits from the resting mean of
  /// [band], whole-head or for one [channel]. Null without deviations or
  /// when the deviation is zero.
  double? zScore(String band, double value, {String? channel}) {
    final mean = channel == null ? meanBaseline(band) : baseline(band, channel);
    final sd = channel == null ? meanDeviation(band) : deviation(band, channel);
    if (mean == null || sd == null || sd <= 0) return null;
    return (value - mean) / sd;
  }

  /// z-score of a whole-head index recorded in [indexMeans].
  double? indexZ(String index, double value) {
    final mean = indexMeans[index];
    final sd = indexDeviations[index];
    if (mean == null || sd == null || sd <= 0) return null;
    return (value - mean) / sd;
  }

  /// Eyes-closed alpha ÷ eyes-open alpha over posterior electrodes (Pz, O1,
  /// O2…), or over every channel when the headset has none. Healthy
  /// resting alpha rises clearly with closed eyes (typically 1.5–3×); a
  /// value near 1 means either poor contact or no alpha reactivity, and
  /// the personal thresholds should be read with that in mind.
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

  /// The resting spectrum as a band-power frame, one entry per channel, so
  /// any index that takes a frame can be evaluated at baseline.
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

  /// Resting asymmetry index of [band] between [left] and [right], so a
  /// personal watcher can flag *changes* from the subject's habitual
  /// balance rather than any imbalance.
  double? baselineAsymmetry(String band, String left, String right) {
    final l = _bandBaseline(band, left);
    final r = _bandBaseline(band, right);
    if (l == null || r == null) return null;
    final sum = l + r;
    return sum <= 0 ? 0.0 : (l - r) / sum;
  }

  double? _bandBaseline(String band, String channel) {
    if (band == 'beta') {
      final lo = baseline('betaLow', channel);
      final hi = baseline('betaHigh', channel);
      return lo == null || hi == null ? null : lo + hi;
    }
    return baseline(band, channel);
  }

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

  static double? _meanOver(
    Map<String, Map<String, double>> table,
    String band,
    Iterable<String>? channels, {
    bool quadrature = false,
  }) {
    if (band == 'beta') {
      final lo = _meanOver(table, 'betaLow', channels, quadrature: quadrature);
      final hi = _meanOver(table, 'betaHigh', channels, quadrature: quadrature);
      if (lo == null || hi == null) return null;
      // Means add linearly; independent deviations add in quadrature.
      return quadrature ? math.sqrt(lo * lo + hi * hi) : lo + hi;
    }
    final row = table[band];
    if (row == null || row.isEmpty) return null;
    final picks = channels == null
        ? row.values.toList()
        : [for (final c in channels) if (_lookup(table, band, c) != null) _lookup(table, band, c)!];
    if (picks.isEmpty) return null;
    return picks.fold(0.0, (a, b) => a + b) / picks.length;
  }

  EegCalibration copyWith({String? id, String? subjectId}) => EegCalibration(
        id: id ?? this.id,
        subjectId: subjectId ?? this.subjectId,
        deviceType: deviceType,
        channels: channels,
        baselines: baselines,
        deviations: deviations,
        eyesClosed: eyesClosed,
        indexMeans: indexMeans,
        indexDeviations: indexDeviations,
        noiseFloor: noiseFloor,
        artifactThreshold: artifactThreshold,
        calibratedAt: calibratedAt,
        eyesOpenSeconds: eyesOpenSeconds,
        eyesClosedSeconds: eyesClosedSeconds,
        frames: frames,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'subjectId': subjectId,
        'deviceType': deviceType?.name,
        'channels': channels,
        'baselines': baselines,
        'deviations': deviations,
        'eyesClosed': eyesClosed,
        'indexMeans': indexMeans,
        'indexDeviations': indexDeviations,
        'noiseFloor': noiseFloor,
        'artifactThreshold': artifactThreshold,
        'calibratedAt': calibratedAt.toIso8601String(),
        'eyesOpenSeconds': eyesOpenSeconds,
        'eyesClosedSeconds': eyesClosedSeconds,
        'frames': frames,
      };

  /// Reads the current schema and the original one (baselines, noise
  /// floor, threshold, date only).
  factory EegCalibration.fromJson(Map<String, dynamic> json) => EegCalibration(
        id: json['id'] as String? ?? '',
        subjectId: json['subjectId'] as String?,
        deviceType: json['deviceType'] != null
            ? EegDeviceType.values.byName(json['deviceType'] as String)
            : null,
        channels: (json['channels'] as List?)?.cast<String>() ?? const [],
        baselines: _table(json['baselines']),
        deviations: _table(json['deviations']),
        eyesClosed: _table(json['eyesClosed']),
        indexMeans: _row(json['indexMeans']),
        indexDeviations: _row(json['indexDeviations']),
        noiseFloor: (json['noiseFloor'] as num).toDouble(),
        artifactThreshold: (json['artifactThreshold'] as num).toDouble(),
        calibratedAt: DateTime.parse(json['calibratedAt'] as String),
        eyesOpenSeconds: (json['eyesOpenSeconds'] as num?)?.toDouble() ?? 0,
        eyesClosedSeconds: (json['eyesClosedSeconds'] as num?)?.toDouble() ?? 0,
        frames: (json['frames'] as num?)?.toInt() ?? 0,
      );

  static Map<String, Map<String, double>> _table(Object? raw) => raw == null
      ? const {}
      : (raw as Map).map((band, channels) => MapEntry(band as String, _row(channels)));

  static Map<String, double> _row(Object? raw) => raw == null
      ? const {}
      : (raw as Map).map((k, v) => MapEntry(k as String, (v as num).toDouble()));
}

/// What a watch rule measures. Every metric is a whole-head number the
/// hub can produce for any headset (see `EegIndices`).
enum EegWatchMetric {
  /// `|asymmetry index|` of [EegWatchRule.band] on the best left/right
  /// pair, `0..1`. With a calibration and `personal: true`, the distance
  /// from the subject's resting asymmetry instead.
  asymmetry,

  /// `1 − |asymmetry|` of band power, `0..1`.
  symmetry,

  /// Spectral coherence (MSC) of [EegWatchRule.band] between the two
  /// electrodes of the pair, `0..1`, from the hub's raw-signal tracker.
  /// Dormant for drivers without raw EEG.
  coherence,

  /// Whole-head z-score of [EegWatchRule.band] against the personal
  /// baseline (σ). Needs a calibration; the rule is dormant without one.
  bandZ,

  /// Share of [EegWatchRule.band] in total power, `0..1`. Works without
  /// calibration.
  bandShare,

  /// Frontal β ÷ (α + θ), raw ratio.
  frontalActivation,

  /// [frontalActivation] z-scored against rest (σ). Needs a calibration.
  frontalActivationZ,

  /// Electrodes currently excluded for poor contact.
  excludedChannels;

  bool get needsCalibration =>
      this == EegWatchMetric.bandZ || this == EegWatchMetric.frontalActivationZ;

  bool get usesBand =>
      this == EegWatchMetric.asymmetry ||
      this == EegWatchMetric.symmetry ||
      this == EegWatchMetric.coherence ||
      this == EegWatchMetric.bandZ ||
      this == EegWatchMetric.bandShare;

  /// Metrics computed on a left/right pair: when the pair changes (an
  /// electrode lost contact) the rule starts over instead of carrying an
  /// episode from one region into another.
  bool get dependsOnPair =>
      this == EegWatchMetric.asymmetry ||
      this == EegWatchMetric.symmetry ||
      this == EegWatchMetric.coherence;
}

enum EegAlertSeverity { info, warning, critical }

/// A condition on one metric that must hold for [sustain] before it fires.
///
/// Per-frame EEG indices are noisy (a band-power frame is ¼–⅛ s of signal),
/// so the condition is evaluated on the metric smoothed with an exponential
/// moving average of time constant [smoothing], and once holding it only
/// releases when the smoothed value falls back past [hysteresis] — a single
/// dip no longer restarts a 10 s count.
///
/// Rules are data: a host keeps its own list, persists it as JSON and
/// hands it to the watcher. The defaults below implement what the
/// Cyberneom protocol looks for during a session, with personal
/// thresholds wherever a calibration exists.
class EegWatchRule {
  final String id;

  /// Shown in alerts and used as the marker label.
  final String label;
  final EegWatchMetric metric;

  /// Band for metrics that take one (`alpha`, `theta`, `beta`, `gamma`,
  /// `delta`).
  final String band;
  final double threshold;

  /// Fire when the value is above [threshold] (true) or below (false).
  final bool above;

  /// How long the condition must hold continuously before firing.
  final Duration sustain;

  /// Time constant of the moving average the condition is evaluated on.
  /// Zero evaluates the raw per-frame value.
  final Duration smoothing;

  /// Margin the smoothed value must fall back past before an episode ends
  /// (in the metric's units: 0.05 of asymmetry, 0.5 σ…).
  final double hysteresis;

  /// Minimum gap between two alerts of this rule while the condition keeps
  /// holding (a long episode is re-marked every [cooldown]).
  final Duration cooldown;

  /// Pin a marker to the active recording when firing.
  final bool autoMarker;

  /// Marker value (Cortex wants a non-negative integer or a string).
  final int markerValue;
  final EegAlertSeverity severity;

  /// For [EegWatchMetric.asymmetry]: measure the change from the resting
  /// asymmetry of the calibration instead of the absolute imbalance.
  final bool personal;
  final bool enabled;

  const EegWatchRule({
    required this.id,
    required this.label,
    required this.metric,
    this.band = 'alpha',
    required this.threshold,
    this.above = true,
    this.sustain = const Duration(seconds: 10),
    this.smoothing = const Duration(seconds: 2),
    this.hysteresis = 0,
    this.cooldown = const Duration(seconds: 60),
    this.autoMarker = true,
    this.markerValue = 10,
    this.severity = EegAlertSeverity.warning,
    this.personal = true,
    this.enabled = true,
  });

  bool get needsCalibration => metric.needsCalibration;

  /// Whether [value] starts an episode.
  bool holds(double value) => above ? value > threshold : value < threshold;

  /// Whether an episode already under way continues at [value].
  bool continues(double value) =>
      above ? value > threshold - hysteresis : value < threshold + hysteresis;

  /// What the Cyberneom protocol watches during a session:
  ///
  /// 1. Sustained temporal asymmetry (the T7/T8 desynchronisation the
  ///    epilepsy notes describe): smoothed over 3 s, 10 s sustained,
  ///    personal when calibrated.
  /// 2. Beta 2σ over the resting level for 10 s — over-activation.
  /// 3. Alpha 1σ over rest for 20 s. Informative only: closing the eyes
  ///    produces it by itself, so it says "alpha is up", not "the audio is
  ///    entraining the brain" — for that see the capture's
  ///    frequency-following response.
  /// 4. Frontal activation 1σ under rest for 20 s — hypofrontality reached.
  /// 5. An electrode losing contact for 5 s, no marker.
  static const List<EegWatchRule> defaults = [
    EegWatchRule(
      id: 'asymmetry_sustained',
      label: 'Asimetría hemisférica',
      metric: EegWatchMetric.asymmetry,
      band: 'alpha',
      threshold: 0.2,
      hysteresis: 0.05,
      smoothing: Duration(seconds: 3),
      sustain: Duration(seconds: 10),
      markerValue: 11,
      severity: EegAlertSeverity.warning,
    ),
    EegWatchRule(
      id: 'beta_over_baseline',
      label: 'Beta sobre línea base',
      metric: EegWatchMetric.bandZ,
      band: 'beta',
      threshold: 2.0,
      hysteresis: 0.5,
      smoothing: Duration(seconds: 2),
      sustain: Duration(seconds: 10),
      markerValue: 12,
      severity: EegAlertSeverity.warning,
    ),
    EegWatchRule(
      id: 'alpha_over_rest',
      label: 'Alfa sobre reposo',
      metric: EegWatchMetric.bandZ,
      band: 'alpha',
      threshold: 1.0,
      hysteresis: 0.3,
      smoothing: Duration(seconds: 3),
      sustain: Duration(seconds: 20),
      cooldown: Duration(seconds: 120),
      markerValue: 13,
      severity: EegAlertSeverity.info,
    ),
    EegWatchRule(
      id: 'hypofrontality',
      label: 'Hipofrontalidad',
      metric: EegWatchMetric.frontalActivationZ,
      threshold: -1.0,
      above: false,
      hysteresis: 0.3,
      smoothing: Duration(seconds: 3),
      sustain: Duration(seconds: 20),
      cooldown: Duration(seconds: 120),
      markerValue: 14,
      severity: EegAlertSeverity.info,
    ),
    EegWatchRule(
      id: 'contact_lost',
      label: 'Electrodo sin contacto',
      metric: EegWatchMetric.excludedChannels,
      threshold: 0,
      smoothing: Duration.zero,
      sustain: Duration(seconds: 5),
      cooldown: Duration(seconds: 120),
      autoMarker: false,
      severity: EegAlertSeverity.info,
      personal: false,
    ),
  ];

  EegWatchRule copyWith({
    String? label,
    double? threshold,
    bool? above,
    Duration? sustain,
    Duration? smoothing,
    double? hysteresis,
    Duration? cooldown,
    bool? autoMarker,
    int? markerValue,
    EegAlertSeverity? severity,
    bool? personal,
    bool? enabled,
  }) =>
      EegWatchRule(
        id: id,
        label: label ?? this.label,
        metric: metric,
        band: band,
        threshold: threshold ?? this.threshold,
        above: above ?? this.above,
        sustain: sustain ?? this.sustain,
        smoothing: smoothing ?? this.smoothing,
        hysteresis: hysteresis ?? this.hysteresis,
        cooldown: cooldown ?? this.cooldown,
        autoMarker: autoMarker ?? this.autoMarker,
        markerValue: markerValue ?? this.markerValue,
        severity: severity ?? this.severity,
        personal: personal ?? this.personal,
        enabled: enabled ?? this.enabled,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'metric': metric.name,
        'band': band,
        'threshold': threshold,
        'above': above,
        'sustainMs': sustain.inMilliseconds,
        'smoothingMs': smoothing.inMilliseconds,
        'hysteresis': hysteresis,
        'cooldownMs': cooldown.inMilliseconds,
        'autoMarker': autoMarker,
        'markerValue': markerValue,
        'severity': severity.name,
        'personal': personal,
        'enabled': enabled,
      };

  factory EegWatchRule.fromJson(Map<String, dynamic> j) => EegWatchRule(
        id: j['id'] as String,
        label: j['label'] as String? ?? j['id'] as String,
        metric: EegWatchMetric.values.byName(j['metric'] as String),
        band: j['band'] as String? ?? 'alpha',
        threshold: (j['threshold'] as num).toDouble(),
        above: j['above'] as bool? ?? true,
        sustain: Duration(milliseconds: (j['sustainMs'] as num?)?.toInt() ?? 10000),
        smoothing: Duration(milliseconds: (j['smoothingMs'] as num?)?.toInt() ?? 2000),
        hysteresis: (j['hysteresis'] as num?)?.toDouble() ?? 0,
        cooldown: Duration(milliseconds: (j['cooldownMs'] as num?)?.toInt() ?? 60000),
        autoMarker: j['autoMarker'] as bool? ?? true,
        markerValue: (j['markerValue'] as num?)?.toInt() ?? 10,
        severity: EegAlertSeverity.values.byName(j['severity'] as String? ?? 'warning'),
        personal: j['personal'] as bool? ?? true,
        enabled: j['enabled'] as bool? ?? true,
      );
}

/// A rule that fired: the value that tripped it, how long it had been
/// holding, and whether a marker landed in the recording.
class EegAlert {
  final String id;
  final EegWatchRule rule;
  final double value;

  /// Effective threshold (after the personal offset, when any).
  final double threshold;
  final DateTime startedAt;
  final DateTime firedAt;
  final bool markerAdded;
  final String? recordingId;

  /// Left/right pair the value was measured on (`T7/T8`), for
  /// pair-dependent metrics.
  final String? pair;

  const EegAlert({
    required this.id,
    required this.rule,
    required this.value,
    required this.threshold,
    required this.startedAt,
    required this.firedAt,
    this.markerAdded = false,
    this.recordingId,
    this.pair,
  });

  Duration get sustained => firedAt.difference(startedAt);

  EegAlertSeverity get severity => rule.severity;

  String get label => rule.label;
}

import '../enums/eeg_device_type.dart';
import 'eeg_recording.dart';

/// Conventional keys a host puts in the context it samples for a capture,
/// so the report can render "frequencies used" without knowing the app.
/// Hosts add any other keys they like; they are stored verbatim.
class EegContextKeys {
  EegContextKeys._();

  /// Base / carrier frequency in Hz.
  static const baseHz = 'baseHz';

  /// Binaural beat in Hz (0 when none).
  static const beatHz = 'beatHz';

  /// Frequency actually sent to the output after octave shifts, Hz.
  static const effectiveHz = 'effectiveHz';

  /// Output volume 0..1.
  static const volume = 'volume';

  /// Target neuro state name the audio is steering towards.
  static const neuroState = 'neuroState';

  /// Isochronic pulse Hz (0 when off).
  static const isochronicHz = 'isochronicHz';

  /// Human-readable name of the preset / session being practised.
  static const preset = 'preset';
}

/// One second of aggregated EEG, averaged across the channels the hub kept
/// (electrodes without contact are excluded upstream).
class EegCaptureRow {
  /// Seconds since the capture started.
  final double t;
  final double delta;
  final double theta;
  final double alpha;
  final double betaLow;
  final double betaHigh;
  final double gamma;

  /// Hemispheric coherence (`1 − |asymmetry|` of the dominant band on the
  /// device's best left/right pair); null when the device has no pair.
  final double? coherence;

  /// Cognitive metrics as of this second (native or estimated); null until
  /// the first one arrives.
  final double? focus;
  final double? relaxation;
  final double? engagement;
  final double? excitement;
  final double? stress;

  /// Raw samples received in this second — the real-time proof.
  final int samples;

  /// Band-power frames received in this second.
  final int frames;

  const EegCaptureRow({
    required this.t,
    required this.delta,
    required this.theta,
    required this.alpha,
    required this.betaLow,
    required this.betaHigh,
    required this.gamma,
    this.coherence,
    this.focus,
    this.relaxation,
    this.engagement,
    this.excitement,
    this.stress,
    required this.samples,
    required this.frames,
  });

  double get beta => betaLow + betaHigh;

  double get total => delta + theta + alpha + betaLow + betaHigh + gamma;

  String get dominantBand {
    final bands = {
      'delta': delta,
      'theta': theta,
      'alpha': alpha,
      'beta': beta,
      'gamma': gamma,
    };
    return bands.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
  }

  EegCaptureRow shifted(double dt) => EegCaptureRow(
        t: t + dt,
        delta: delta,
        theta: theta,
        alpha: alpha,
        betaLow: betaLow,
        betaHigh: betaHigh,
        gamma: gamma,
        coherence: coherence,
        focus: focus,
        relaxation: relaxation,
        engagement: engagement,
        excitement: excitement,
        stress: stress,
        samples: samples,
        frames: frames,
      );

  /// Compact list form for storage: fixed positions, nulls kept.
  List<dynamic> toList() => [
        t, delta, theta, alpha, betaLow, betaHigh, gamma, coherence,
        focus, relaxation, engagement, excitement, stress, samples, frames,
      ];

  factory EegCaptureRow.fromList(List<dynamic> l) {
    double d(int i) => (l[i] as num).toDouble();
    double? n(int i) => l.length > i && l[i] != null ? (l[i] as num).toDouble() : null;
    return EegCaptureRow(
      t: d(0),
      delta: d(1),
      theta: d(2),
      alpha: d(3),
      betaLow: d(4),
      betaHigh: d(5),
      gamma: d(6),
      coherence: n(7),
      focus: n(8),
      relaxation: n(9),
      engagement: n(10),
      excitement: n(11),
      stress: n(12),
      samples: (l[13] as num).toInt(),
      frames: (l[14] as num).toInt(),
    );
  }
}

/// A snapshot of what the host was doing (audio parameters) at second [t].
class EegContextSample {
  final double t;
  final Map<String, dynamic> values;

  const EegContextSample({required this.t, required this.values});

  double? hz(String key) => (values[key] as num?)?.toDouble();

  Map<String, dynamic> toJson() => {'t': t, 'values': values};

  factory EegContextSample.fromJson(Map<String, dynamic> j) => EegContextSample(
        t: (j['t'] as num).toDouble(),
        values: Map<String, dynamic>.from((j['values'] as Map?) ?? {}),
      );
}

enum EegVoiceEventKind { detected, captureStarted, captureStopped }

/// Something the host's microphone pipeline reported: a detected vocal
/// frequency, or the start/stop of a voice capture.
class EegVoiceEvent {
  final double t;
  final EegVoiceEventKind kind;
  final double? frequencyHz;

  const EegVoiceEvent({required this.t, required this.kind, this.frequencyHz});

  Map<String, dynamic> toJson() => {
        't': t,
        'kind': kind.name,
        'frequencyHz': frequencyHz,
      };

  factory EegVoiceEvent.fromJson(Map<String, dynamic> j) => EegVoiceEvent(
        t: (j['t'] as num).toDouble(),
        kind: EegVoiceEventKind.values.byName(j['kind'] as String),
        frequencyHz: (j['frequencyHz'] as num?)?.toDouble(),
      );
}

/// Electrodes excluded (no contact) from second [t] on.
class EegContactChange {
  final double t;
  final List<String> excluded;

  const EegContactChange({required this.t, required this.excluded});

  Map<String, dynamic> toJson() => {'t': t, 'excluded': excluded};

  factory EegContactChange.fromJson(Map<String, dynamic> j) => EegContactChange(
        t: (j['t'] as num).toDouble(),
        excluded: (j['excluded'] as List).cast<String>(),
      );
}

/// A watch rule that fired at second [t] — kept in the capture even when
/// no recording was active to receive the marker.
class EegAlertNote {
  final double t;
  final String ruleId;
  final String label;
  final String severity;
  final double value;
  final double threshold;
  final double sustainedSeconds;
  final bool markerAdded;

  const EegAlertNote({
    required this.t,
    required this.ruleId,
    required this.label,
    required this.severity,
    required this.value,
    required this.threshold,
    required this.sustainedSeconds,
    this.markerAdded = false,
  });

  Map<String, dynamic> toJson() => {
        't': t,
        'ruleId': ruleId,
        'label': label,
        'severity': severity,
        'value': value,
        'threshold': threshold,
        'sustainedSeconds': sustainedSeconds,
        'markerAdded': markerAdded,
      };

  factory EegAlertNote.fromJson(Map<String, dynamic> j) => EegAlertNote(
        t: (j['t'] as num).toDouble(),
        ruleId: j['ruleId'] as String,
        label: j['label'] as String? ?? j['ruleId'] as String,
        severity: j['severity'] as String? ?? 'warning',
        value: (j['value'] as num?)?.toDouble() ?? 0,
        threshold: (j['threshold'] as num?)?.toDouble() ?? 0,
        sustainedSeconds: (j['sustainedSeconds'] as num?)?.toDouble() ?? 0,
        markerAdded: j['markerAdded'] as bool? ?? false,
      );
}

/// A pair of frequencies the host used, with how long.
class EegFrequencyUse {
  final double baseHz;
  final double beatHz;
  final double seconds;

  const EegFrequencyUse({
    required this.baseHz,
    required this.beatHz,
    required this.seconds,
  });
}

/// Everything captured around one session: the EEG the headset produced,
/// what the host was playing, what the microphone heard and what the user
/// marked. Persisted in Hive so a session can be understood afterwards.
class EegSessionCapture {
  final String id;

  /// Id of the host session this capture belongs to (the Cámara Neom
  /// practice id, a recording id…). Null for ad-hoc captures.
  final String? practiceSessionId;

  final EegDeviceType deviceType;
  final String deviceName;
  final List<String> channels;
  final int sampleRate;
  final DateTime startedAt;
  final DateTime endedAt;

  final List<EegCaptureRow> rows;
  final List<EegContextSample> context;
  final List<EegVoiceEvent> voice;
  final List<EegMarker> markers;
  final List<EegContactChange> contactChanges;
  final List<EegAlertNote> alerts;

  const EegSessionCapture({
    required this.id,
    this.practiceSessionId,
    required this.deviceType,
    required this.deviceName,
    required this.channels,
    required this.sampleRate,
    required this.startedAt,
    required this.endedAt,
    required this.rows,
    this.context = const [],
    this.voice = const [],
    this.markers = const [],
    this.contactChanges = const [],
    this.alerts = const [],
  });

  Duration get duration => endedAt.difference(startedAt);

  int get sampleCount => rows.fold(0, (s, r) => s + r.samples);

  int get frameCount => rows.fold(0, (s, r) => s + r.frames);

  /// Samples received ÷ samples the headset should have produced. Below
  /// ~0.9 the link was dropping packets (or the seconds without contact
  /// were many).
  double get coverage {
    final expected = duration.inMilliseconds / 1000.0 * sampleRate;
    if (expected <= 0) return 0.0;
    return (sampleCount / expected).clamp(0.0, 1.0);
  }

  /// Seconds that carried EEG samples.
  int get secondsWithSignal => rows.where((r) => r.samples > 0).length;

  Map<String, double> get avgBands {
    final withSignal = rows.where((r) => r.frames > 0).toList();
    if (withSignal.isEmpty) return const {};
    double avg(double Function(EegCaptureRow) f) =>
        withSignal.fold(0.0, (s, r) => s + f(r)) / withSignal.length;
    return {
      'delta': avg((r) => r.delta),
      'theta': avg((r) => r.theta),
      'alpha': avg((r) => r.alpha),
      'betaLow': avg((r) => r.betaLow),
      'betaHigh': avg((r) => r.betaHigh),
      'gamma': avg((r) => r.gamma),
    };
  }

  String? get dominantBand {
    final b = avgBands;
    if (b.isEmpty) return null;
    final merged = {
      'delta': b['delta']!,
      'theta': b['theta']!,
      'alpha': b['alpha']!,
      'beta': b['betaLow']! + b['betaHigh']!,
      'gamma': b['gamma']!,
    };
    return merged.entries.reduce((a, c) => a.value >= c.value ? a : c).key;
  }

  /// Seconds spent with each band dominant.
  Map<String, int> get dominantBandSeconds {
    final out = <String, int>{};
    for (final r in rows) {
      if (r.frames == 0) continue;
      out.update(r.dominantBand, (v) => v + 1, ifAbsent: () => 1);
    }
    return out;
  }

  List<double> get _coherences =>
      [for (final r in rows) if (r.coherence != null) r.coherence!];

  double? get avgCoherence {
    final c = _coherences;
    return c.isEmpty ? null : c.reduce((a, b) => a + b) / c.length;
  }

  double? get minCoherence =>
      _coherences.isEmpty ? null : _coherences.reduce((a, b) => a < b ? a : b);

  double? get maxCoherence =>
      _coherences.isEmpty ? null : _coherences.reduce((a, b) => a > b ? a : b);

  Map<String, double?> get avgMetrics {
    double? avg(double? Function(EegCaptureRow) f) {
      final v = [for (final r in rows) if (f(r) != null) f(r)!];
      return v.isEmpty ? null : v.reduce((a, b) => a + b) / v.length;
    }
    return {
      'focus': avg((r) => r.focus),
      'relaxation': avg((r) => r.relaxation),
      'engagement': avg((r) => r.engagement),
      'excitement': avg((r) => r.excitement),
      'stress': avg((r) => r.stress),
    };
  }

  /// Distinct (base, beat) pairs the host played, with seconds each,
  /// longest first. Derived from [EegContextKeys.baseHz] / [EegContextKeys.beatHz].
  List<EegFrequencyUse> get frequenciesUsed {
    if (context.isEmpty) return const [];
    final seconds = <String, double>{};
    final pairs = <String, (double, double)>{};
    for (var i = 0; i < context.length; i++) {
      final c = context[i];
      final base = c.hz(EegContextKeys.baseHz);
      if (base == null) continue;
      final beat = c.hz(EegContextKeys.beatHz) ?? 0.0;
      final key = '${base.toStringAsFixed(2)}|${beat.toStringAsFixed(2)}';
      final next = i + 1 < context.length
          ? context[i + 1].t
          : duration.inMilliseconds / 1000.0;
      final span = (next - c.t).clamp(0.0, double.infinity);
      seconds.update(key, (v) => v + span, ifAbsent: () => span);
      pairs[key] = (base, beat);
    }
    final out = [
      for (final e in seconds.entries)
        EegFrequencyUse(
          baseHz: pairs[e.key]!.$1,
          beatHz: pairs[e.key]!.$2,
          seconds: e.value,
        ),
    ]..sort((a, b) => b.seconds.compareTo(a.seconds));
    return out;
  }

  /// Vocal frequencies the microphone detected, in order.
  List<double> get detectedVoiceHz => [
        for (final v in voice)
          if (v.kind == EegVoiceEventKind.detected && v.frequencyHz != null)
            v.frequencyHz!,
      ];

  /// Share of [band] in the whole-head total at second [t]; null for a
  /// second without frames.
  double? bandShareAt(EegCaptureRow r, String band) {
    if (r.frames == 0 || r.total <= 0) return null;
    final v = switch (band) {
      'delta' => r.delta,
      'theta' => r.theta,
      'alpha' => r.alpha,
      'beta' => r.beta,
      'betaLow' => r.betaLow,
      'betaHigh' => r.betaHigh,
      'gamma' => r.gamma,
      _ => 0.0,
    };
    return v / r.total;
  }

  /// Did the session move the spectrum towards [band]? Mean share of the
  /// band over the last third of the session ÷ over the first third. 1.0 =
  /// unchanged; 1.3 = 30 % more of the spectrum in the target band at the
  /// end than at the start. Null when either third has no frames.
  double? entrainmentIndex(String band) {
    final withFrames = rows.where((r) => r.frames > 0).toList();
    if (withFrames.length < 6) return null;
    final third = withFrames.length ~/ 3;
    double? avg(Iterable<EegCaptureRow> part) {
      final v = [for (final r in part) if (bandShareAt(r, band) != null) bandShareAt(r, band)!];
      return v.isEmpty ? null : v.reduce((a, b) => a + b) / v.length;
    }
    final start = avg(withFrames.take(third));
    final end = avg(withFrames.skip(withFrames.length - third));
    if (start == null || end == null || start <= 0) return null;
    return end / start;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'practiceSessionId': practiceSessionId,
        'deviceType': deviceType.name,
        'deviceName': deviceName,
        'channels': channels,
        'sampleRate': sampleRate,
        'startedAt': startedAt.toIso8601String(),
        'endedAt': endedAt.toIso8601String(),
        'rows': rows.map((r) => r.toList()).toList(),
        'context': context.map((c) => c.toJson()).toList(),
        'voice': voice.map((v) => v.toJson()).toList(),
        'markers': markers.map((m) => m.toJson()).toList(),
        'contactChanges': contactChanges.map((c) => c.toJson()).toList(),
        'alerts': alerts.map((a) => a.toJson()).toList(),
      };

  factory EegSessionCapture.fromJson(Map<String, dynamic> j) => EegSessionCapture(
        id: j['id'] as String,
        practiceSessionId: j['practiceSessionId'] as String?,
        deviceType: EegDeviceType.values.byName(j['deviceType'] as String),
        deviceName: j['deviceName'] as String? ?? '',
        channels: (j['channels'] as List?)?.cast<String>() ?? const [],
        sampleRate: (j['sampleRate'] as num?)?.toInt() ?? 0,
        startedAt: DateTime.parse(j['startedAt'] as String),
        endedAt: DateTime.parse(j['endedAt'] as String),
        rows: [
          for (final r in (j['rows'] as List?) ?? const [])
            EegCaptureRow.fromList((r as List).cast<dynamic>()),
        ],
        context: [
          for (final c in (j['context'] as List?) ?? const [])
            EegContextSample.fromJson(Map<String, dynamic>.from(c as Map)),
        ],
        voice: [
          for (final v in (j['voice'] as List?) ?? const [])
            EegVoiceEvent.fromJson(Map<String, dynamic>.from(v as Map)),
        ],
        markers: [
          for (final m in (j['markers'] as List?) ?? const [])
            EegMarker.fromJson(Map<String, dynamic>.from(m as Map)),
        ],
        contactChanges: [
          for (final c in (j['contactChanges'] as List?) ?? const [])
            EegContactChange.fromJson(Map<String, dynamic>.from(c as Map)),
        ],
        alerts: [
          for (final a in (j['alerts'] as List?) ?? const [])
            EegAlertNote.fromJson(Map<String, dynamic>.from(a as Map)),
        ],
      );
}

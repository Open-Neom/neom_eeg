import 'dart:math' as math;

import '../../domain/enums/eeg_device_type.dart';
import '../../domain/models/eeg_band_power.dart';
import '../../domain/models/eeg_calibration.dart';
import '../../domain/models/eeg_sample.dart';
import 'eeg_indices.dart';

/// Phase of the calibration routine a frame belongs to.
enum EegCalibrationPhase {
  idle,

  /// Eyes open, gaze on a fixed point: the resting reference every
  /// personal threshold is measured against.
  eyesOpen,

  /// Eyes closed: only used to measure alpha reactivity.
  eyesClosed,
  done,
  cancelled,
}

/// Collects the band-power frames of each phase and the raw samples of the
/// eyes-open phase, then turns them into an [EegCalibration].
///
/// Frames are kept (a 90 s routine at 8 Hz is ~700 frames) because the
/// statistics need two passes:
///
/// 1. **Artifact rejection** — a frame is dropped when any electrode's log
///    total power is more than [rejectZ] robust σ (median/MAD) from that
///    electrode's median: blinks, jaw clenches, a touched sensor.
/// 2. **Statistics in log₁₀ power** per band and channel, then the spread of
///    the channel-averaged z across frames ([EegCalibration.headDeviations]),
///    so a whole-head z is in real σ.
class EegCalibrationBuilder {
  /// Robust z beyond which a frame counts as an artifact.
  final double rejectZ;

  EegCalibrationBuilder({this.rejectZ = 3.5});

  final _open = <List<EegBandPower>>[];
  final _closed = <List<EegBandPower>>[];
  final _raw = <String, _Welford>{};
  int _rawSamples = 0;

  int get eyesOpenFrames => _open.length;
  int get eyesClosedFrames => _closed.length;
  int get rawSamples => _rawSamples;

  /// Channels seen in the eyes-open phase, in first-seen order.
  List<String> get channels {
    final out = <String>[];
    for (final f in _open) {
      for (final b in f) {
        if (!out.contains(b.channel)) out.add(b.channel);
      }
    }
    return out;
  }

  void addFrame(EegCalibrationPhase phase, List<EegBandPower> frame) {
    if (frame.isEmpty) return;
    switch (phase) {
      case EegCalibrationPhase.eyesOpen:
        _open.add(List.of(frame));
      case EegCalibrationPhase.eyesClosed:
        _closed.add(List.of(frame));
      default:
        break;
    }
  }

  /// Raw samples feed the DC level and noise floor per channel (eyes open).
  void addRaw(EegCalibrationPhase phase, EegSample sample) {
    if (phase != EegCalibrationPhase.eyesOpen) return;
    _rawSamples++;
    for (final e in sample.channels.entries) {
      if (!e.value.isFinite) continue;
      _raw.putIfAbsent(e.key, _Welford.new).add(e.value);
    }
  }

  bool get hasData => _open.isNotEmpty;

  /// Frames of [frames] that are not artifacts.
  List<List<EegBandPower>> clean(List<List<EegBandPower>> frames) {
    if (frames.length < 5) return frames;
    // Per-channel median and MAD of log total power.
    final byChannel = <String, List<double>>{};
    for (final f in frames) {
      for (final b in f) {
        byChannel.putIfAbsent(b.channel, () => []).add(EegCalibration.log10(b.totalPower));
      }
    }
    final median = <String, double>{};
    final mad = <String, double>{};
    for (final e in byChannel.entries) {
      final m = _median(e.value);
      median[e.key] = m;
      mad[e.key] = _median([for (final v in e.value) (v - m).abs()]) * 1.4826;
    }
    return [
      for (final f in frames)
        if (!f.any((b) {
          final s = mad[b.channel] ?? 0;
          if (s <= 1e-9) return false;
          return (EegCalibration.log10(b.totalPower) - median[b.channel]!).abs() / s > rejectZ;
        }))
          f,
    ];
  }

  EegCalibration build({
    String? subjectId,
    EegDeviceType? deviceType,
    required double eyesOpenSeconds,
    required double eyesClosedSeconds,
    DateTime? at,
  }) {
    final now = at ?? DateTime.now();
    final open = clean(_open);
    final closed = clean(_closed);

    // Linear and log statistics per band and channel.
    final linMean = <String, Map<String, double>>{};
    final linSd = <String, Map<String, double>>{};
    final logMean = <String, Map<String, double>>{};
    final logSd = <String, Map<String, double>>{};
    for (final band in EegCalibration.statBands) {
      final lin = <String, _Welford>{};
      final lg = <String, _Welford>{};
      for (final f in open) {
        for (final b in f) {
          final v = EegIndices.bandValue(b, band);
          lin.putIfAbsent(b.channel, _Welford.new).add(v);
          lg.putIfAbsent(b.channel, _Welford.new).add(EegCalibration.log10(v));
        }
      }
      if (band != 'beta') {
        linMean[band] = {for (final e in lin.entries) e.key: e.value.mean};
        linSd[band] = {for (final e in lin.entries) e.key: e.value.sd};
      }
      logMean[band] = {for (final e in lg.entries) e.key: e.value.mean};
      logSd[band] = {for (final e in lg.entries) e.key: e.value.sd};
    }

    // Spread of the channel-averaged z at rest, per band.
    final headSd = <String, double>{};
    for (final band in EegCalibration.statBands) {
      final avgZ = _Welford();
      for (final f in open) {
        var sum = 0.0;
        var n = 0;
        for (final b in f) {
          final m = logMean[band]![b.channel];
          final s = logSd[band]![b.channel];
          if (m == null || s == null || s <= 1e-9) continue;
          sum += (EegCalibration.log10(EegIndices.bandValue(b, band)) - m) / s;
          n++;
        }
        if (n > 0) avgZ.add(sum / n);
      }
      if (avgZ.n >= 2) headSd[band] = avgZ.sd;
    }

    // Whole-head indices at rest.
    final indices = <String, _Welford>{};
    for (final f in open) {
      final fa = EegIndices.frontalActivation(f);
      if (fa != null && fa > 0) {
        indices
            .putIfAbsent(EegCalibration.frontalActivationIndex, _Welford.new)
            .add(EegCalibration.log10(fa));
      }
      for (final band in const ['alpha', 'theta', 'beta']) {
        final asym = EegIndices.asymmetry(f, band: band);
        if (asym != null) {
          indices
              .putIfAbsent('${EegCalibration.asymmetryIndexPrefix}$band', _Welford.new)
              .add(asym.index);
        }
      }
    }

    final closedMean = <String, Map<String, double>>{};
    for (final band in EegCalibration.bands) {
      final w = <String, _Welford>{};
      for (final f in closed) {
        for (final b in f) {
          w.putIfAbsent(b.channel, _Welford.new).add(EegIndices.bandValue(b, band));
        }
      }
      if (w.isNotEmpty) closedMean[band] = {for (final e in w.entries) e.key: e.value.mean};
    }

    if (_raw.isNotEmpty) {
      linMean[EegCalibration.rawKey] = {for (final e in _raw.entries) e.key: e.value.mean};
      linSd[EegCalibration.rawKey] = {for (final e in _raw.entries) e.key: e.value.sd};
    }

    // Noise floor: the raw signal's spread around its DC level, averaged
    // over channels. Four floors is an artifact for the processor.
    final sds = _raw.values.map((w) => w.sd).where((v) => v.isFinite).toList();
    final noiseFloor = sds.isEmpty ? 0.0 : sds.reduce((a, b) => a + b) / sds.length;

    return EegCalibration(
      id: 'cal_${now.microsecondsSinceEpoch}',
      subjectId: subjectId,
      deviceType: deviceType,
      channels: channels,
      baselines: linMean,
      deviations: linSd,
      eyesClosed: closedMean,
      logMeans: logMean,
      logDeviations: logSd,
      headDeviations: headSd,
      indexMeans: {for (final e in indices.entries) e.key: e.value.mean},
      indexDeviations: {for (final e in indices.entries) e.key: e.value.sd},
      noiseFloor: noiseFloor,
      artifactThreshold: noiseFloor * 4,
      calibratedAt: now,
      eyesOpenSeconds: eyesOpenSeconds,
      eyesClosedSeconds: eyesClosedSeconds,
      frames: open.length + closed.length,
      rejectedFrames: (_open.length - open.length) + (_closed.length - closed.length),
    );
  }

  void reset() {
    _open.clear();
    _closed.clear();
    _raw.clear();
    _rawSamples = 0;
  }

  static double _median(List<double> v) {
    if (v.isEmpty) return 0;
    final s = List.of(v)..sort();
    final mid = s.length ~/ 2;
    return s.length.isOdd ? s[mid] : (s[mid - 1] + s[mid]) / 2;
  }
}

/// Running mean / variance (Welford 1962).
class _Welford {
  int n = 0;
  double mean = 0;
  double _m2 = 0;

  void add(double x) {
    n++;
    final delta = x - mean;
    mean += delta / n;
    _m2 += delta * (x - mean);
  }

  double get variance => n < 2 ? 0.0 : _m2 / (n - 1);

  double get sd => math.sqrt(variance);
}

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

/// Accumulates band-power frames and raw samples per phase and turns them
/// into an [EegCalibration]. Pure Dart, streaming (Welford) statistics, so
/// it holds no history and a 90 s routine costs nothing.
class EegCalibrationBuilder {
  final _open = <String, Map<String, _Welford>>{};
  final _closed = <String, Map<String, _Welford>>{};
  final _raw = <String, _Welford>{};
  final _indices = <String, _Welford>{};
  int _openFrames = 0;
  int _closedFrames = 0;
  int _rawSamples = 0;

  int get eyesOpenFrames => _openFrames;
  int get eyesClosedFrames => _closedFrames;
  int get rawSamples => _rawSamples;

  /// Channels seen so far in the eyes-open phase.
  List<String> get channels => (_open['alpha']?.keys ?? const Iterable<String>.empty()).toList();

  void addFrame(EegCalibrationPhase phase, List<EegBandPower> frame) {
    if (frame.isEmpty) return;
    final table = switch (phase) {
      EegCalibrationPhase.eyesOpen => _open,
      EegCalibrationPhase.eyesClosed => _closed,
      _ => null,
    };
    if (table == null) return;

    for (final b in frame) {
      for (final band in EegCalibration.bands) {
        table.putIfAbsent(band, () => {}).putIfAbsent(b.channel, _Welford.new).add(
              EegIndices.bandValue(b, band),
            );
      }
    }

    if (phase == EegCalibrationPhase.eyesOpen) {
      _openFrames++;
      final fa = EegIndices.frontalActivation(frame);
      if (fa != null) {
        _indices.putIfAbsent(EegCalibration.frontalActivationIndex, _Welford.new).add(fa);
      }
      for (final band in const ['alpha', 'theta', 'beta']) {
        final asym = EegIndices.asymmetry(frame, band: band);
        if (asym != null) {
          _indices
              .putIfAbsent('${EegCalibration.asymmetryIndexPrefix}$band', _Welford.new)
              .add(asym.index);
        }
      }
    } else {
      _closedFrames++;
    }
  }

  /// Raw samples feed the DC level and noise floor per channel. Only the
  /// eyes-open phase is used; blinks are absent there by instruction and
  /// the eyes-closed phase adds nothing to the noise estimate.
  void addRaw(EegCalibrationPhase phase, EegSample sample) {
    if (phase != EegCalibrationPhase.eyesOpen) return;
    _rawSamples++;
    for (final e in sample.channels.entries) {
      if (!e.value.isFinite) continue;
      _raw.putIfAbsent(e.key, _Welford.new).add(e.value);
    }
  }

  bool get hasData => _openFrames > 0;

  EegCalibration build({
    String? subjectId,
    EegDeviceType? deviceType,
    required double eyesOpenSeconds,
    required double eyesClosedSeconds,
    DateTime? at,
  }) {
    final now = at ?? DateTime.now();
    final baselines = <String, Map<String, double>>{
      for (final e in _open.entries)
        e.key: {for (final c in e.value.entries) c.key: c.value.mean},
    };
    final deviations = <String, Map<String, double>>{
      for (final e in _open.entries)
        e.key: {for (final c in e.value.entries) c.key: c.value.sd},
    };
    if (_raw.isNotEmpty) {
      baselines[EegCalibration.rawKey] = {for (final e in _raw.entries) e.key: e.value.mean};
      deviations[EegCalibration.rawKey] = {for (final e in _raw.entries) e.key: e.value.sd};
    }
    final eyesClosed = <String, Map<String, double>>{
      for (final e in _closed.entries)
        e.key: {for (final c in e.value.entries) c.key: c.value.mean},
    };

    // Noise floor: the raw signal's spread around its DC level, averaged
    // over channels. An excursion of four floors is an artifact (blink,
    // jaw clench, cable tug) for the processor's purposes.
    final sds = _raw.values.map((w) => w.sd).where((v) => v.isFinite).toList();
    final noiseFloor = sds.isEmpty ? 0.0 : sds.reduce((a, b) => a + b) / sds.length;

    return EegCalibration(
      id: 'cal_${now.microsecondsSinceEpoch}',
      subjectId: subjectId,
      deviceType: deviceType,
      channels: channels,
      baselines: baselines,
      deviations: deviations,
      eyesClosed: eyesClosed,
      indexMeans: {for (final e in _indices.entries) e.key: e.value.mean},
      indexDeviations: {for (final e in _indices.entries) e.key: e.value.sd},
      noiseFloor: noiseFloor,
      artifactThreshold: noiseFloor * 4,
      calibratedAt: now,
      eyesOpenSeconds: eyesOpenSeconds,
      eyesClosedSeconds: eyesClosedSeconds,
      frames: _openFrames + _closedFrames,
    );
  }

  void reset() {
    _open.clear();
    _closed.clear();
    _raw.clear();
    _indices.clear();
    _openFrames = 0;
    _closedFrames = 0;
    _rawSamples = 0;
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

import 'dart:typed_data';

import '../../domain/models/eeg_channel_catalog.dart';
import '../../domain/models/eeg_sample.dart';
import 'eeg_ring_buffer.dart';
import 'eeg_spectral.dart';

/// Spectral coherence between the two electrodes of a hemispheric pair
/// over the last [window] of raw EEG — the module's single meaning of
/// "coherence".
///
/// Distinct from *symmetry* (`1 − |asymmetry|` of band power), which says
/// whether both sides have the same amount of a rhythm but nothing about
/// whether they oscillate together. Consumer headsets share one reference
/// electrode, which inflates [msc]; [imaginary] discards the zero-lag
/// component and is the conservative reading.
class EegPairCoherence {
  final EegHemisphericPair pair;

  /// Band → mean magnitude-squared coherence (`0..1`).
  final Map<String, double> msc;

  /// Band → mean imaginary coherence (`0..1`).
  final Map<String, double> imaginary;

  /// Band → 95 % chance threshold of the band-averaged MSC: below it the
  /// value is indistinguishable from two independent signals.
  final Map<String, double> thresholds;
  final Duration window;
  final DateTime at;

  const EegPairCoherence({
    required this.pair,
    required this.msc,
    required this.imaginary,
    required this.thresholds,
    required this.window,
    required this.at,
  });

  double? of(String band) => msc[band];

  double? threshold(String band) => thresholds[band];

  bool isSignificant(String band) {
    final v = msc[band];
    final t = thresholds[band];
    return v != null && t != null && v > t;
  }

  /// Whether this reading is recent enough to stand for "now".
  bool isFresh({Duration maxAge = const Duration(seconds: 3), DateTime? now}) =>
      (now ?? DateTime.now()).difference(at) <= maxAge;
}

/// Buffers the raw samples of one pair and, every [hop], estimates Welch
/// coherence over the last [window] (1 s segments, 50 % overlap).
///
/// 8 s gives 15 segments: enough for a stable estimate and a chance
/// threshold near 0.25 for alpha, at the cost of reacting within seconds rather than
/// instantly — coherence is a property of a stretch of signal, not of a
/// sample.
class EegCoherenceTracker {
  final Duration window;
  final Duration hop;
  final double segmentSeconds;

  EegCoherenceTracker({
    this.window = const Duration(seconds: 8),
    this.hop = const Duration(seconds: 1),
    this.segmentSeconds = 1.0,
  });

  EegFloat64RingBuffer? _left;
  EegFloat64RingBuffer? _right;
  Float64List? _scratchLeft;
  Float64List? _scratchRight;
  EegHemisphericPair? _pair;
  int _rate = 0;
  int _sinceHop = 0;

  EegHemisphericPair? get pair => _pair;

  void reset() {
    _left?.clear();
    _right?.clear();
    _pair = null;
    _sinceHop = 0;
  }

  /// Feeds one sample for [pair]. Returns a reading when a hop boundary is
  /// crossed and at least two segments' worth of signal is buffered.
  EegPairCoherence? push(EegSample sample, EegHemisphericPair pair, int sampleRate) =>
      pushValues(
        sample.channels[pair.left],
        sample.channels[pair.right],
        pair,
        sampleRate,
      );

  /// Zero-map fast path accepting the pair's raw electrode values directly.
  EegPairCoherence? pushValues(
    double? l,
    double? r,
    EegHemisphericPair pair,
    int sampleRate,
  ) {
    if (sampleRate <= 0 ||
        window <= Duration.zero ||
        !segmentSeconds.isFinite ||
        segmentSeconds <= 0) {
      return null;
    }
    final capacity = (window.inMicroseconds * sampleRate / 1000000)
        .round()
        .clamp(1, sampleRate * 300);
    if (_pair != pair || _rate != sampleRate) {
      reset();
      _pair = pair;
      _rate = sampleRate;
      (_left ??= EegFloat64RingBuffer(capacity)).ensureCapacity(capacity);
      (_right ??= EegFloat64RingBuffer(capacity)).ensureCapacity(capacity);
    }
    if (l == null || r == null || !l.isFinite || !r.isFinite) return null;

    final leftRing = (_left ??= EegFloat64RingBuffer(capacity))
      ..ensureCapacity(capacity);
    final rightRing = (_right ??= EegFloat64RingBuffer(capacity))
      ..ensureCapacity(capacity);
    leftRing.push(l);
    rightRing.push(r);

    _sinceHop++;
    final hopMicros = hop > Duration.zero ? hop.inMicroseconds : 1;
    final hopSamples =
        (hopMicros * sampleRate / 1000000).round().clamp(1, 1 << 30);
    if (_sinceHop < hopSamples) return null;
    final n = leftRing.length;
    if (n < 2 * segmentSeconds * sampleRate) return null;
    _sinceHop = 0;

    if (_scratchLeft == null || _scratchLeft!.length != n) {
      _scratchLeft = Float64List(n);
      _scratchRight = Float64List(n);
    }
    final spec = EegSpectral.coherence(
      leftRing.toFloat64List(_scratchLeft),
      rightRing.toFloat64List(_scratchRight),
      sampleRate.toDouble(),
      segmentSeconds: segmentSeconds,
    );
    if (spec.segments == 0) return null;
    final alpha = spec.band('alpha');
    // A flat or disconnected pair has no defined coherence.
    if (alpha == null) return null;
    return EegPairCoherence(
      pair: pair,
      msc: {
        for (final b in EegBands.coherenceBands)
          if (spec.band(b) != null) b: spec.band(b)!,
      },
      imaginary: {
        for (final b in EegBands.coherenceBands)
          if (spec.imaginaryBand(b) != null) b: spec.imaginaryBand(b)!,
      },
      thresholds: {
        for (final b in EegBands.coherenceBands)
          if (spec.bandSignificance(b) != null) b: spec.bandSignificance(b)!,
      },
      window: Duration(microseconds: (n * 1000000 / sampleRate).round()),
      at: DateTime.now(),
    );
  }
}

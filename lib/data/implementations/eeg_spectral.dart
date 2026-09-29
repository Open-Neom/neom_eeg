import 'dart:math' as math;

/// Canonical EEG bands in Hz, half-open `[low, high)`. The one definition
/// every spectral computation in the module uses.
class EegBands {
  EegBands._();

  static const Map<String, (double, double)> ranges = {
    'delta': (0.5, 4.0),
    'theta': (4.0, 8.0),
    'alpha': (8.0, 13.0),
    'betaLow': (13.0, 20.0),
    'betaHigh': (20.0, 30.0),
    'gamma': (30.0, 50.0),
  };

  /// Range of [band]; `beta` is low + high.
  static (double, double)? rangeOf(String band) =>
      band == 'beta' ? (13.0, 30.0) : ranges[band];

  /// Bands the coherence tracker reports (the ones a hemispheric protocol
  /// reads; gamma is dominated by muscle at the temples).
  static const coherenceBands = ['delta', 'theta', 'alpha', 'beta'];
}

/// One-sided power spectrum: bin frequencies and power per bin.
class EegSpectrum {
  final List<double> freqs;
  final List<double> power;

  const EegSpectrum(this.freqs, this.power);

  /// Total power in `[low, high)`.
  double sum(double low, double high) {
    var total = 0.0;
    for (var i = 0; i < freqs.length; i++) {
      if (freqs[i] >= low && freqs[i] < high) total += power[i];
    }
    return total;
  }

  double band(String name) {
    final r = EegBands.rangeOf(name);
    return r == null ? 0.0 : sum(r.$1, r.$2);
  }
}

/// Coherence between two signals per frequency bin (Welch).
///
/// * [msc] — magnitude-squared coherence `|Sxy|² / (Sxx·Syy)`, `0..1`: how
///   consistently the two signals keep the same phase relation at each
///   frequency. This is what "coherence" means in the EEG literature.
/// * [imaginary] — `|Im(Sxy)| / √(Sxx·Syy)` (Nolte et al. 2004). Zero-lag
///   coupling — volume conduction, the shared reference of consumer
///   headsets — has no imaginary part, so this is the conservative reading
///   of *interaction* between hemispheres.
///
/// [significance] is the 95 % threshold of a single bin's MSC for two
/// independent Gaussian signals with [independentSegments] disjoint
/// segments (`1 − 0.05^(1/(K−1))`). A band average needs its own,
/// narrower threshold: [bandSignificance].
class EegCoherenceSpectrum {
  final List<double> freqs;
  final List<double> msc;
  final List<double> imaginary;
  final int segments;
  final int independentSegments;
  final double significance;

  const EegCoherenceSpectrum({
    required this.freqs,
    required this.msc,
    required this.imaginary,
    required this.segments,
    required this.independentSegments,
    required this.significance,
  });

  static const empty = EegCoherenceSpectrum(
    freqs: [],
    msc: [],
    imaginary: [],
    segments: 0,
    independentSegments: 0,
    significance: 1,
  );

  /// 95 % chance threshold for the *band-averaged* MSC. Under independence
  /// each bin's MSC follows Beta(1, K−1) (mean 1/K); averaging B bins
  /// narrows it. Neighbouring bins are correlated by the Hann window, so
  /// only B/2 count as independent (conservative). Normal approximation:
  /// `1/K + 1.645·√((K−1)/(K²(K+1)) / (B/2))`.
  double? bandSignificance(String band) {
    final r = EegBands.rangeOf(band);
    if (r == null || independentSegments < 2) return null;
    var bins = 0;
    for (var i = 0; i < freqs.length; i++) {
      if (freqs[i] >= r.$1 && freqs[i] < r.$2 && msc[i].isFinite) bins++;
    }
    if (bins == 0) return null;
    final k = independentSegments.toDouble();
    final effective = math.max(1.0, bins / 2);
    final variance = (k - 1) / (k * k * (k + 1)) / effective;
    return (1 / k + 1.645 * math.sqrt(variance)).clamp(0.0, 1.0);
  }

  double? _mean(List<double> values, String band) {
    final r = EegBands.rangeOf(band);
    if (r == null) return null;
    var sum = 0.0;
    var n = 0;
    for (var i = 0; i < freqs.length; i++) {
      // NaN marks a bin with no power on one side: coherence is undefined
      // there, not zero.
      if (freqs[i] >= r.$1 && freqs[i] < r.$2 && values[i].isFinite) {
        sum += values[i];
        n++;
      }
    }
    return n == 0 ? null : sum / n;
  }

  /// Mean MSC over the bins of [band].
  double? band(String band) => _mean(msc, band);

  /// Mean imaginary coherence over the bins of [band].
  double? imaginaryBand(String band) => _mean(imaginary, band);
}

/// Spectral estimators over raw EEG. Pure Dart, no FFT dependency: only the
/// bins up to [maxHz] are evaluated, with cached twiddle tables, which is
/// cheaper than a full FFT for the 1–50 Hz range EEG needs.
class EegSpectral {
  EegSpectral._();

  static final _hannCache = <int, List<double>>{};
  static final _twiddleCache = <String, ({List<double> cos, List<double> sin})>{};

  static List<double> hann(int n) => _hannCache.putIfAbsent(
        n,
        () => n <= 1
            ? List.filled(n, 1.0)
            : [for (var i = 0; i < n; i++) 0.5 - 0.5 * math.cos(2 * math.pi * i / (n - 1))],
      );

  /// Removes the least-squares line, so electrode drift and the DC offset
  /// of consumer headsets (≈4200 µV on Emotiv) do not leak into delta.
  static List<double> detrend(List<double> x) {
    final n = x.length;
    if (n < 2) return List.filled(n, 0.0);
    final meanT = (n - 1) / 2;
    var meanX = 0.0;
    for (final v in x) {
      meanX += v;
    }
    meanX /= n;
    var num = 0.0, den = 0.0;
    for (var i = 0; i < n; i++) {
      final dt = i - meanT;
      num += dt * (x[i] - meanX);
      den += dt * dt;
    }
    final slope = den == 0 ? 0.0 : num / den;
    return [for (var i = 0; i < n; i++) x[i] - meanX - slope * (i - meanT)];
  }

  static List<double> _prepare(List<double> x) {
    final d = detrend([for (final v in x) v.isFinite ? v : 0.0]);
    final w = hann(d.length);
    return [for (var i = 0; i < d.length; i++) d[i] * w[i]];
  }

  static int _maxBin(int n, double fs, double maxHz) =>
      math.min(n ~/ 2, (maxHz * n / fs).floor());

  static ({List<double> cos, List<double> sin}) _twiddles(int n, int bins) =>
      _twiddleCache.putIfAbsent('$n:$bins', () {
        final c = List<double>.filled(bins * n, 0);
        final s = List<double>.filled(bins * n, 0);
        for (var k = 1; k <= bins; k++) {
          for (var i = 0; i < n; i++) {
            final a = -2.0 * math.pi * k * i / n;
            c[(k - 1) * n + i] = math.cos(a);
            s[(k - 1) * n + i] = math.sin(a);
          }
        }
        return (cos: c, sin: s);
      });

  /// Real/imaginary DFT of an already windowed segment, bins `1..bins`.
  static (List<double>, List<double>) _dft(List<double> x, int bins) {
    final n = x.length;
    final t = _twiddles(n, bins);
    final re = List<double>.filled(bins, 0);
    final im = List<double>.filled(bins, 0);
    for (var k = 0; k < bins; k++) {
      var r = 0.0, j = 0.0;
      final base = k * n;
      for (var i = 0; i < n; i++) {
        r += x[i] * t.cos[base + i];
        j += x[i] * t.sin[base + i];
      }
      re[k] = r;
      im[k] = j;
    }
    return (re, im);
  }

  /// Hann-windowed, detrended power spectrum up to [maxHz].
  ///
  /// Normalised by `n·Σw²` so the power of a tone inside a band equals the
  /// rectangular-window convention (`A²/4` per one-sided tone), i.e. band
  /// sums are comparable with the previous unwindowed estimates.
  static EegSpectrum powerSpectrum(List<double> x, double fs, {double maxHz = 50}) {
    final n = x.length;
    if (n < 4 || fs <= 0) return const EegSpectrum([], []);
    final bins = _maxBin(n, fs, maxHz);
    if (bins < 1) return const EegSpectrum([], []);
    final w = hann(n);
    final norm = w.fold<double>(0.0, (a, v) => a + v * v) * n;
    final (re, im) = _dft(_prepare(x), bins);
    return EegSpectrum(
      [for (var k = 1; k <= bins; k++) k * fs / n],
      [for (var k = 0; k < bins; k++) (re[k] * re[k] + im[k] * im[k]) / norm],
    );
  }

  /// Welch coherence between [x] and [y] (same length, same rate):
  /// segments of [segmentSeconds], [overlap] between them, Hann window and
  /// detrending per segment.
  static EegCoherenceSpectrum coherence(
    List<double> x,
    List<double> y,
    double fs, {
    double segmentSeconds = 1.0,
    double overlap = 0.5,
    double maxHz = 45,
  }) {
    final n = math.min(x.length, y.length);
    final seg = (segmentSeconds * fs).round();
    if (seg < 8 || n < seg) return EegCoherenceSpectrum.empty;
    final step = math.max(1, (seg * (1 - overlap)).round());
    final bins = _maxBin(seg, fs, maxHz);
    if (bins < 1) return EegCoherenceSpectrum.empty;

    final sxx = List<double>.filled(bins, 0);
    final syy = List<double>.filled(bins, 0);
    final sxyRe = List<double>.filled(bins, 0);
    final sxyIm = List<double>.filled(bins, 0);
    var segments = 0;
    for (var start = 0; start + seg <= n; start += step) {
      final (xr, xi) = _dft(_prepare(x.sublist(start, start + seg)), bins);
      final (yr, yi) = _dft(_prepare(y.sublist(start, start + seg)), bins);
      for (var k = 0; k < bins; k++) {
        sxx[k] += xr[k] * xr[k] + xi[k] * xi[k];
        syy[k] += yr[k] * yr[k] + yi[k] * yi[k];
        // X · conj(Y)
        sxyRe[k] += xr[k] * yr[k] + xi[k] * yi[k];
        sxyIm[k] += xi[k] * yr[k] - xr[k] * yi[k];
      }
      segments++;
    }

    final msc = List<double>.filled(bins, double.nan);
    final imag = List<double>.filled(bins, double.nan);
    for (var k = 0; k < bins; k++) {
      final den = sxx[k] * syy[k];
      if (den <= 1e-24) continue;
      msc[k] = ((sxyRe[k] * sxyRe[k] + sxyIm[k] * sxyIm[k]) / den).clamp(0.0, 1.0);
      imag[k] = (sxyIm[k].abs() / math.sqrt(den)).clamp(0.0, 1.0);
    }

    // Overlapping segments are not independent; count only the disjoint
    // ones for the significance threshold (conservative).
    final independent = math.max(2, n ~/ seg);
    return EegCoherenceSpectrum(
      freqs: [for (var k = 1; k <= bins; k++) k * fs / seg],
      msc: msc,
      imaginary: imag,
      segments: segments,
      independentSegments: independent,
      significance: 1 - math.pow(0.05, 1 / (independent - 1)).toDouble(),
    );
  }

  /// Windowed power of [x] at exactly [f] Hz (single-frequency DFT, not
  /// bin-aligned). Same normalisation as [powerSpectrum].
  static double powerAt(List<double> prepared, double fs, double f, double norm) {
    var r = 0.0, j = 0.0;
    final w = -2.0 * math.pi * f / fs;
    for (var i = 0; i < prepared.length; i++) {
      r += prepared[i] * math.cos(w * i);
      j += prepared[i] * math.sin(w * i);
    }
    return (r * r + j * j) / norm;
  }

  /// Steady-state response at a stimulus frequency: power at [f0] divided
  /// by the mean power of the neighbouring frequencies
  /// `f0 ± [exclude, neighbour]`, sampled at the spectral resolution.
  ///
  /// ≈1 means the EEG shows nothing special at the stimulus frequency;
  /// clearly above 1 (≥ 2 is a common criterion) means the brain is
  /// following it. This is what "entrainment" measures in the literature
  /// (ASSR / SSVEP), unlike a band-share change. Needs a window long enough
  /// to resolve [exclude] (`n/fs ≥ 1/exclude`, i.e. ≥ 4 s for 0.25 Hz);
  /// returns null otherwise or when [f0] is outside the usable range.
  static double? frequencyFollowingSnr(
    List<double> x,
    double fs,
    double f0, {
    double exclude = 0.25,
    double neighbour = 1.5,
  }) {
    final n = x.length;
    if (n < 8 || fs <= 0 || f0 <= 0 || f0 + neighbour >= fs / 2) return null;
    final resolution = fs / n;
    if (resolution > exclude) return null;
    final prepared = _prepare(x);
    final w = hann(n);
    final norm = w.fold<double>(0.0, (a, v) => a + v * v) * n;

    final signal = powerAt(prepared, fs, f0, norm);
    var noise = 0.0;
    var count = 0;
    for (var d = exclude + resolution; d <= neighbour + 1e-9; d += resolution) {
      for (final f in [f0 - d, f0 + d]) {
        if (f < 0.3) continue;
        noise += powerAt(prepared, fs, f, norm);
        count++;
      }
    }
    if (count < 4 || noise <= 0) return null;
    return signal / (noise / count);
  }
}

import 'dart:math' as math;
import 'dart:typed_data';

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

  static final _hannCache = <int, Float64List>{};
  static final _hannNormCache = <int, double>{};
  static final _twiddleCache = <String, ({Float64List cos, Float64List sin})>{};
  static const int _maxCacheEntries = 64;

  static List<double> hann(int n) => _hannTyped(n);

  static Float64List _hannTyped(int n) {
    if (n <= 0) return Float64List(0);
    if (!_hannCache.containsKey(n) && _hannCache.length >= _maxCacheEntries) {
      _hannCache.clear();
      _hannNormCache.clear();
    }
    return _hannCache.putIfAbsent(n, () {
      final w = Float64List(n);
      if (n == 1) {
        w[0] = 1.0;
      } else {
        final scale = 2.0 * math.pi / (n - 1);
        for (var i = 0; i < n; i++) {
          w[i] = 0.5 - 0.5 * math.cos(scale * i);
        }
      }
      return w;
    });
  }

  static double _hannNorm(int n) {
    if (n <= 0) return 0.0;
    final cached = _hannNormCache[n];
    if (cached != null) return cached;
    final w = _hannTyped(n);
    var sumSq = 0.0;
    for (var i = 0; i < n; i++) {
      final v = w[i];
      sumSq += v * v;
    }
    final norm = sumSq * n;
    _hannNormCache[n] = norm;
    return norm;
  }

  /// Removes the least-squares line, so electrode drift and the DC offset
  /// of consumer headsets (≈4200 µV on Emotiv) do not leak into delta.
  static List<double> detrend(List<double> x) {
    final n = x.length;
    final out = Float64List(n);
    if (n < 2) return out;
    final meanT = (n - 1) / 2.0;
    var meanX = 0.0;
    for (var i = 0; i < n; i++) {
      meanX += x[i];
    }
    meanX /= n;
    var num = 0.0, den = 0.0;
    for (var i = 0; i < n; i++) {
      final dt = i - meanT;
      num += dt * (x[i] - meanX);
      den += dt * dt;
    }
    final slope = den == 0 ? 0.0 : num / den;
    for (var i = 0; i < n; i++) {
      out[i] = x[i] - meanX - slope * (i - meanT);
    }
    return out;
  }

  /// Sanitises non-finite samples, removes least-squares linear trend, and
  /// applies the Hann window in place into [out] without allocating sublists.
  static void _prepareSliceInto(
    List<double> x,
    int start,
    int n,
    Float64List out,
  ) {
    if (n < 2) {
      for (var i = 0; i < n; i++) {
        out[i] = 0.0;
      }
      return;
    }
    final meanT = (n - 1) / 2.0;
    var meanX = 0.0;
    for (var i = 0; i < n; i++) {
      final v = x[start + i];
      final safe = v.isFinite ? v : 0.0;
      out[i] = safe;
      meanX += safe;
    }
    meanX /= n;
    var num = 0.0, den = 0.0;
    for (var i = 0; i < n; i++) {
      final dt = i - meanT;
      num += dt * (out[i] - meanX);
      den += dt * dt;
    }
    final slope = den == 0 ? 0.0 : num / den;
    final w = _hannTyped(n);
    for (var i = 0; i < n; i++) {
      out[i] = (out[i] - meanX - slope * (i - meanT)) * w[i];
    }
  }

  static Float64List _prepare(List<double> x) {
    final out = Float64List(x.length);
    _prepareSliceInto(x, 0, x.length, out);
    return out;
  }

  static int _maxBin(int n, double fs, double maxHz) {
    if (!fs.isFinite || fs <= 0 || !maxHz.isFinite || maxHz <= 0 || n <= 0) {
      return 0;
    }
    return math.min(n ~/ 2, (maxHz * n / fs).floor());
  }

  static ({Float64List cos, Float64List sin}) _twiddles(int n, int bins) {
    final key = '$n:$bins';
    if (!_twiddleCache.containsKey(key) &&
        _twiddleCache.length >= _maxCacheEntries) {
      _twiddleCache.clear();
    }
    return _twiddleCache.putIfAbsent(key, () {
      final c = Float64List(bins * n);
      final s = Float64List(bins * n);
      for (var k = 1; k <= bins; k++) {
        final step = -2.0 * math.pi * k / n;
        for (var i = 0; i < n; i++) {
          final a = step * i;
          c[(k - 1) * n + i] = math.cos(a);
          s[(k - 1) * n + i] = math.sin(a);
        }
      }
      return (cos: c, sin: s);
    });
  }

  /// Real/imaginary DFT of an already windowed segment, bins `1..bins`, written
  /// into pre-allocated [re] and [im] buffers.
  static void _dftInto(
    Float64List x,
    int n,
    int bins,
    Float64List re,
    Float64List im,
  ) {
    final t = _twiddles(n, bins);
    final cosTbl = t.cos;
    final sinTbl = t.sin;
    for (var k = 0; k < bins; k++) {
      var r = 0.0, j = 0.0;
      final base = k * n;
      for (var i = 0; i < n; i++) {
        final xi = x[i];
        r += xi * cosTbl[base + i];
        j += xi * sinTbl[base + i];
      }
      re[k] = r;
      im[k] = j;
    }
  }

  /// Hann-windowed, detrended power spectrum up to [maxHz].
  ///
  /// Normalised by `n·Σw²` so the power of a tone inside a band equals the
  /// rectangular-window convention (`A²/4` per one-sided tone), i.e. band
  /// sums are comparable with the previous unwindowed estimates.
  static EegSpectrum powerSpectrum(List<double> x, double fs, {double maxHz = 50}) {
    final n = x.length;
    if (n < 4 || !fs.isFinite || fs <= 0 || !maxHz.isFinite || maxHz <= 0) {
      return const EegSpectrum([], []);
    }
    final bins = _maxBin(n, fs, maxHz);
    if (bins < 1) return const EegSpectrum([], []);
    final norm = _hannNorm(n);
    if (norm <= 0) return const EegSpectrum([], []);
    final prepared = _prepare(x);
    final re = Float64List(bins);
    final im = Float64List(bins);
    _dftInto(prepared, n, bins, re, im);
    final freqs = Float64List(bins);
    final power = Float64List(bins);
    final binScale = fs / n;
    for (var k = 0; k < bins; k++) {
      freqs[k] = (k + 1) * binScale;
      final rk = re[k];
      final ik = im[k];
      power[k] = (rk * rk + ik * ik) / norm;
    }
    return EegSpectrum(freqs, power);
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
    if (!fs.isFinite ||
        fs <= 0 ||
        !segmentSeconds.isFinite ||
        segmentSeconds <= 0 ||
        !overlap.isFinite ||
        overlap < 0 ||
        overlap >= 1.0 ||
        !maxHz.isFinite ||
        maxHz <= 0) {
      return EegCoherenceSpectrum.empty;
    }
    final n = math.min(x.length, y.length);
    final seg = (segmentSeconds * fs).round();
    if (seg < 8 || n < seg) return EegCoherenceSpectrum.empty;
    final step = math.max(1, (seg * (1 - overlap)).round());
    final bins = _maxBin(seg, fs, maxHz);
    if (bins < 1) return EegCoherenceSpectrum.empty;

    final sxx = Float64List(bins);
    final syy = Float64List(bins);
    final sxyRe = Float64List(bins);
    final sxyIm = Float64List(bins);
    final workX = Float64List(seg);
    final workY = Float64List(seg);
    final xr = Float64List(bins);
    final xi = Float64List(bins);
    final yr = Float64List(bins);
    final yi = Float64List(bins);

    var segments = 0;
    for (var start = 0; start + seg <= n; start += step) {
      _prepareSliceInto(x, start, seg, workX);
      _prepareSliceInto(y, start, seg, workY);
      _dftInto(workX, seg, bins, xr, xi);
      _dftInto(workY, seg, bins, yr, yi);
      for (var k = 0; k < bins; k++) {
        final xrk = xr[k], xik = xi[k];
        final yrk = yr[k], yik = yi[k];
        sxx[k] += xrk * xrk + xik * xik;
        syy[k] += yrk * yrk + yik * yik;
        // X · conj(Y)
        sxyRe[k] += xrk * yrk + xik * yik;
        sxyIm[k] += xik * yrk - xrk * yik;
      }
      segments++;
    }

    final msc = Float64List(bins);
    final imag = Float64List(bins);
    for (var k = 0; k < bins; k++) {
      final den = sxx[k] * syy[k];
      if (den <= 1e-24) {
        msc[k] = double.nan;
        imag[k] = double.nan;
        continue;
      }
      msc[k] = ((sxyRe[k] * sxyRe[k] + sxyIm[k] * sxyIm[k]) / den).clamp(0.0, 1.0);
      imag[k] = (sxyIm[k].abs() / math.sqrt(den)).clamp(0.0, 1.0);
    }

    // Overlapping segments are not independent; count only the disjoint
    // ones for the significance threshold (conservative).
    final independent = math.max(2, n ~/ seg);
    final freqs = Float64List(bins);
    final binScale = fs / seg;
    for (var k = 0; k < bins; k++) {
      freqs[k] = (k + 1) * binScale;
    }
    return EegCoherenceSpectrum(
      freqs: freqs,
      msc: msc,
      imaginary: imag,
      segments: segments,
      independentSegments: independent,
      significance: 1 - math.pow(0.05, 1 / (independent - 1)).toDouble(),
    );
  }

  /// Windowed power of [prepared] at exactly [f] Hz (single-frequency DFT via
  /// Goertzel's recurrence, not bin-aligned). Same normalisation as
  /// [powerSpectrum], requiring a single `cos` evaluation instead of `2N`
  /// trigonometric calls.
  static double powerAt(List<double> prepared, double fs, double f, double norm) {
    final n = prepared.length;
    if (n == 0 ||
        !fs.isFinite ||
        fs <= 0 ||
        !f.isFinite ||
        !norm.isFinite ||
        norm <= 0) {
      return 0.0;
    }
    final c = 2.0 * math.cos(2.0 * math.pi * f / fs);
    var s1 = 0.0;
    var s2 = 0.0;
    for (var i = 0; i < n; i++) {
      final s0 = prepared[i] + c * s1 - s2;
      s2 = s1;
      s1 = s0;
    }
    final magSq = s1 * s1 + s2 * s2 - c * s1 * s2;
    if (!magSq.isFinite) return double.nan;
    return (magSq < 0.0 ? 0.0 : magSq) / norm;
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
    if (n < 8 ||
        !fs.isFinite ||
        fs <= 0 ||
        !f0.isFinite ||
        f0 <= 0 ||
        !exclude.isFinite ||
        exclude <= 0 ||
        !neighbour.isFinite ||
        neighbour <= exclude ||
        f0 + neighbour >= fs / 2) {
      return null;
    }
    final resolution = fs / n;
    if (resolution > exclude) return null;
    final prepared = _prepare(x);
    final norm = _hannNorm(n);

    final signal = powerAt(prepared, fs, f0, norm);
    var noise = 0.0;
    var count = 0;
    for (var d = exclude + resolution; d <= neighbour + 1e-9; d += resolution) {
      final fLow = f0 - d;
      if (fLow >= 0.3) {
        noise += powerAt(prepared, fs, fLow, norm);
        count++;
      }
      final fHigh = f0 + d;
      if (fHigh >= 0.3) {
        noise += powerAt(prepared, fs, fHigh, norm);
        count++;
      }
    }
    if (count < 4 || noise <= 0) return null;
    return signal / (noise / count);
  }
}

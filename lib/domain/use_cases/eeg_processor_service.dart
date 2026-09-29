import '../../domain/models/eeg_asymmetry.dart';
import '../../domain/models/eeg_band_power.dart';
import '../../domain/models/eeg_calibration.dart';
import '../../domain/models/eeg_channel_info.dart';
import '../../domain/models/eeg_sample.dart';

/// Abstract interface for EEG signal processing (pure math, no I/O).
///
/// Handles FFT-based band extraction, artifact detection, and
/// hemispheric asymmetry computation.
abstract class EegProcessorService {
  /// Extract frequency band powers from a window of raw samples.
  ///
  /// Computes the spectrum of each channel and sums bins within the
  /// standard EEG bands. Pass [sampleRate] when the driver knows it;
  /// otherwise it is estimated from the sample timestamps.
  List<EegBandPower> extractBandPower(
    List<EegSample> samples,
    List<EegChannelInfo> channels, {
    double? sampleRate,
  });

  /// Detect whether a sample contains an artifact (blink, jaw clench).
  ///
  /// Uses frontal channel spike detection (>3x baseline = blink)
  /// and simultaneous T7+T8 spike for jaw clench.
  bool detectArtifact(EegSample sample, EegCalibration calibration);

  /// Compute hemispheric asymmetry between left and right channels
  /// for a specific frequency band.
  EegAsymmetry computeAsymmetry(
    EegBandPower left,
    EegBandPower right,
    String band,
  );
}

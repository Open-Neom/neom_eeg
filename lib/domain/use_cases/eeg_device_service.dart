import '../../domain/enums/eeg_connection_state.dart';
import '../../domain/models/eeg_band_power.dart';
import '../../domain/models/eeg_device_info.dart';
import '../../domain/models/eeg_mental_state.dart';
import '../../domain/models/eeg_sample.dart';

/// Abstract interface for EEG device lifecycle management.
///
/// Implementations handle scanning, connecting, and streaming data
/// from specific hardware (Emotiv, Muse, NeuroSky) or simulated sources.
abstract class EegDeviceService {
  /// Scan for available EEG devices.
  Future<List<EegDeviceInfo>> scan({
    Duration timeout = const Duration(seconds: 10),
  });

  /// Connect to a specific device.
  Future<void> connect(EegDeviceInfo device);

  /// Disconnect from the current device.
  Future<void> disconnect();

  /// Raw EEG sample stream (per-sample, all channels).
  Stream<EegSample> get rawStream;

  /// Processed band power stream (FFT-derived, per update cycle).
  Stream<List<EegBandPower>> get bandPowerStream;

  /// Mental state metrics stream (engagement, focus, etc.).
  Stream<EegMentalState> get mentalStateStream;

  /// Current connection state.
  EegConnectionState get connectionState;

  /// Currently connected device, or null if disconnected.
  EegDeviceInfo? get connectedDevice;
}

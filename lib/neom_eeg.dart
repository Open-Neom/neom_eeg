/// # NeomEEG
///
/// EEG device abstraction, signal processing, and closed-loop neurofeedback
/// for the Open Neom ecosystem.
///
/// Supports Emotiv (EPOC X, Insight, MN8), Muse, BrainBit, OpenBCI, and
/// NeuroSky headsets via three provider backends:
///
/// * [EmotivCortexProvider] — WebSocket JSON-RPC to Emotiv Cortex API
/// * [BleGenericEegProvider] — BLE via flutter_blue_plus for Muse/NeuroSky
/// * [SimulatedEegProvider] — Mock data for development and testing
///
/// ## Closed-loop neurofeedback
///
/// ```
/// EEG headset → EegSignalProcessor (FFT → band powers)
///   → EegNeurofeedbackController (compare target vs current)
///     → neom_generator (adjust binaural/isochronic frequency)
///       → user hears adjusted tone → brain responds → loop
/// ```
///
/// ## Medical context
///
/// Includes T7/T8 hemispheric asymmetry monitoring ([EegAsymmetry])
/// for temporal lobe epilepsy screening. See Cyberneom CONTEXT.md.
library;

// ═══════════════════════════════════════════════════════════════
// Enums
// ═══════════════════════════════════════════════════════════════
export 'domain/enums/eeg_device_type.dart';
export 'domain/enums/eeg_connection_state.dart';
export 'domain/enums/eeg_stream_type.dart';

// ═══════════════════════════════════════════════════════════════
// Domain Models
// ═══════════════════════════════════════════════════════════════
export 'domain/models/eeg_sample.dart';
export 'domain/models/eeg_band_power.dart';
export 'domain/models/eeg_channel_info.dart';
export 'domain/models/eeg_device_info.dart';
export 'domain/models/eeg_session.dart';
export 'domain/models/eeg_calibration.dart';
export 'domain/models/eeg_mental_state.dart';
export 'domain/models/eeg_asymmetry.dart';

// ═══════════════════════════════════════════════════════════════
// Service Interfaces
// ═══════════════════════════════════════════════════════════════
export 'domain/use_cases/eeg_device_service.dart';
export 'domain/use_cases/eeg_processor_service.dart';
export 'domain/use_cases/eeg_neurofeedback_service.dart';

// ═══════════════════════════════════════════════════════════════
// Providers (device-specific backends)
// ═══════════════════════════════════════════════════════════════
export 'data/providers/emotiv_cortex_provider.dart';
export 'data/providers/simulated_eeg_provider.dart';
export 'data/providers/ble_generic_eeg_provider.dart';

// ═══════════════════════════════════════════════════════════════
// Implementations
// ═══════════════════════════════════════════════════════════════
export 'data/implementations/eeg_connection_controller.dart';
export 'data/implementations/eeg_signal_processor.dart';
export 'data/implementations/eeg_biofeedback_adapter.dart';
export 'data/implementations/eeg_session_recorder.dart';
export 'data/implementations/eeg_neurofeedback_controller.dart';

// ═══════════════════════════════════════════════════════════════
// UI Pages
// ═══════════════════════════════════════════════════════════════
export 'ui/pages/eeg_monitor_page.dart';

// ═══════════════════════════════════════════════════════════════
// UI Widgets
// ═══════════════════════════════════════════════════════════════
export 'ui/widgets/eeg_device_picker.dart';
export 'ui/widgets/eeg_band_meter.dart';
export 'ui/widgets/eeg_topography.dart';
export 'ui/widgets/eeg_raw_wave.dart';
export 'ui/widgets/eeg_asymmetry_indicator.dart';
export 'ui/widgets/eeg_session_timeline.dart';

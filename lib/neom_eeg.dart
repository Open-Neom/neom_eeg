/// # NeomEEG
///
/// EEG device abstraction, signal processing, and closed-loop neurofeedback
/// for the Open Neom ecosystem.
///
/// ## One API for every headset
///
/// [EegHub] is the entry point. It holds one [EegDriver] per vendor in an
/// [EegDriverRegistry], scans them all at once and routes `connect()` by
/// the device's [EegDeviceType] — the consumer never names a vendor:
///
/// ```dart
/// final hub = EegHub.standard(
///   emotiv: EmotivCortexConfig.fromAppProperties(),
/// );
/// final devices = await hub.scan();       // Emotiv + Muse + …
/// await hub.connect(devices.first);       // routed by devices.first.type
/// hub.bandPowerStream.listen(...);        // native or derived, same stream
/// ```
///
/// Drivers declare [EegCapabilities]; whatever a headset cannot compute
/// itself (band powers, cognitive metrics) the hub derives from raw EEG,
/// so `rawStream`, `bandPowerStream` and `mentalStateStream` are always
/// populated regardless of the hardware.
///
/// | Vendor    | Driver                  | Transport                          |
/// |-----------|-------------------------|------------------------------------|
/// | Emotiv    | [EmotivCortexProvider]  | Cortex service (desktop/web) or embedded Cortex library (mobile) |
/// | Interaxon | [MuseBleProvider]       | BLE GATT                           |
/// | OpenBCI, BrainBit, NeuroSky | [EegPendingDriver] | declared, not yet implemented |
/// | —         | [SimulatedEegProvider]  | in-process                         |
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
export 'domain/enums/eeg_vendor.dart';
export 'domain/enums/eeg_transport.dart';
export 'domain/enums/eeg_device_type.dart';
export 'domain/enums/eeg_connection_state.dart';
export 'domain/enums/eeg_stream_type.dart';

// ═══════════════════════════════════════════════════════════════
// Domain Models
// ═══════════════════════════════════════════════════════════════
export 'domain/models/eeg_sample.dart';
export 'domain/models/eeg_band_power.dart';
export 'domain/models/eeg_channel_info.dart';
export 'domain/models/eeg_channel_catalog.dart';
export 'domain/models/eeg_capabilities.dart';
export 'domain/models/eeg_device_info.dart';
export 'domain/models/eeg_device_status.dart';
export 'domain/models/eeg_session.dart';
export 'domain/models/eeg_calibration.dart';
export 'domain/models/eeg_mental_state.dart';
export 'domain/models/eeg_asymmetry.dart';
export 'domain/models/eeg_exceptions.dart';
export 'domain/models/eeg_recording.dart';
export 'domain/models/eeg_session_capture.dart';
export 'domain/models/eeg_watch_rule.dart';
export 'domain/models/emotiv_cortex_config.dart';

// ═══════════════════════════════════════════════════════════════
// Service Interfaces
// ═══════════════════════════════════════════════════════════════
export 'domain/use_cases/eeg_device_service.dart';
export 'domain/use_cases/eeg_driver.dart';
export 'domain/use_cases/eeg_processor_service.dart';
export 'domain/use_cases/eeg_neurofeedback_service.dart';
export 'domain/use_cases/eeg_recording_service.dart';

// ═══════════════════════════════════════════════════════════════
// Hub (vendor routing)
// ═══════════════════════════════════════════════════════════════
export 'data/hub/eeg_hub.dart';
export 'data/hub/eeg_driver_registry.dart';

// ═══════════════════════════════════════════════════════════════
// Drivers (device-specific backends)
// ═══════════════════════════════════════════════════════════════
export 'data/drivers/eeg_driver_base.dart';
export 'data/providers/emotiv_cortex_provider.dart';
export 'data/providers/emotiv/cortex_transport.dart';
export 'data/providers/emotiv/cortex_client.dart';
export 'data/providers/emotiv/cortex_stream_parser.dart';
export 'data/providers/emotiv/cortex_models.dart';
export 'data/providers/emotiv/cortex_websocket_transport.dart';
export 'data/providers/emotiv/cortex_native_transport.dart';
export 'data/providers/muse_ble_provider.dart';
export 'data/providers/muse/muse_packet_parser.dart';
export 'data/providers/eeg_pending_driver.dart';
export 'data/providers/simulated_eeg_provider.dart';

// ═══════════════════════════════════════════════════════════════
// Implementations
// ═══════════════════════════════════════════════════════════════
export 'data/implementations/eeg_connection_controller.dart';
export 'data/implementations/eeg_signal_processor.dart';
export 'data/implementations/eeg_spectral.dart';
export 'data/implementations/eeg_ring_buffer.dart';
export 'data/implementations/dsp_isolate/eeg_dsp_isolate.dart';
export 'data/implementations/eeg_coherence_tracker.dart';
export 'data/implementations/eeg_band_power_deriver.dart';
export 'data/implementations/eeg_metrics_estimator.dart';
export 'data/implementations/eeg_biofeedback_adapter.dart';
export 'data/implementations/eeg_session_recorder.dart';
export 'data/implementations/local_eeg_recording_service.dart';
export 'data/implementations/eeg_session_capture_controller.dart';
export 'data/implementations/eeg_indices.dart';
export 'data/implementations/eeg_calibration_builder.dart';
export 'data/implementations/eeg_calibration_controller.dart';
export 'data/implementations/eeg_watch_controller.dart';
export 'data/implementations/eeg_practice_link.dart';
export 'data/implementations/eeg_neurofeedback_controller.dart';
export 'data/implementations/eeg_neuro_state_adapter.dart';

// ═══════════════════════════════════════════════════════════════
// UI
// ═══════════════════════════════════════════════════════════════
export 'ui/pages/eeg_monitor_page.dart';
export 'ui/pages/eeg_session_report_page.dart';
export 'ui/widgets/eeg_live_stats_badge.dart';
export 'ui/widgets/eeg_live_dashboard.dart';
export 'ui/widgets/eeg_device_picker.dart';
export 'ui/widgets/eeg_contact_quality_strip.dart';
export 'ui/widgets/eeg_hemispheric_balance.dart';
export 'ui/widgets/eeg_metrics_row.dart';
export 'ui/widgets/eeg_recording_strip.dart';
export 'ui/widgets/eeg_calibration_panel.dart';
export 'ui/widgets/eeg_watch_strip.dart';
export 'ui/widgets/eeg_band_meter.dart';
export 'ui/widgets/eeg_topography.dart';
export 'ui/widgets/eeg_raw_wave.dart';
export 'ui/widgets/eeg_asymmetry_indicator.dart';
export 'ui/widgets/eeg_session_timeline.dart';

import '../models/eeg_recording.dart';

/// Recording and event-marking, independent of the headset.
///
/// Emotiv implements it natively (Cortex records — the marker lands in the
/// EDF the neurologist opens); every other driver gets the local Hive
/// implementation. Consumers reach it through `EegHub.recording` and never
/// learn which one they got beyond [backend].
abstract class EegRecordingService {
  EegRecordingBackend get backend;

  bool get isRecording;

  EegRecording? get activeRecording;

  /// Every marker added through [addMarker], for timelines and overlays.
  Stream<EegMarker> get markerStream;

  /// Emits the recording when one starts and null when it stops, so other
  /// components (the session capture) can align themselves to it.
  Stream<EegRecording?> get activeRecordingStream;

  /// Whether [exportRecordings] can write files itself. False for the
  /// local backend on web, where the host must save [EegExportResult.inlineCsv].
  bool get canExportToFolder;

  Future<EegRecording> startRecording({
    required String title,
    String? description,
    String? subject,
    List<String> tags = const [],
  });

  /// Returns the finished recording, or null when none was active.
  Future<EegRecording?> stopRecording();

  /// Pins an event to the EEG timeline of the active recording.
  ///
  /// Throws [EegException] when nothing is being recorded — Cortex refuses
  /// markers outside a record and the local backend mirrors that so the
  /// behaviour does not depend on the headset.
  Future<EegMarker> addMarker({
    required String label,
    Object value = 1,
    DateTime? at,
    String port = 'Software',
    Map<String, dynamic> extras = const {},
  });

  Future<List<EegRecording>> listRecordings({int limit = 50});

  Future<EegExportResult> exportRecordings({
    required List<String> ids,
    required String folder,
    EegExportFormat format = EegExportFormat.csv,
    Set<EegExportStream> streams = const {
      EegExportStream.eeg,
      EegExportStream.bandPower,
      EegExportStream.performanceMetrics,
    },
  });
}

import 'dart:async';

import '../../domain/enums/eeg_device_type.dart';
import '../../domain/models/eeg_exceptions.dart';
import '../../domain/models/eeg_recording.dart';
import '../../domain/models/eeg_session.dart';
import '../../domain/use_cases/eeg_device_service.dart';
import '../../domain/use_cases/eeg_recording_service.dart';
import 'eeg_session_recorder.dart';

/// [EegRecordingService] for headsets whose SDK has no recording of its own
/// (Muse, OpenBCI, the simulator…). Wraps [EegSessionRecorder]: 1 s
/// band-power snapshots and events go to Hive; markers are events with
/// `type: marker`.
///
/// Export produces CSV text ([EegExportResult.inlineCsv]) rather than files:
/// this package has no dart:io on web, and the host knows where its
/// documents folder is.
class LocalEegRecordingService implements EegRecordingService {
  final EegSessionRecorder recorder;

  /// Source of the band powers to snapshot — normally the hub.
  final EegDeviceService source;

  /// Model to stamp on sessions when the source does not say.
  final EegDeviceType Function() deviceTypeOf;

  final _markers = StreamController<EegMarker>.broadcast();
  final _activeChanges = StreamController<EegRecording?>.broadcast();
  EegRecording? _active;
  int _markerSeq = 0;
  bool _disposed = false;

  LocalEegRecordingService({
    required this.source,
    required this.deviceTypeOf,
    EegSessionRecorder? recorder,
  }) : recorder = recorder ?? EegSessionRecorder();

  @override
  EegRecordingBackend get backend => EegRecordingBackend.local;

  @override
  bool get isRecording => _active != null;

  @override
  EegRecording? get activeRecording => _active;

  @override
  Stream<EegMarker> get markerStream => _markers.stream;

  @override
  Stream<EegRecording?> get activeRecordingStream => _activeChanges.stream;

  @override
  bool get canExportToFolder => false;

  static final RegExp _pairedInternalBlockRe = RegExp(
    r'(?:<\s*(?:think(?:ing)?|thought|memory_recall|auto_memory|system_context)\b[^>]*>[\s\S]*?<\s*/\s*(?:think(?:ing)?|thought|memory_recall|auto_memory|system_context)\s*>|\[\s*(BIOCHIP|MEMORY_RECALL|AUTO_MEMORY|SYSTEM_CONTEXT)\s*\](?:(?!\[\s*\1\s*\])[\s\S])*?\[\s*/\s*\1\s*\])',
    caseSensitive: false,
  );
  static final RegExp _standaloneInternalTagRe = RegExp(
    r'(?:\[\s*/?\s*(?:BIOCHIP(?:\s*:[^\]]*)?|MEMORY_RECALL(?:\s*:[^\]]*)?|AUTO_MEMORY(?:\s*:[^\]]*)?|SYSTEM_CONTEXT(?:\s*:[^\]]*)?)\s*\]|<\s*/?\s*(?:think(?:ing)?|thought|memory_recall|auto_memory|system_context)\b[^>]*>)',
    caseSensitive: false,
  );
  static final RegExp _controlOrBidiRe = RegExp(
    r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F-\x9F\u0085\u061C\u200B\u200C\u200E\u200F\u2028-\u202E\u2060-\u2064\u2066-\u2069\uFEFF]',
  );

  static String _cleanField(String raw, {int maxChars = 512}) {
    final stripped = raw
        .replaceAll(_pairedInternalBlockRe, '')
        .replaceAll(_standaloneInternalTagRe, '')
        .replaceAll(_controlOrBidiRe, '')
        .trim();
    if (stripped.length <= maxChars) return stripped;
    var end = maxChars;
    final cu = stripped.codeUnitAt(end - 1);
    if (cu >= 0xD800 && cu <= 0xDBFF) end--;
    return stripped.substring(0, end);
  }

  @override
  Future<EegRecording> startRecording({
    required String title,
    String? description,
    String? subject,
    List<String> tags = const [],
  }) async {
    if (_active != null) await stopRecording();

    final cleanTitle = _cleanField(title, maxChars: 256);
    final cleanDesc =
        description == null ? null : _cleanField(description, maxChars: 2048);
    final cleanSubject =
        subject == null ? null : _cleanField(subject, maxChars: 256);
    final cleanTags = tags
        .take(64)
        .map((t) => _cleanField(t, maxChars: 64))
        .where((t) => t.isNotEmpty)
        .toList(growable: false);

    final session = await recorder.startSession(
      deviceType: source.connectedDevice?.type ?? deviceTypeOf(),
      deviceService: source,
    );
    recorder.addEvent('recordingStarted', data: {
      'title': cleanTitle,
      'description': ?cleanDesc,
      'subject': ?cleanSubject,
      if (cleanTags.isNotEmpty) 'tags': cleanTags,
    });
    _markerSeq = 0;
    _active = EegRecording(
      id: session.id,
      title: cleanTitle,
      description: cleanDesc,
      subject: cleanSubject,
      tags: cleanTags,
      startedAt: session.startTime,
      backend: EegRecordingBackend.local,
      sampleRate: source.connectedDevice?.sampleRate,
    );
    if (!_activeChanges.isClosed) {
      _activeChanges.add(_active);
    }
    return _active!;
  }

  @override
  Future<EegRecording?> stopRecording() async {
    final active = _active;
    if (active == null) return null;
    final session = await recorder.stopSession();
    _active = null;
    if (!_activeChanges.isClosed) {
      _activeChanges.add(null);
    }
    return active.copyWith(
      endedAt: session?.endTime ?? DateTime.now(),
      metadata: {'sampleCount': session?.sampleCount ?? 0},
    );
  }

  @override
  Future<EegMarker> addMarker({
    required String label,
    Object value = 1,
    DateTime? at,
    String port = 'Software',
    Map<String, dynamic> extras = const {},
  }) async {
    final active = _active;
    if (active == null) {
      throw const EegException(
        'Inicia una grabación antes de marcar un evento',
      );
    }
    final cleanLabel = _cleanField(label, maxChars: 256);
    final cleanPort = _cleanField(port, maxChars: 128);
    final marker = EegMarker(
      id: '${active.id}-m${++_markerSeq}',
      label: cleanLabel,
      value: value,
      at: at ?? DateTime.now(),
      port: cleanPort,
      extras: extras,
      recordingId: active.id,
    );
    recorder.addEvent('marker', data: {
      'markerId': marker.id,
      'label': cleanLabel,
      'value': value,
      'at': marker.at.toIso8601String(),
      'port': cleanPort,
      if (extras.isNotEmpty) 'extras': extras,
    });
    _active = active.copyWith(markerCount: active.markerCount + 1);
    if (!_markers.isClosed) {
      _markers.add(marker);
    }
    return marker;
  }

  @override
  Future<List<EegRecording>> listRecordings({int limit = 50}) async {
    if (!limit.toDouble().isFinite || limit <= 0) {
      return const <EegRecording>[];
    }
    final safeLimit = limit > 500 ? 500 : limit;
    final sessions = await recorder.getSessions();
    return [
      for (final s in sessions.take(safeLimit)) _fromSession(s),
    ];
  }

  @override
  Future<EegExportResult> exportRecordings({
    required List<String> ids,
    required String folder,
    EegExportFormat format = EegExportFormat.csv,
    Set<EegExportStream> streams = const {
      EegExportStream.eeg,
      EegExportStream.bandPower,
      EegExportStream.performanceMetrics,
    },
  }) async {
    if (format != EegExportFormat.csv) {
      return EegExportResult(
        exported: const [],
        failed: {for (final id in ids) id: 'El backend local sólo exporta CSV'},
        folder: folder,
        format: format,
      );
    }
    await recorder.init();
    final csv = <String, String>{};
    final failed = <String, String>{};
    for (final id in ids) {
      final text = recorder.exportCsv(id);
      if (text.isEmpty) {
        failed[id] = 'Sin datos para esta grabación';
      } else {
        csv[id] = text;
      }
    }
    return EegExportResult(
      exported: csv.keys.toList(),
      failed: failed,
      folder: folder,
      format: format,
      inlineCsv: csv,
    );
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await stopRecording();
    await _markers.close();
    await _activeChanges.close();
  }

  EegRecording _fromSession(EegSession s) {
    Map<String, dynamic>? started;
    var markers = 0;
    for (final e in s.events) {
      if (e['type'] == 'recordingStarted') started = e;
      if (e['type'] == 'marker') markers++;
    }
    return EegRecording(
      id: s.id,
      title: started?['title'] as String? ?? 'Sesión ${s.deviceType.displayName}',
      description: started?['description'] as String?,
      subject: started?['subject'] as String?,
      tags: (started?['tags'] as List?)?.cast<String>() ?? const [],
      startedAt: s.startTime,
      endedAt: s.endTime,
      backend: EegRecordingBackend.local,
      markerCount: markers,
      metadata: {'deviceType': s.deviceType.name, 'sampleCount': s.sampleCount},
    );
  }
}

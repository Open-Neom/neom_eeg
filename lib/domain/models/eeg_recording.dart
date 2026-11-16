/// Where a recording lives.
enum EegRecordingBackend {
  /// Kept by the vendor SDK (Cortex records: visible in EmotivPRO, exportable
  /// to EDF/CSV with markers embedded in the EEG timeline).
  native,

  /// Kept by neom_eeg in Hive: 1 s band-power snapshots plus events. What
  /// every non-Emotiv headset gets.
  local,
}

enum EegExportFormat {
  csv('CSV', 'csv'),
  edf('EDF', 'edf'),
  edfPlus('EDFPLUS', 'edf'),
  bdfPlus('BDFPLUS', 'bdf');

  /// Value the Cortex `exportRecord` call expects.
  final String cortexName;
  final String extension;

  const EegExportFormat(this.cortexName, this.extension);
}

/// Which data an export should contain (Cortex `streamTypes`).
enum EegExportStream {
  eeg('EEG'),
  motion('MOTION'),
  performanceMetrics('PM'),
  bandPower('BP');

  final String cortexName;
  const EegExportStream(this.cortexName);
}

class EegRecording {
  final String id;
  final String title;
  final String? description;
  final String? subject;
  final List<String> tags;
  final DateTime startedAt;
  final DateTime? endedAt;
  final EegRecordingBackend backend;
  final int? sampleRate;
  final int markerCount;

  /// Vendor-specific fields kept verbatim (Cortex `uuid`, `exportIds`…).
  final Map<String, dynamic> metadata;

  const EegRecording({
    required this.id,
    required this.title,
    this.description,
    this.subject,
    this.tags = const [],
    required this.startedAt,
    this.endedAt,
    required this.backend,
    this.sampleRate,
    this.markerCount = 0,
    this.metadata = const {},
  });

  bool get isActive => endedAt == null;

  Duration? get duration => endedAt?.difference(startedAt);

  EegRecording copyWith({
    DateTime? endedAt,
    int? markerCount,
    Map<String, dynamic>? metadata,
  }) =>
      EegRecording(
        id: id,
        title: title,
        description: description,
        subject: subject,
        tags: tags,
        startedAt: startedAt,
        endedAt: endedAt ?? this.endedAt,
        backend: backend,
        sampleRate: sampleRate,
        markerCount: markerCount ?? this.markerCount,
        metadata: metadata ?? this.metadata,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'description': description,
        'subject': subject,
        'tags': tags,
        'startedAt': startedAt.toIso8601String(),
        'endedAt': endedAt?.toIso8601String(),
        'backend': backend.name,
        'sampleRate': sampleRate,
        'markerCount': markerCount,
        'metadata': metadata,
      };

  static Map<String, dynamic> _sanitizeDynamicMap(Object? raw) {
    if (raw is! Map) return const {};
    final out = <String, dynamic>{};
    for (final entry in raw.entries.take(128)) {
      final k = entry.key?.toString() ?? '';
      final lower = k.toLowerCase();
      if (k.isEmpty ||
          lower == '__proto__' ||
          lower == 'constructor' ||
          lower == 'prototype') {
        continue;
      }
      out[k] = entry.value;
    }
    return out;
  }

  static int? _finiteIntOrNull(Object? raw) {
    if (raw is num && raw.isFinite) return raw.toInt();
    return null;
  }

  factory EegRecording.fromJson(Map<String, dynamic> json) {
    final rawBackend = json['backend']?.toString() ?? '';
    final rawStarted = json['startedAt']?.toString() ?? '';
    final rawEnded = json['endedAt'];
    final markerCount = _finiteIntOrNull(json['markerCount']) ?? 0;
    return EegRecording(
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      description: json['description'] as String?,
      subject: json['subject'] as String?,
      tags: (json['tags'] as List?)
              ?.take(64)
              .whereType<String>()
              .toList() ??
          const [],
      startedAt: DateTime.tryParse(rawStarted) ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      endedAt: rawEnded is String ? DateTime.tryParse(rawEnded) : null,
      backend: EegRecordingBackend.values.firstWhere(
        (b) => b.name == rawBackend,
        orElse: () => EegRecordingBackend.local,
      ),
      sampleRate: _finiteIntOrNull(json['sampleRate']),
      markerCount: markerCount < 0 ? 0 : markerCount,
      metadata: _sanitizeDynamicMap(json['metadata']),
    );
  }
}

/// An event pinned to the EEG timeline — an aura, a symptom, a stimulus,
/// the start of a breathing exercise.
class EegMarker {
  final String id;
  final String label;

  /// Free-form value; Cortex accepts a string or a non-negative integer.
  final Object value;
  final DateTime at;

  /// Origin of the marker (`Software` by default in Cortex).
  final String port;
  final Map<String, dynamic> extras;
  final String? recordingId;

  const EegMarker({
    required this.id,
    required this.label,
    required this.value,
    required this.at,
    this.port = 'Software',
    this.extras = const {},
    this.recordingId,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'value': value,
        'at': at.toIso8601String(),
        'port': port,
        'extras': extras,
        'recordingId': recordingId,
      };

  factory EegMarker.fromJson(Map<String, dynamic> json) {
    final rawAt = json['at']?.toString() ?? '';
    final rawVal = json['value'];
    final Object safeVal = (rawVal is num && !rawVal.isFinite)
        ? 1
        : (rawVal as Object? ?? 1);
    return EegMarker(
      id: json['id']?.toString() ?? '',
      label: json['label']?.toString() ?? '',
      value: safeVal,
      at: DateTime.tryParse(rawAt) ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      port: json['port']?.toString() ?? 'Software',
      extras: EegRecording._sanitizeDynamicMap(json['extras']),
      recordingId: json['recordingId'] as String?,
    );
  }
}

class EegExportResult {
  final List<String> exported;

  /// Recording id → reason.
  final Map<String, String> failed;
  final String folder;
  final EegExportFormat format;

  /// For the local backend, which cannot write files on every platform:
  /// recording id → CSV text the host can save wherever it likes.
  final Map<String, String> inlineCsv;

  const EegExportResult({
    required this.exported,
    this.failed = const {},
    required this.folder,
    required this.format,
    this.inlineCsv = const {},
  });

  bool get isComplete => failed.isEmpty;
}

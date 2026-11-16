import '../enums/eeg_device_type.dart';

class EegSession {
  final String id;
  final EegDeviceType deviceType;
  final DateTime startTime;
  final DateTime? endTime;
  final int sampleCount;
  final List<Map<String, dynamic>> events;

  const EegSession({
    required this.id,
    required this.deviceType,
    required this.startTime,
    this.endTime,
    this.sampleCount = 0,
    this.events = const [],
  });

  Duration? get duration => endTime?.difference(startTime);

  bool get isActive => endTime == null;

  Map<String, dynamic> toJson() => {
        'id': id,
        'deviceType': deviceType.name,
        'startTime': startTime.toIso8601String(),
        'endTime': endTime?.toIso8601String(),
        'sampleCount': sampleCount,
        'events': events,
      };

  static Map<String, dynamic> _sanitizeMap(Map raw) {
    final out = <String, dynamic>{};
    for (final entry in raw.entries.take(64)) {
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

  factory EegSession.fromJson(Map<String, dynamic> json) {
    final rawDevice = json['deviceType']?.toString() ?? '';
    final rawSampleCount = json['sampleCount'];
    final safeSamples = (rawSampleCount is num && rawSampleCount.isFinite)
        ? (rawSampleCount.toInt() < 0 ? 0 : rawSampleCount.toInt())
        : 0;
    final rawStart = json['startTime']?.toString() ?? '';
    final rawEnd = json['endTime'];
    return EegSession(
      id: json['id']?.toString() ?? '',
      deviceType: EegDeviceType.values.firstWhere(
        (d) => d.name == rawDevice,
        orElse: () => EegDeviceType.simulated,
      ),
      startTime: DateTime.tryParse(rawStart) ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      endTime: rawEnd is String ? DateTime.tryParse(rawEnd) : null,
      sampleCount: safeSamples,
      events: (json['events'] as List?)
              ?.take(10000)
              .whereType<Map>()
              .map(_sanitizeMap)
              .toList() ??
          const [],
    );
  }
}

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

  factory EegSession.fromJson(Map<String, dynamic> json) => EegSession(
        id: json['id'] as String,
        deviceType: EegDeviceType.values.byName(json['deviceType'] as String),
        startTime: DateTime.parse(json['startTime'] as String),
        endTime: json['endTime'] != null
            ? DateTime.parse(json['endTime'] as String)
            : null,
        sampleCount: json['sampleCount'] as int? ?? 0,
        events: (json['events'] as List?)
                ?.map((e) => Map<String, dynamic>.from(e as Map))
                .toList() ??
            [],
      );
}

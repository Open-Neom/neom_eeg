/// Slow-changing health of a connected headset: battery, link quality and
/// per-electrode contact quality.
///
/// Emitted by drivers on their own cadence (Cortex `dev`/`eq` streams push
/// roughly twice a second; Muse telemetry every ~10 s). Every value is
/// normalised to `0..1` regardless of the vendor's native scale.
class EegDeviceStatus {
  /// Battery charge, `0..1`. Null when the device does not report it.
  final double? battery;

  /// Wireless link strength, `0..1`. Null when unknown.
  final double? wirelessSignal;

  /// Contact quality per electrode label, `0..1` (1 = good contact).
  final Map<String, double> contactQuality;

  /// Aggregate signal quality, `0..1`. Null when unknown.
  final double? overallQuality;

  final DateTime timestamp;

  const EegDeviceStatus({
    this.battery,
    this.wirelessSignal,
    this.contactQuality = const {},
    this.overallQuality,
    required this.timestamp,
  });

  /// Electrodes whose contact is poor (below [threshold]).
  List<String> poorContacts({double threshold = 0.5}) => [
        for (final e in contactQuality.entries)
          if (e.value < threshold) e.key,
      ];

  EegDeviceStatus copyWith({
    double? battery,
    double? wirelessSignal,
    Map<String, double>? contactQuality,
    double? overallQuality,
    DateTime? timestamp,
  }) =>
      EegDeviceStatus(
        battery: battery ?? this.battery,
        wirelessSignal: wirelessSignal ?? this.wirelessSignal,
        contactQuality: contactQuality ?? this.contactQuality,
        overallQuality: overallQuality ?? this.overallQuality,
        timestamp: timestamp ?? this.timestamp,
      );

  Map<String, dynamic> toJson() => {
        'battery': battery,
        'wirelessSignal': wirelessSignal,
        'contactQuality': contactQuality,
        'overallQuality': overallQuality,
        'timestamp': timestamp.toIso8601String(),
      };

  factory EegDeviceStatus.fromJson(Map<String, dynamic> json) =>
      EegDeviceStatus(
        battery: (json['battery'] as num?)?.toDouble(),
        wirelessSignal: (json['wirelessSignal'] as num?)?.toDouble(),
        contactQuality: Map<String, double>.from(
          (json['contactQuality'] as Map?) ?? const {},
        ),
        overallQuality: (json['overallQuality'] as num?)?.toDouble(),
        timestamp: DateTime.parse(json['timestamp'] as String),
      );
}

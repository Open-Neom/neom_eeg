class EegSample {
  final DateTime timestamp;
  final Map<String, double> channels;
  final Map<String, double> quality;

  const EegSample({
    required this.timestamp,
    required this.channels,
    required this.quality,
  });

  Map<String, dynamic> toJson() => {
        'timestamp': timestamp.toIso8601String(),
        'channels': channels,
        'quality': quality,
      };

  factory EegSample.fromJson(Map<String, dynamic> json) => EegSample(
        timestamp: DateTime.parse(json['timestamp'] as String),
        channels: Map<String, double>.from(json['channels'] as Map),
        quality: Map<String, double>.from(json['quality'] as Map),
      );
}

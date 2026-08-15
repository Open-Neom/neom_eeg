class EegCalibration {
  final Map<String, Map<String, double>> baselines;
  final double noiseFloor;
  final double artifactThreshold;
  final DateTime calibratedAt;

  const EegCalibration({
    required this.baselines,
    required this.noiseFloor,
    required this.artifactThreshold,
    required this.calibratedAt,
  });

  Map<String, dynamic> toJson() => {
        'baselines': baselines.map(
          (band, channels) => MapEntry(band, channels),
        ),
        'noiseFloor': noiseFloor,
        'artifactThreshold': artifactThreshold,
        'calibratedAt': calibratedAt.toIso8601String(),
      };

  factory EegCalibration.fromJson(Map<String, dynamic> json) => EegCalibration(
        baselines: (json['baselines'] as Map<String, dynamic>).map(
          (band, channels) => MapEntry(
            band,
            Map<String, double>.from(channels as Map),
          ),
        ),
        noiseFloor: (json['noiseFloor'] as num).toDouble(),
        artifactThreshold: (json['artifactThreshold'] as num).toDouble(),
        calibratedAt: DateTime.parse(json['calibratedAt'] as String),
      );
}

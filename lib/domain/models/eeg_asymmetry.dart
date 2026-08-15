class EegAsymmetry {
  final String band;
  final String leftChannel;
  final String rightChannel;
  final double leftPower;
  final double rightPower;
  final DateTime timestamp;

  const EegAsymmetry({
    required this.band,
    required this.leftChannel,
    required this.rightChannel,
    required this.leftPower,
    required this.rightPower,
    required this.timestamp,
  });

  double get ratio => rightPower != 0 ? leftPower / rightPower : double.infinity;

  double get asymmetryIndex {
    final sum = leftPower + rightPower;
    return sum != 0 ? (leftPower - rightPower) / sum : 0.0;
  }

  bool get isSignificant => asymmetryIndex.abs() > 0.2;

  Map<String, dynamic> toJson() => {
        'band': band,
        'leftChannel': leftChannel,
        'rightChannel': rightChannel,
        'leftPower': leftPower,
        'rightPower': rightPower,
        'timestamp': timestamp.toIso8601String(),
      };

  factory EegAsymmetry.fromJson(Map<String, dynamic> json) => EegAsymmetry(
        band: json['band'] as String,
        leftChannel: json['leftChannel'] as String,
        rightChannel: json['rightChannel'] as String,
        leftPower: (json['leftPower'] as num).toDouble(),
        rightPower: (json['rightPower'] as num).toDouble(),
        timestamp: DateTime.parse(json['timestamp'] as String),
      );
}

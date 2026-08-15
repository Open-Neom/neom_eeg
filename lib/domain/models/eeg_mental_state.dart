class EegMentalState {
  final double engagement;
  final double relaxation;
  final double stress;
  final double focus;
  final double excitement;
  final DateTime timestamp;

  const EegMentalState({
    required this.engagement,
    required this.relaxation,
    required this.stress,
    required this.focus,
    required this.excitement,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
        'engagement': engagement,
        'relaxation': relaxation,
        'stress': stress,
        'focus': focus,
        'excitement': excitement,
        'timestamp': timestamp.toIso8601String(),
      };

  factory EegMentalState.fromJson(Map<String, dynamic> json) => EegMentalState(
        engagement: (json['engagement'] as num).toDouble(),
        relaxation: (json['relaxation'] as num).toDouble(),
        stress: (json['stress'] as num).toDouble(),
        focus: (json['focus'] as num).toDouble(),
        excitement: (json['excitement'] as num).toDouble(),
        timestamp: DateTime.parse(json['timestamp'] as String),
      );
}

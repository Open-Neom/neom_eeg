class EegBandPower {
  final String channel;
  final double delta;
  final double theta;
  final double alpha;
  final double betaLow;
  final double betaHigh;
  final double gamma;
  final DateTime timestamp;

  const EegBandPower({
    required this.channel,
    required this.delta,
    required this.theta,
    required this.alpha,
    required this.betaLow,
    required this.betaHigh,
    required this.gamma,
    required this.timestamp,
  });

  double get totalPower => delta + theta + alpha + betaLow + betaHigh + gamma;

  String get dominantBand {
    final bands = {
      'delta': delta,
      'theta': theta,
      'alpha': alpha,
      'betaLow': betaLow,
      'betaHigh': betaHigh,
      'gamma': gamma,
    };
    return bands.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
  }

  Map<String, dynamic> toJson() => {
        'channel': channel,
        'delta': delta,
        'theta': theta,
        'alpha': alpha,
        'betaLow': betaLow,
        'betaHigh': betaHigh,
        'gamma': gamma,
        'timestamp': timestamp.toIso8601String(),
      };

  factory EegBandPower.fromJson(Map<String, dynamic> json) => EegBandPower(
        channel: json['channel'] as String,
        delta: (json['delta'] as num).toDouble(),
        theta: (json['theta'] as num).toDouble(),
        alpha: (json['alpha'] as num).toDouble(),
        betaLow: (json['betaLow'] as num).toDouble(),
        betaHigh: (json['betaHigh'] as num).toDouble(),
        gamma: (json['gamma'] as num).toDouble(),
        timestamp: DateTime.parse(json['timestamp'] as String),
      );
}

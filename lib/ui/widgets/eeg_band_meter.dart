import 'package:flutter/material.dart';

import '../../domain/models/eeg_band_power.dart';

/// Displays 5 animated horizontal bars for each EEG frequency band.
///
/// Colors: delta (purple), theta (indigo), alpha (green),
/// beta (amber), gamma (red). Height proportional to power.
class EegBandMeter extends StatelessWidget {
  final List<EegBandPower> bandPowers;

  const EegBandMeter({super.key, required this.bandPowers});

  @override
  Widget build(BuildContext context) {
    // Average across channels
    final avg = _averagePowers();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Bandas EEG',
          style: TextStyle(
            color: Colors.white70,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        _BandBar(
          label: 'δ Delta',
          range: '0.5-4 Hz',
          value: avg['delta']!,
          color: const Color(0xFF9C27B0),
          maxValue: _maxPower(avg),
        ),
        _BandBar(
          label: 'θ Theta',
          range: '4-8 Hz',
          value: avg['theta']!,
          color: const Color(0xFF3F51B5),
          maxValue: _maxPower(avg),
        ),
        _BandBar(
          label: 'α Alpha',
          range: '8-13 Hz',
          value: avg['alpha']!,
          color: const Color(0xFF4CAF50),
          maxValue: _maxPower(avg),
        ),
        _BandBar(
          label: 'β Beta',
          range: '13-30 Hz',
          value: avg['beta']!,
          color: const Color(0xFFFFC107),
          maxValue: _maxPower(avg),
        ),
        _BandBar(
          label: 'γ Gamma',
          range: '30-50 Hz',
          value: avg['gamma']!,
          color: const Color(0xFFF44336),
          maxValue: _maxPower(avg),
        ),
      ],
    );
  }

  Map<String, double> _averagePowers() {
    if (bandPowers.isEmpty) {
      return {
        'delta': 0,
        'theta': 0,
        'alpha': 0,
        'beta': 0,
        'gamma': 0,
      };
    }

    final n = bandPowers.length;
    return {
      'delta': bandPowers.fold(0.0, (s, b) => s + b.delta) / n,
      'theta': bandPowers.fold(0.0, (s, b) => s + b.theta) / n,
      'alpha': bandPowers.fold(0.0, (s, b) => s + b.alpha) / n,
      'beta':
          bandPowers.fold(0.0, (s, b) => s + b.betaLow + b.betaHigh) / n,
      'gamma': bandPowers.fold(0.0, (s, b) => s + b.gamma) / n,
    };
  }

  double _maxPower(Map<String, double> avg) {
    final values = avg.values;
    return values.isEmpty ? 1.0 : values.reduce((a, b) => a > b ? a : b).clamp(0.1, double.infinity);
  }
}

class _BandBar extends StatelessWidget {
  final String label;
  final String range;
  final double value;
  final Color color;
  final double maxValue;

  const _BandBar({
    required this.label,
    required this.range,
    required this.value,
    required this.color,
    required this.maxValue,
  });

  @override
  Widget build(BuildContext context) {
    final fraction = maxValue > 0 ? (value / maxValue).clamp(0.0, 1.0) : 0.0;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 80,
                child: Text(
                  label,
                  style: TextStyle(color: color, fontSize: 11),
                ),
              ),
              Expanded(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  height: 14,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: fraction,
                    child: Container(
                      decoration: BoxDecoration(
                        color: color,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              SizedBox(
                width: 44,
                child: Text(
                  value.toStringAsFixed(1),
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 10,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 80),
            child: Text(
              range,
              style: const TextStyle(color: Colors.white24, fontSize: 9),
            ),
          ),
        ],
      ),
    );
  }
}

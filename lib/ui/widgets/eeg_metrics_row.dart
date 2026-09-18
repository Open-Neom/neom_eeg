import 'package:flutter/material.dart';

import '../../domain/models/eeg_mental_state.dart';

/// The five cognitive metrics as compact bars. Works for Cortex's native
/// detections and for the hub's estimated metrics alike; [estimated] only
/// changes the caption so the user knows which one they are looking at.
class EegMetricsRow extends StatelessWidget {
  final EegMentalState? state;
  final bool estimated;
  final bool compact;

  const EegMetricsRow({
    super.key,
    required this.state,
    this.estimated = false,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final s = state;
    final metrics = <(String, double?, Color)>[
      ('Enfoque', s?.focus, const Color(0xFF64B5F6)),
      ('Relajación', s?.relaxation, const Color(0xFF4DB6AC)),
      ('Engagement', s?.engagement, const Color(0xFFBA68C8)),
      ('Excitación', s?.excitement, const Color(0xFFFFB74D)),
      ('Estrés', s?.stress, const Color(0xFFE57373)),
    ];

    return Container(
      padding: EdgeInsets.all(compact ? 8 : 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A2E),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.psychology_alt, size: 14, color: Colors.white38),
              const SizedBox(width: 6),
              const Expanded(
                child: Text(
                  'ESTADO MENTAL',
                  style: TextStyle(
                    color: Colors.white38,
                    fontSize: 10,
                    letterSpacing: 1.5,
                  ),
                ),
              ),
              Text(
                s == null
                    ? 'esperando…'
                    : estimated
                        ? 'estimado de bandas'
                        : 'detección del headset',
                style: const TextStyle(color: Colors.white38, fontSize: 10),
              ),
            ],
          ),
          SizedBox(height: compact ? 6 : 10),
          for (final (label, value, color) in metrics) ...[
            _MetricBar(
              label: label,
              value: value,
              color: color,
              compact: compact,
            ),
            SizedBox(height: compact ? 4 : 6),
          ],
        ],
      ),
    );
  }
}

class _MetricBar extends StatelessWidget {
  final String label;
  final double? value;
  final Color color;
  final bool compact;

  const _MetricBar({
    required this.label,
    required this.value,
    required this.color,
    required this.compact,
  });

  @override
  Widget build(BuildContext context) {
    final v = (value ?? 0).clamp(0.0, 1.0);
    return Row(
      children: [
        SizedBox(
          width: compact ? 68 : 84,
          child: Text(
            label,
            style: TextStyle(
              color: Colors.white70,
              fontSize: compact ? 10 : 11,
            ),
          ),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: value == null ? 0 : v,
              minHeight: compact ? 5 : 7,
              backgroundColor: Colors.white10,
              valueColor: AlwaysStoppedAnimation(color),
            ),
          ),
        ),
        SizedBox(
          width: 38,
          child: Text(
            value == null ? '—' : '${(v * 100).round()}%',
            textAlign: TextAlign.right,
            style: TextStyle(
              color: Colors.white54,
              fontSize: compact ? 10 : 11,
              fontFamily: 'monospace',
            ),
          ),
        ),
      ],
    );
  }
}

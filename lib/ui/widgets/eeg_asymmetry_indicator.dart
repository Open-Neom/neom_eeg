import 'package:flutter/material.dart';

import '../../domain/models/eeg_asymmetry.dart';

/// Horizontal gauge showing hemispheric asymmetry.
///
/// Left (T7) ← center → Right (T8). Needle position maps
/// asymmetryIndex to gauge width. Color: green (balanced),
/// yellow (moderate), red (significant — epilepsy alert zone).
class EegAsymmetryIndicator extends StatelessWidget {
  final EegAsymmetry asymmetry;

  const EegAsymmetryIndicator({super.key, required this.asymmetry});

  @override
  Widget build(BuildContext context) {
    final index = asymmetry.asymmetryIndex;
    final absIndex = index.abs();

    // Color based on asymmetry magnitude
    final Color indicatorColor;
    final String statusText;
    if (absIndex < 0.1) {
      indicatorColor = Colors.green;
      statusText = 'Balanceado';
    } else if (absIndex < 0.2) {
      indicatorColor = Colors.amber;
      statusText = 'Moderado';
    } else {
      indicatorColor = Colors.redAccent;
      statusText = 'Significativo';
    }

    // Needle position: -1..+1 → 0..1
    final needlePos = ((index + 1.0) / 2.0).clamp(0.0, 1.0);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A2E),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Asimetría ${asymmetry.band}',
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: indicatorColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  statusText,
                  style: TextStyle(
                    color: indicatorColor,
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),

          // Gauge
          SizedBox(
            height: 32,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth;

                return Stack(
                  alignment: Alignment.center,
                  children: [
                    // Track background
                    Container(
                      height: 8,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(4),
                        gradient: const LinearGradient(
                          colors: [
                            Color(0xFF64B5F6), // Left hemisphere
                            Color(0xFF2E2E3A), // Center
                            Color(0xFFFF8A65), // Right hemisphere
                          ],
                        ),
                      ),
                    ),
                    // Center mark
                    Container(
                      width: 2,
                      height: 16,
                      color: Colors.white24,
                    ),
                    // Needle
                    Positioned(
                      left: needlePos * (width - 12),
                      child: Container(
                        width: 12,
                        height: 24,
                        decoration: BoxDecoration(
                          color: indicatorColor,
                          borderRadius: BorderRadius.circular(6),
                          boxShadow: [
                            BoxShadow(
                              color: indicatorColor.withValues(alpha: 0.4),
                              blurRadius: 6,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          const SizedBox(height: 6),

          // Labels
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'L (${asymmetry.leftChannel})',
                style: const TextStyle(
                  color: Color(0xFF64B5F6),
                  fontSize: 10,
                ),
              ),
              Text(
                asymmetry.ratio.isFinite
                    ? asymmetry.ratio.toStringAsFixed(2)
                    : '∞',
                style: TextStyle(
                  color: indicatorColor,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  fontFamily: 'monospace',
                ),
              ),
              Text(
                'R (${asymmetry.rightChannel})',
                style: const TextStyle(
                  color: Color(0xFFFF8A65),
                  fontSize: 10,
                ),
              ),
            ],
          ),

          // Alert for significant asymmetry
          if (absIndex > 0.2) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: Colors.redAccent.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: Colors.redAccent.withValues(alpha: 0.3),
                ),
              ),
              child: const Row(
                children: [
                  Icon(Icons.warning_amber, color: Colors.redAccent, size: 14),
                  SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Asimetría significativa detectada',
                      style: TextStyle(
                        color: Colors.redAccent,
                        fontSize: 10,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

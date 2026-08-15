import 'package:flutter/material.dart';

import '../../domain/models/eeg_band_power.dart';
import '../../domain/models/eeg_channel_info.dart';

/// Scalp topography map showing channel-level band power as colored dots.
///
/// Renders an oval scalp outline with a nose indicator, and places
/// each channel at its (positionX, positionY) with intensity-based
/// coloring (blue=low → red=high).
class EegTopography extends StatelessWidget {
  final List<EegBandPower> perChannel;
  final List<EegChannelInfo> channels;
  final String selectedBand;

  const EegTopography({
    super.key,
    required this.perChannel,
    required this.channels,
    this.selectedBand = 'alpha',
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 180,
      child: CustomPaint(
        painter: _TopographyPainter(
          perChannel: perChannel,
          channels: channels,
          selectedBand: selectedBand,
        ),
      ),
    );
  }
}

class _TopographyPainter extends CustomPainter {
  final List<EegBandPower> perChannel;
  final List<EegChannelInfo> channels;
  final String selectedBand;

  _TopographyPainter({
    required this.perChannel,
    required this.channels,
    required this.selectedBand,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final rx = size.width * 0.38;
    final ry = size.height * 0.42;

    // Draw scalp outline
    final scalpPaint = Paint()
      ..color = Colors.white24
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawOval(
      Rect.fromCenter(center: Offset(cx, cy), width: rx * 2, height: ry * 2),
      scalpPaint,
    );

    // Draw nose indicator
    final nosePath = Path()
      ..moveTo(cx - 8, cy - ry - 2)
      ..lineTo(cx, cy - ry - 14)
      ..lineTo(cx + 8, cy - ry - 2);
    canvas.drawPath(nosePath, scalpPaint);

    // Build power map by channel name
    final powerMap = <String, double>{};
    double minPower = double.infinity;
    double maxPower = double.negativeInfinity;

    for (final bp in perChannel) {
      final value = _getBandValue(bp);
      powerMap[bp.channel] = value;
      if (value < minPower) minPower = value;
      if (value > maxPower) maxPower = value;
    }

    final range = maxPower - minPower;

    // Draw channel dots
    for (final ch in channels) {
      final x = cx + (ch.positionX - 0.5) * 2 * rx;
      final y = cy + (ch.positionY - 0.5) * 2 * ry;

      final power = powerMap[ch.name] ?? 0.0;
      final normalized =
          range > 0 ? ((power - minPower) / range).clamp(0.0, 1.0) : 0.5;

      // Blue (low) → Green (mid) → Red (high)
      final color = Color.lerp(
        Color.lerp(Colors.blue, Colors.green, normalized * 2)!,
        Color.lerp(Colors.green, Colors.red, (normalized - 0.5) * 2)!,
        normalized,
      )!;

      // Dot
      final dotPaint = Paint()..color = color;
      canvas.drawCircle(Offset(x, y), 8, dotPaint);

      // Glow
      final glowPaint = Paint()
        ..color = color.withValues(alpha: 0.25)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);
      canvas.drawCircle(Offset(x, y), 14, glowPaint);

      // Label
      final textSpan = TextSpan(
        text: ch.name,
        style: const TextStyle(
          color: Colors.white70,
          fontSize: 9,
          fontWeight: FontWeight.w500,
        ),
      );
      final tp = TextPainter(
        text: textSpan,
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(x - tp.width / 2, y + 10));
    }
  }

  double _getBandValue(EegBandPower bp) {
    switch (selectedBand) {
      case 'delta':
        return bp.delta;
      case 'theta':
        return bp.theta;
      case 'alpha':
        return bp.alpha;
      case 'betaLow':
        return bp.betaLow;
      case 'betaHigh':
        return bp.betaHigh;
      case 'gamma':
        return bp.gamma;
      default:
        return bp.alpha;
    }
  }

  @override
  bool shouldRepaint(_TopographyPainter oldDelegate) => true;
}

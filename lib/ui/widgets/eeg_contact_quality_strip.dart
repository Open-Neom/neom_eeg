import 'package:flutter/material.dart';

import '../../domain/models/eeg_channel_info.dart';
import '../../domain/models/eeg_device_status.dart';

/// One chip per electrode with its contact quality, in the device's own
/// channel order. Electrodes below [poorThreshold] are drawn red — that is
/// how a lost sensor tip shows up.
class EegContactQualityStrip extends StatelessWidget {
  final List<EegChannelInfo> channels;
  final EegDeviceStatus? status;
  final double poorThreshold;
  final bool compact;

  const EegContactQualityStrip({
    super.key,
    required this.channels,
    required this.status,
    this.poorThreshold = 0.25,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final quality = status?.contactQuality ?? const <String, double>{};
    final poor = channels.where((c) => (quality[c.name] ?? 1) < poorThreshold);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Icon(Icons.sensors, size: 14, color: Colors.white38),
            const SizedBox(width: 6),
            const Expanded(
              child: Text(
                'CONTACTO',
                style: TextStyle(
                  color: Colors.white38,
                  fontSize: 10,
                  letterSpacing: 1.5,
                ),
              ),
            ),
            if (status?.overallQuality != null)
              Text(
                '${(status!.overallQuality! * 100).round()}%',
                style: const TextStyle(color: Colors.white54, fontSize: 11),
              ),
          ],
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final ch in channels)
              _ContactChip(
                label: ch.name,
                quality: quality[ch.name],
                poor: (quality[ch.name] ?? 1) < poorThreshold,
                compact: compact,
              ),
          ],
        ),
        if (poor.isNotEmpty && !compact)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Sin contacto: ${poor.map((c) => c.name).join(', ')} · '
              'excluidos del análisis de bandas',
              style: const TextStyle(color: Colors.redAccent, fontSize: 11),
            ),
          ),
      ],
    );
  }
}

class _ContactChip extends StatelessWidget {
  final String label;
  final double? quality;
  final bool poor;
  final bool compact;

  const _ContactChip({
    required this.label,
    required this.quality,
    required this.poor,
    required this.compact,
  });

  Color get _color {
    final q = quality;
    if (q == null) return Colors.white24;
    if (poor) return Colors.redAccent;
    if (q < 0.5) return Colors.orangeAccent;
    if (q < 0.75) return Colors.amber;
    return Colors.greenAccent;
  }

  @override
  Widget build(BuildContext context) {
    final bars = quality == null ? 0 : (quality! * 4).round().clamp(0, 4);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 6 : 8,
        vertical: compact ? 3 : 5,
      ),
      decoration: BoxDecoration(
        color: _color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: _color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              color: poor ? Colors.redAccent : Colors.white,
              fontSize: compact ? 10 : 12,
              fontWeight: FontWeight.w600,
              decoration: poor ? TextDecoration.lineThrough : null,
            ),
          ),
          const SizedBox(width: 5),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: List.generate(4, (i) {
              return Container(
                width: 3,
                height: 4.0 + i * 2.5,
                margin: const EdgeInsets.symmetric(horizontal: 0.7),
                decoration: BoxDecoration(
                  color: i < bars ? _color : Colors.white12,
                  borderRadius: BorderRadius.circular(1),
                ),
              );
            }),
          ),
        ],
      ),
    );
  }
}

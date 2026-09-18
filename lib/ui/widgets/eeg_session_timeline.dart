import 'package:flutter/material.dart';

import '../../domain/enums/eeg_device_type.dart';
import '../../domain/enums/eeg_vendor.dart';
import '../../domain/models/eeg_session.dart';

/// Timeline list of recorded EEG sessions.
///
/// Each card shows date, duration, device type icon, sample count,
/// and event count badge. Tappable for navigation to detail.
class EegSessionTimeline extends StatelessWidget {
  final List<EegSession> sessions;
  final void Function(EegSession)? onTap;

  const EegSessionTimeline({
    super.key,
    required this.sessions,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    if (sessions.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            'Sin sesiones registradas',
            style: TextStyle(color: Colors.white38, fontSize: 13),
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: sessions.length,
      itemBuilder: (context, index) {
        final session = sessions[index];
        return _SessionCard(
          session: session,
          onTap: onTap != null ? () => onTap!(session) : null,
        );
      },
    );
  }
}

class _SessionCard extends StatelessWidget {
  final EegSession session;
  final VoidCallback? onTap;

  const _SessionCard({required this.session, this.onTap});

  @override
  Widget build(BuildContext context) {
    final duration = session.duration;
    final durationText = duration != null
        ? '${duration.inMinutes}m ${duration.inSeconds % 60}s'
        : 'En curso';

    return Card(
      color: const Color(0xFF1A1A2E),
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              // Device icon
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  _iconForType(session.deviceType),
                  color: const Color(0xFF64B5F6),
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),

              // Session info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _formatDate(session.startTime),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$durationText · ${session.sampleCount} muestras',
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),

              // Event count badge
              if (session.events.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF3F51B5).withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '${session.events.length}',
                    style: const TextStyle(
                      color: Color(0xFF64B5F6),
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),

              // Active indicator
              if (session.isActive)
                Container(
                  width: 8,
                  height: 8,
                  margin: const EdgeInsets.only(left: 8),
                  decoration: const BoxDecoration(
                    color: Colors.green,
                    shape: BoxShape.circle,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  IconData _iconForType(EegDeviceType type) => switch (type.vendor) {
        EegVendor.emotiv => Icons.headset,
        EegVendor.interaxon => Icons.self_improvement,
        EegVendor.neurosky => Icons.psychology,
        EegVendor.brainbit || EegVendor.openbci => Icons.memory,
        EegVendor.simulated => Icons.bug_report,
      };

  String _formatDate(DateTime dt) {
    final months = [
      'Ene', 'Feb', 'Mar', 'Abr', 'May', 'Jun',
      'Jul', 'Ago', 'Sep', 'Oct', 'Nov', 'Dic',
    ];
    return '${dt.day} ${months[dt.month - 1]} ${dt.year} '
        '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}';
  }
}

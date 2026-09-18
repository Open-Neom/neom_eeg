import 'package:flutter/material.dart';
import 'package:sint/sint.dart';

import '../../data/implementations/eeg_session_capture_controller.dart';

/// Proof that the headset is delivering data right now: samples and band
/// frames per second against the nominal rate, and — when a session
/// segment is open — that it is being captured, with the elapsed time.
///
/// Renders nothing when no [EegSessionCaptureController] is registered.
class EegLiveStatsBadge extends StatelessWidget {
  final bool compact;

  const EegLiveStatsBadge({super.key, this.compact = false});

  @override
  Widget build(BuildContext context) {
    if (!Sint.isRegistered<EegSessionCaptureController>()) {
      return const SizedBox.shrink();
    }
    final capture = Sint.find<EegSessionCaptureController>();

    return Obx(() {
      final s = capture.liveStats.value;
      final flowing = s.isFlowing;
      final open = capture.segmentOpen.value;
      final color = flowing
          ? (s.throughput >= 0.9 ? Colors.greenAccent : Colors.amber)
          : Colors.redAccent;

      final age = s.lastSampleAge;
      final status = flowing
          ? 'EN VIVO · ${s.samplesPerSecond} muestras/s · ${s.framesPerSecond} frames/s'
          : age == null
              ? 'SIN DATOS AÚN'
              : 'SIN DATOS HACE ${age.inSeconds} s';

      return Container(
        padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 10, vertical: compact ? 4 : 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withValues(alpha: 0.35)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _Pulse(active: flowing, color: color),
            const SizedBox(width: 6),
            Text(
              status,
              style: TextStyle(
                color: color,
                fontSize: compact ? 9 : 10,
                letterSpacing: 1.2,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (s.expectedSampleRate > 0 && flowing && !compact) ...[
              const SizedBox(width: 8),
              Text(
                '${(s.throughput * 100).round()}% de ${s.expectedSampleRate} Hz',
                style: const TextStyle(color: Colors.white38, fontSize: 9),
              ),
            ],
            if (open) ...[
              const SizedBox(width: 10),
              const Icon(Icons.fiber_manual_record, size: 9, color: Colors.redAccent),
              const SizedBox(width: 4),
              Text(
                'CAPTURANDO SESIÓN ${_mmss(capture.segmentSeconds.value)}',
                style: const TextStyle(
                  color: Colors.redAccent,
                  fontSize: 9,
                  letterSpacing: 1.2,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ],
        ),
      );
    });
  }

  static String _mmss(int seconds) =>
      '${(seconds ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
}

class _Pulse extends StatefulWidget {
  final bool active;
  final Color color;
  const _Pulse({required this.active, required this.color});

  @override
  State<_Pulse> createState() => _PulseState();
}

class _PulseState extends State<_Pulse> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void initState() {
    super.initState();
    if (widget.active) _ctrl.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant _Pulse old) {
    super.didUpdateWidget(old);
    if (widget.active && !_ctrl.isAnimating) _ctrl.repeat(reverse: true);
    if (!widget.active && _ctrl.isAnimating) _ctrl.stop();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
        opacity: widget.active
            ? Tween(begin: 0.35, end: 1.0).animate(_ctrl)
            : const AlwaysStoppedAnimation(1.0),
        child: Icon(
          widget.active ? Icons.circle : Icons.circle_outlined,
          size: 9,
          color: widget.color,
        ),
      );
}

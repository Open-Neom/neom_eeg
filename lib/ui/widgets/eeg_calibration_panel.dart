import 'package:flutter/material.dart';
import 'package:sint/sint.dart';

import '../../data/implementations/eeg_calibration_builder.dart';
import '../../data/implementations/eeg_calibration_controller.dart';
import '../../domain/models/eeg_calibration.dart';

/// Personal-baseline status for the connected headset, with the button that
/// runs the routine. Renders nothing when no [EegCalibrationController] is
/// registered, so hosts opt in by binding the controller.
class EegCalibrationPanel extends StatelessWidget {
  final bool compact;

  const EegCalibrationPanel({super.key, this.compact = false});

  @override
  Widget build(BuildContext context) {
    if (!Sint.isRegistered<EegCalibrationController>()) {
      return const SizedBox.shrink();
    }
    final controller = Sint.find<EegCalibrationController>();

    return Obx(() {
      final cal = controller.current.value;
      final running = controller.isRunning;
      final phase = controller.phase.value;
      final color = cal == null || cal.isStale() || !cal.supportsZ
          ? Colors.amber
          : Colors.greenAccent;

      return Container(
        padding: EdgeInsets.all(compact ? 8 : 12),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A2E),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Icon(
              cal == null ? Icons.tune : Icons.verified_outlined,
              size: 16,
              color: color,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    running
                        ? 'CALIBRANDO · ${_phaseLabel(phase).toUpperCase()} · ${controller.remainingSeconds.value} s'
                        : 'LÍNEA BASE PERSONAL',
                    style: TextStyle(
                      color: running ? Colors.lightBlueAccent : Colors.white38,
                      fontSize: 10,
                      letterSpacing: 1.5,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    running
                        ? _phaseInstruction(phase)
                        : cal == null
                            ? 'Sin calibrar: los umbrales usan valores fijos.'
                            : _summary(cal),
                    maxLines: compact ? 1 : 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: running ? Colors.white : Colors.white70,
                      fontSize: compact ? 11 : 12,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              height: 30,
              child: FilledButton.tonalIcon(
                key: const ValueKey('eeg-calibrate'),
                onPressed: running
                    ? controller.cancel
                    : () => showEegCalibrationSheet(context, controller),
                icon: Icon(running ? Icons.close : Icons.tune, size: 16),
                label: Text(running ? 'Cancelar' : (cal == null ? 'Calibrar' : 'Recalibrar')),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                ),
              ),
            ),
          ],
        ),
      );
    });
  }

  static String _summary(EegCalibration cal) {
    if (!cal.supportsZ) {
      return 'Formato anterior (potencia lineal): recalibra para activar las reglas personales.';
    }
    final parts = <String>[_age(cal.age)];
    final react = cal.alphaReactivity;
    if (react != null) parts.add('reactividad alfa ${react.toStringAsFixed(1)}×');
    parts.add('${cal.channels.length} canales');
    if (cal.rejectedFrames > 0) parts.add('${cal.rejectedFrames} frames con artefactos descartados');
    if (cal.isStale()) parts.add('conviene repetirla');
    return parts.join(' · ');
  }

  static String _age(Duration d) {
    if (d.inMinutes < 1) return 'hace un momento';
    if (d.inHours < 1) return 'hace ${d.inMinutes} min';
    if (d.inDays < 1) return 'hace ${d.inHours} h';
    return 'hace ${d.inDays} d';
  }
}

String _phaseLabel(EegCalibrationPhase p) => switch (p) {
      EegCalibrationPhase.eyesOpen => 'ojos abiertos',
      EegCalibrationPhase.eyesClosed => 'ojos cerrados',
      EegCalibrationPhase.done => 'lista',
      EegCalibrationPhase.cancelled => 'cancelada',
      EegCalibrationPhase.idle => 'inactiva',
    };

String _phaseInstruction(EegCalibrationPhase p) => switch (p) {
      EegCalibrationPhase.eyesOpen => 'Mira un punto fijo, sin parpadear más de lo normal.',
      EegCalibrationPhase.eyesClosed => 'Cierra los ojos y respira con calma.',
      _ => '',
    };

/// Opens the routine as a bottom sheet: instructions, the two timed phases
/// with a countdown, and the summary of what was measured.
Future<void> showEegCalibrationSheet(
  BuildContext context,
  EegCalibrationController controller,
) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0D1117),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => EegCalibrationSheet(controller: controller),
    );

class EegCalibrationSheet extends StatefulWidget {
  final EegCalibrationController controller;
  final Duration eyesOpen;
  final Duration eyesClosed;

  const EegCalibrationSheet({
    super.key,
    required this.controller,
    this.eyesOpen = const Duration(seconds: 60),
    this.eyesClosed = const Duration(seconds: 30),
  });

  @override
  State<EegCalibrationSheet> createState() => _EegCalibrationSheetState();
}

class _EegCalibrationSheetState extends State<EegCalibrationSheet> {
  bool _includeEyesClosed = true;
  bool _started = false;
  String? _error;

  EegCalibrationController get c => widget.controller;

  Future<void> _start() async {
    setState(() {
      _started = true;
      _error = null;
    });
    try {
      await c.run(
        eyesOpen: widget.eyesOpen,
        eyesClosed: widget.eyesClosed,
        includeEyesClosed: _includeEyesClosed,
      );
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString().replaceFirst('EegException: ', ''));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Obx(() {
          final phase = c.phase.value;
          final running = c.isRunning;
          final cal = c.current.value;
          final showResult = _started && !running && phase == EegCalibrationPhase.done && cal != null;
          final failed = _started && !running && phase == EegCalibrationPhase.cancelled;

          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.tune, color: Colors.lightBlueAccent, size: 18),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Línea base personal',
                      style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white54),
                    onPressed: () {
                      if (running) c.cancel();
                      Sint.pop();
                    },
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (running) _Countdown(controller: c),
              if (showResult) _Result(calibration: cal),
              if (failed)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    c.error.value ?? 'Calibración cancelada.',
                    style: const TextStyle(color: Colors.redAccent, fontSize: 13),
                  ),
                ),
              if (!running && !showResult) ...[
                const Text(
                  'Dos fases cortas para medir tu reposo: primero con los ojos abiertos '
                  'mirando un punto fijo, después con los ojos cerrados. Con esto los '
                  'avisos (asimetría, beta alta, hipofrontalidad) se miden contra tu '
                  'propia señal en vez de contra valores fijos.',
                  style: TextStyle(color: Colors.white70, fontSize: 13, height: 1.4),
                ),
                const SizedBox(height: 10),
                _Step(
                  n: 1,
                  text: 'Ojos abiertos · ${widget.eyesOpen.inSeconds} s',
                  hint: 'Mirada en un punto fijo, mandíbula relajada.',
                ),
                _Step(
                  n: 2,
                  text: 'Ojos cerrados · ${widget.eyesClosed.inSeconds} s',
                  hint: 'Mide la reactividad alfa (cuánto sube al cerrar los ojos).',
                  enabled: _includeEyesClosed,
                  onToggle: (v) => setState(() => _includeEyesClosed = v),
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
                  ),
                const SizedBox(height: 14),
                FilledButton.icon(
                  key: const ValueKey('eeg-calibration-start'),
                  onPressed: _start,
                  icon: const Icon(Icons.play_arrow),
                  label: Text(failed || cal != null ? 'Repetir calibración' : 'Empezar'),
                ),
              ],
              if (running)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: OutlinedButton.icon(
                    onPressed: c.cancel,
                    icon: const Icon(Icons.close, size: 16),
                    label: const Text('Cancelar'),
                  ),
                ),
              if (showResult)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => setState(() => _started = false),
                          child: const Text('Repetir'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: FilledButton(
                          key: const ValueKey('eeg-calibration-done'),
                          onPressed: () => Sint.pop(),
                          child: const Text('Listo'),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          );
        }),
      ),
    );
  }
}

class _Step extends StatelessWidget {
  final int n;
  final String text;
  final String hint;
  final bool enabled;
  final ValueChanged<bool>? onToggle;

  const _Step({
    required this.n,
    required this.text,
    required this.hint,
    this.enabled = true,
    this.onToggle,
  });

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Container(
              width: 22,
              height: 22,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: enabled ? Colors.lightBlueAccent.withValues(alpha: 0.2) : Colors.white10,
              ),
              child: Text('$n', style: TextStyle(color: enabled ? Colors.lightBlueAccent : Colors.white38, fontSize: 11)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(text, style: TextStyle(color: enabled ? Colors.white : Colors.white38, fontSize: 13)),
                  Text(hint, style: const TextStyle(color: Colors.white38, fontSize: 11)),
                ],
              ),
            ),
            if (onToggle != null)
              Switch(value: enabled, onChanged: onToggle),
          ],
        ),
      );
}

class _Countdown extends StatelessWidget {
  final EegCalibrationController controller;
  const _Countdown({required this.controller});

  @override
  Widget build(BuildContext context) => Obx(() {
        final phase = controller.phase.value;
        final closed = phase == EegCalibrationPhase.eyesClosed;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(
            children: [
              SizedBox(
                width: 140,
                height: 140,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    SizedBox(
                      width: 140,
                      height: 140,
                      child: CircularProgressIndicator(
                        value: controller.progress.value,
                        strokeWidth: 6,
                        backgroundColor: Colors.white10,
                        color: closed ? Colors.deepPurpleAccent : Colors.lightBlueAccent,
                      ),
                    ),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          closed ? Icons.visibility_off : Icons.visibility,
                          color: Colors.white70,
                          size: 26,
                        ),
                        Text(
                          '${controller.remainingSeconds.value}',
                          style: const TextStyle(color: Colors.white, fontSize: 40, fontWeight: FontWeight.w300, height: 1.1),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Text(
                _phaseLabel(phase).toUpperCase(),
                style: const TextStyle(color: Colors.white38, fontSize: 11, letterSpacing: 2),
              ),
              const SizedBox(height: 4),
              Text(
                _phaseInstruction(phase),
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 16),
              ),
              const SizedBox(height: 8),
              Text(
                '${controller.frames.value} frames de bandas',
                style: const TextStyle(color: Colors.white38, fontSize: 11),
              ),
            ],
          ),
        );
      });
}

class _Result extends StatelessWidget {
  final EegCalibration calibration;
  const _Result({required this.calibration});

  @override
  Widget build(BuildContext context) {
    final cal = calibration;
    final shares = cal.bandShares;
    final react = cal.alphaReactivity;
    final tiles = <(String, String, Color?)>[
      ('Frames', '${cal.frames}', null),
      if (cal.rejectedFrames > 0) ('Artefactos', '${cal.rejectedFrames}', Colors.amber),
      ('Canales', '${cal.channels.length}', null),
      if (react != null)
        (
          'Reactividad alfa',
          '${react.toStringAsFixed(2)}×',
          react >= 1.3 ? Colors.greenAccent : Colors.amber,
        ),
      ('Ruido (µV)', cal.noiseFloor.toStringAsFixed(1), null),
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.check_circle, color: Colors.greenAccent, size: 18),
              const SizedBox(width: 8),
              Text(
                'Línea base guardada${cal.deviceType != null ? ' · ${cal.deviceType!.displayName}' : ''}',
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final (k, v, color) in tiles)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1A1A2E),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(k.toUpperCase(), style: const TextStyle(color: Colors.white38, fontSize: 9, letterSpacing: 1.2)),
                      Text(v, style: TextStyle(color: color ?? Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
            ],
          ),
          if (shares.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Text('ESPECTRO EN REPOSO', style: TextStyle(color: Colors.white38, fontSize: 9, letterSpacing: 1.2)),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: SizedBox(
                height: 10,
                child: Row(
                  children: [
                    for (final e in shares.entries)
                      if (e.value > 0)
                        Expanded(
                          flex: (e.value * 1000).round().clamp(1, 1000),
                          child: Container(color: _bandColor(e.key)),
                        ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 10,
              children: [
                for (final e in shares.entries)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(width: 8, height: 8, color: _bandColor(e.key)),
                      const SizedBox(width: 4),
                      Text('${e.key} ${(e.value * 100).round()}%', style: const TextStyle(color: Colors.white54, fontSize: 10)),
                    ],
                  ),
              ],
            ),
          ],
          if (react != null && react < 1.3)
            const Padding(
              padding: EdgeInsets.only(top: 10),
              child: Text(
                'La reactividad alfa es baja: revisa el contacto de los electrodos posteriores '
                'o repite la calibración en un lugar tranquilo.',
                style: TextStyle(color: Colors.amber, fontSize: 11),
              ),
            ),
        ],
      ),
    );
  }

  static Color _bandColor(String band) => switch (band) {
        'delta' => const Color(0xFF5C6BC0),
        'theta' => const Color(0xFF7E57C2),
        'alpha' => const Color(0xFF26A69A),
        'betaLow' => const Color(0xFFFFB300),
        'betaHigh' => const Color(0xFFF4511E),
        'gamma' => const Color(0xFFEC407A),
        _ => Colors.white38,
      };
}

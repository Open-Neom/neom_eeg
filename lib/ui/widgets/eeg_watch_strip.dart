import 'package:flutter/material.dart';
import 'package:sint/sint.dart';

import '../../data/implementations/eeg_indices.dart';
import '../../data/implementations/eeg_watch_controller.dart';
import '../../domain/models/eeg_watch_rule.dart';

/// Live indices the watcher evaluates (asymmetry, coherence, band
/// z-scores, frontal activation) and the alerts it has raised, with a
/// switch for automatic markers. Renders nothing when no
/// [EegWatchController] is registered.
class EegWatchStrip extends StatelessWidget {
  final bool compact;

  const EegWatchStrip({super.key, this.compact = false});

  @override
  Widget build(BuildContext context) {
    if (!Sint.isRegistered<EegWatchController>()) return const SizedBox.shrink();
    final watch = Sint.find<EegWatchController>();

    return Obx(() {
      final idx = watch.indices.value;
      final alerts = watch.alerts;
      final active = watch.active;
      final holding = watch.holding;
      final worst = _worstActive(watch, active);
      final border = worst == null
          ? null
          : Border.all(color: _severityColor(worst).withValues(alpha: 0.6));

      return Container(
        padding: EdgeInsets.all(compact ? 8 : 12),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A2E),
          borderRadius: BorderRadius.circular(10),
          border: border,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  worst == null ? Icons.shield_outlined : Icons.notifications_active,
                  size: 14,
                  color: worst == null ? Colors.white38 : _severityColor(worst),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    worst == null
                        ? 'VIGILANTE · ${watch.rules.where(watch.isArmed).length}/${watch.rules.length} reglas armadas'
                        : 'VIGILANTE · ${active.length} activa${active.length == 1 ? '' : 's'}',
                    style: TextStyle(
                      color: worst == null ? Colors.white38 : _severityColor(worst),
                      fontSize: 10,
                      letterSpacing: 1.5,
                    ),
                  ),
                ),
                Tooltip(
                  message: 'Marcar automáticamente en la grabación cuando una regla se dispara',
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.flag, size: 12, color: Colors.white38),
                      const SizedBox(width: 2),
                      SizedBox(
                        height: 24,
                        child: Switch(
                          key: const ValueKey('eeg-auto-markers'),
                          value: watch.autoMarkers.value,
                          onChanged: (v) => watch.autoMarkers.value = v,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            SizedBox(height: compact ? 6 : 8),
            if (idx.isEmpty)
              const Text(
                'Esperando bandas del headset…',
                style: TextStyle(color: Colors.white38, fontSize: 11),
              )
            else
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: _indexChips(idx, compact),
              ),
            if (holding.isNotEmpty) ...[
              SizedBox(height: compact ? 6 : 8),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final id in holding.keys)
                    _HoldingChip(
                      rule: watch.rules.firstWhere((r) => r.id == id),
                      since: holding[id]!,
                      now: idx.at,
                    ),
                ],
              ),
            ],
            if (alerts.isNotEmpty) ...[
              SizedBox(height: compact ? 6 : 8),
              for (final a in alerts.take(compact ? 2 : 4))
                _AlertRow(alert: a, active: active.contains(a.rule.id)),
            ],
            if (!idx.isCalibrated && !compact)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text(
                  'Sin línea base personal: las reglas por desviación (beta, alfa, '
                  'hipofrontalidad) están dormidas; asimetría y contacto siguen activas.',
                  style: TextStyle(color: Colors.white38, fontSize: 10),
                ),
              ),
          ],
        ),
      );
    });
  }

  static EegAlertSeverity? _worstActive(EegWatchController watch, Set<String> active) {
    EegAlertSeverity? worst;
    for (final id in active) {
      final rule = watch.rules.where((r) => r.id == id).firstOrNull;
      if (rule == null) continue;
      if (worst == null || rule.severity.index > worst.index) worst = rule.severity;
    }
    return worst;
  }

  static List<Widget> _indexChips(EegLiveIndices idx, bool compact) {
    final chips = <Widget>[];
    final pair = idx.pair;
    if (idx.asymmetry != null && pair != null) {
      chips.add(_Chip(
        label: 'ASIM ${pair.left}/${pair.right}',
        value: _signed(idx.asymmetry!, 2),
        color: idx.asymmetry!.abs() > 0.2 ? Colors.amber : Colors.white70,
      ));
      chips.add(_Chip(
        label: 'COHERENCIA',
        value: idx.coherence!.toStringAsFixed(2),
        color: idx.coherence! >= 0.8 ? Colors.greenAccent : Colors.white70,
      ));
    }
    for (final band in const ['alpha', 'theta', 'beta']) {
      final z = idx.z[band];
      final share = idx.shares[band];
      if (share == null) continue;
      chips.add(_Chip(
        label: band.toUpperCase(),
        value: z == null
            ? '${(share * 100).round()}%'
            : '${(share * 100).round()}% · z ${_signed(z, 1)}',
        color: z != null && z.abs() >= 2 ? Colors.amber : Colors.white70,
      ));
    }
    if (idx.frontalActivation != null) {
      final hypo = idx.hypofrontality;
      chips.add(_Chip(
        label: 'FRONTAL β/(α+θ)',
        value: hypo == null
            ? idx.frontalActivation!.toStringAsFixed(2)
            : '${idx.frontalActivation!.toStringAsFixed(2)} · −${(hypo * 100).round()}%',
        color: hypo != null && hypo >= 0.3 ? Colors.greenAccent : Colors.white70,
      ));
    }
    if (idx.excludedChannels > 0) {
      chips.add(_Chip(
        label: 'SIN CONTACTO',
        value: '${idx.excludedChannels}',
        color: Colors.redAccent,
      ));
    }
    return chips;
  }

  static String _signed(double v, int digits) => '${v >= 0 ? '+' : ''}${v.toStringAsFixed(digits)}';
}

Color _severityColor(EegAlertSeverity s) => switch (s) {
      EegAlertSeverity.info => Colors.lightBlueAccent,
      EegAlertSeverity.warning => Colors.amber,
      EegAlertSeverity.critical => Colors.redAccent,
    };

class _Chip extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _Chip({required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: const TextStyle(color: Colors.white38, fontSize: 9, letterSpacing: 1)),
            const SizedBox(width: 6),
            Text(
              value,
              style: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      );
}

class _HoldingChip extends StatelessWidget {
  final EegWatchRule rule;
  final DateTime since;
  final DateTime now;
  const _HoldingChip({required this.rule, required this.since, required this.now});

  @override
  Widget build(BuildContext context) {
    final held = now.difference(since);
    final progress = rule.sustain.inMilliseconds == 0
        ? 1.0
        : (held.inMilliseconds / rule.sustain.inMilliseconds).clamp(0.0, 1.0);
    final color = _severityColor(rule.severity);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 10,
            height: 10,
            child: CircularProgressIndicator(value: progress, strokeWidth: 2, color: color, backgroundColor: Colors.white10),
          ),
          const SizedBox(width: 6),
          Text(
            '${rule.label} · ${held.inSeconds}/${rule.sustain.inSeconds} s',
            style: TextStyle(color: color, fontSize: 10),
          ),
        ],
      ),
    );
  }
}

class _AlertRow extends StatelessWidget {
  final EegAlert alert;
  final bool active;
  const _AlertRow({required this.alert, required this.active});

  @override
  Widget build(BuildContext context) {
    final color = _severityColor(alert.severity);
    final t = alert.firedAt.toLocal();
    final hhmm = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(
            active ? Icons.circle : Icons.circle_outlined,
            size: 8,
            color: active ? color : color.withValues(alpha: 0.5),
          ),
          const SizedBox(width: 8),
          Text(hhmm, style: const TextStyle(color: Colors.white38, fontSize: 10, fontFamily: 'monospace')),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${alert.label} · ${alert.value.toStringAsFixed(2)} ${alert.rule.above ? '>' : '<'} ${alert.threshold.toStringAsFixed(2)} · ${alert.sustained.inSeconds} s',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: active ? Colors.white : Colors.white70, fontSize: 11),
            ),
          ),
          if (alert.markerAdded) const Icon(Icons.flag, size: 12, color: Colors.amber),
        ],
      ),
    );
  }
}

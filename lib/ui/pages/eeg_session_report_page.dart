import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../domain/models/eeg_session_capture.dart';

/// What happened in one captured session: the frequencies the host played,
/// what the microphone heard, the markers the user set, and the EEG the
/// headset produced — bands, hemispheric coherence, metrics, contact and
/// real-time coverage.
class EegSessionReportPage extends StatelessWidget {
  final EegSessionCapture capture;

  const EegSessionReportPage({super.key, required this.capture});

  @override
  Widget build(BuildContext context) {
    final c = capture;
    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      appBar: AppBar(
        title: const Text('Reporte de sesión'),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1000),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Header(capture: c),
                const SizedBox(height: 12),
                _SummaryTiles(capture: c),
                const SizedBox(height: 12),
                _Section(
                  title: 'FRECUENCIAS UTILIZADAS',
                  icon: Icons.graphic_eq,
                  child: _FrequenciesUsed(capture: c),
                ),
                const SizedBox(height: 12),
                _Section(
                  title: 'MICRÓFONO',
                  icon: Icons.mic,
                  child: _Voice(capture: c),
                ),
                const SizedBox(height: 12),
                _Section(
                  title: 'SEÑAL EEG · BANDAS POR SEGUNDO',
                  icon: Icons.show_chart,
                  child: SizedBox(height: 220, child: _BandsChart(capture: c)),
                ),
                const SizedBox(height: 12),
                _Section(
                  title: 'HEMISFERIOS · COHERENCIA Y SIMETRÍA (α)',
                  icon: Icons.balance,
                  child: _CoherenceChart(capture: c),
                ),
                const SizedBox(height: 12),
                _Section(
                  title: 'ESTADO MENTAL (PROMEDIO)',
                  icon: Icons.psychology_alt,
                  child: _MetricsAvg(capture: c),
                ),
                const SizedBox(height: 12),
                _Section(
                  title: 'MARCADORES, AVISOS Y CONTACTO',
                  icon: Icons.flag,
                  child: _Events(capture: c),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Sections ──────────────────────────────────────────────────────────

class _Header extends StatelessWidget {
  final EegSessionCapture capture;
  const _Header({required this.capture});

  @override
  Widget build(BuildContext context) {
    final c = capture;
    final start = c.startedAt.toLocal();
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A2E),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${_two(start.day)}/${_two(start.month)}/${start.year} · '
            '${_two(start.hour)}:${_two(start.minute)} · ${_mmss(c.duration.inSeconds)}',
            style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              _Tag('${c.deviceName} · ${c.deviceType.displayName}'),
              _Tag('${c.channels.length} ch · ${c.sampleRate} Hz'),
              if (c.practiceSessionId != null) _Tag('sesión ${c.practiceSessionId}'),
              _Tag(c.channels.join(' ')),
            ],
          ),
        ],
      ),
    );
  }
}

class _SummaryTiles extends StatelessWidget {
  final EegSessionCapture capture;
  const _SummaryTiles({required this.capture});

  @override
  Widget build(BuildContext context) {
    final c = capture;
    final coverage = c.coverage;
    final tiles = <(String, String, Color)>[
      (
        'Cobertura EEG',
        '${(coverage * 100).round()}%',
        coverage >= 0.9 ? Colors.greenAccent : coverage >= 0.6 ? Colors.amber : Colors.redAccent,
      ),
      ('Muestras', _thousands(c.sampleCount), Colors.white),
      ('Segundos con señal', '${c.secondsWithSignal} / ${c.rows.length}', Colors.white),
      ('Banda dominante', c.dominantBand ?? '—', const Color(0xFF4DB6AC)),
      (
        'Coherencia α media',
        c.avgCoherence == null ? '—' : c.avgCoherence!.toStringAsFixed(2),
        Colors.white,
      ),
      (
        'Simetría α media',
        c.avgSymmetry == null ? '—' : '${(c.avgSymmetry! * 100).round()}%',
        Colors.white,
      ),
      ('Marcadores', '${c.markers.length}', Colors.white),
      if (c.alerts.isNotEmpty) ('Avisos', '${c.alerts.length}', Colors.amber),
      if (c.frequencyFollowing != null)
        (
          'Respuesta a ${_hz(c.frequencyFollowing!.hz)}',
          'SNR ${c.frequencyFollowing!.meanSnr.toStringAsFixed(1)}×',
          c.frequencyFollowing!.meanSnr >= 2
              ? Colors.greenAccent
              : c.frequencyFollowing!.meanSnr >= 1.3
                  ? Colors.amber
                  : Colors.white,
        ),
      if (c.bandShift('alpha') != null)
        ('Cambio alfa fin/inicio', _ratio(c.bandShift('alpha')!), Colors.white),
    ];
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final (label, value, color) in tiles)
          Container(
            width: 150,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A2E),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label.toUpperCase(),
                    style: const TextStyle(color: Colors.white38, fontSize: 9, letterSpacing: 1.2)),
                const SizedBox(height: 4),
                Text(value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: color, fontSize: 18, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
      ],
    );
  }
}

class _FrequenciesUsed extends StatelessWidget {
  final EegSessionCapture capture;
  const _FrequenciesUsed({required this.capture});

  @override
  Widget build(BuildContext context) {
    final used = capture.frequenciesUsed;
    if (used.isEmpty) {
      return const Text(
        'La app no reportó contexto de audio en esta sesión.',
        style: TextStyle(color: Colors.white38, fontSize: 12),
      );
    }
    final total = used.fold(0.0, (s, u) => s + u.seconds);
    final preset = capture.context
        .map((c) => c.values[EegContextKeys.preset])
        .whereType<String>()
        .toSet();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (preset.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text('Preset: ${preset.join(', ')}',
                style: const TextStyle(color: Colors.white70, fontSize: 12)),
          ),
        for (final u in used)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                SizedBox(
                  width: 160,
                  child: Text(
                    '${u.baseHz.toStringAsFixed(1)} Hz'
                    '${u.beatHz > 0 ? ' · binaural ${u.beatHz.toStringAsFixed(2)} Hz' : ''}',
                    style: const TextStyle(color: Colors.white, fontSize: 12, fontFamily: 'monospace'),
                  ),
                ),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: total > 0 ? u.seconds / total : 0,
                      minHeight: 6,
                      backgroundColor: Colors.white10,
                      valueColor: const AlwaysStoppedAnimation(Color(0xFF64B5F6)),
                    ),
                  ),
                ),
                SizedBox(
                  width: 64,
                  child: Text(_mmss(u.seconds.round()),
                      textAlign: TextAlign.right,
                      style: const TextStyle(color: Colors.white54, fontSize: 11)),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _Voice extends StatelessWidget {
  final EegSessionCapture capture;
  const _Voice({required this.capture});

  @override
  Widget build(BuildContext context) {
    final v = capture.voice;
    if (v.isEmpty) {
      return const Text(
        'Sin capturas de micrófono en esta sesión.',
        style: TextStyle(color: Colors.white38, fontSize: 12),
      );
    }
    final detected = capture.detectedVoiceHz;
    final captures = v.where((e) => e.kind == EegVoiceEventKind.captureStarted).length;
    final avg = detected.isEmpty ? null : detected.reduce((a, b) => a + b) / detected.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$captures captura${captures == 1 ? '' : 's'} de voz · '
          '${detected.length} detecciones'
          '${avg == null ? '' : ' · frecuencia media ${avg.toStringAsFixed(1)} Hz'}',
          style: const TextStyle(color: Colors.white70, fontSize: 12),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            for (final e in v)
              _Tag(switch (e.kind) {
                EegVoiceEventKind.detected =>
                  '${_mmss(e.t.round())} voz ${e.frequencyHz?.toStringAsFixed(1)} Hz',
                EegVoiceEventKind.captureStarted => '${_mmss(e.t.round())} ▶ mic',
                EegVoiceEventKind.captureStopped => '${_mmss(e.t.round())} ■ mic',
              }),
          ],
        ),
      ],
    );
  }
}

class _BandsChart extends StatelessWidget {
  final EegSessionCapture capture;
  const _BandsChart({required this.capture});

  @override
  Widget build(BuildContext context) {
    final rows = capture.rows.where((r) => r.frames > 0).toList();
    if (rows.isEmpty) {
      return const Center(
        child: Text('Sin bandas en esta sesión', style: TextStyle(color: Colors.white38, fontSize: 12)),
      );
    }
    LineChartBarData line(Color color, double Function(EegCaptureRow) f) => LineChartBarData(
          spots: [for (final r in rows) FlSpot(r.t, f(r))],
          color: color,
          barWidth: 1.6,
          isCurved: false,
          dotData: const FlDotData(show: false),
        );
    final maxY = rows.fold(0.0, (m, r) => [m, r.alpha, r.theta, r.beta, r.delta, r.gamma].reduce((a, b) => a > b ? a : b));
    return Column(
      children: [
        Expanded(
          child: LineChart(
            LineChartData(
              minX: 0,
              maxX: capture.duration.inSeconds.toDouble().clamp(1, double.infinity),
              minY: 0,
              maxY: maxY * 1.1,
              lineBarsData: [
                line(const Color(0xFF9C27B0), (r) => r.delta),
                line(const Color(0xFF5C6BC0), (r) => r.theta),
                line(const Color(0xFF4CAF50), (r) => r.alpha),
                line(const Color(0xFFFFC107), (r) => r.beta),
                line(const Color(0xFFF44336), (r) => r.gamma),
              ],
              gridData: FlGridData(
                show: true,
                drawVerticalLine: false,
                getDrawingHorizontalLine: (_) => FlLine(color: Colors.white10, strokeWidth: 1),
              ),
              borderData: FlBorderData(show: false),
              titlesData: _axes(capture),
              lineTouchData: const LineTouchData(enabled: false),
            ),
          ),
        ),
        const SizedBox(height: 6),
        const Wrap(
          spacing: 12,
          children: [
            _Legend('δ delta', Color(0xFF9C27B0)),
            _Legend('θ theta', Color(0xFF5C6BC0)),
            _Legend('α alpha', Color(0xFF4CAF50)),
            _Legend('β beta', Color(0xFFFFC107)),
            _Legend('γ gamma', Color(0xFFF44336)),
          ],
        ),
      ],
    );
  }
}

/// Spectral coherence (does each side oscillate with the other?) and power
/// symmetry (does each side carry the same amount of alpha?) per second.
class _CoherenceChart extends StatelessWidget {
  final EegSessionCapture capture;
  const _CoherenceChart({required this.capture});

  static const _coherenceColor = Color(0xFF4DB6AC);
  static const _symmetryColor = Color(0xFF9FA8DA);

  @override
  Widget build(BuildContext context) {
    final coh = capture.rows.where((r) => r.coherence != null).toList();
    final sym = capture.rows.where((r) => r.symmetry != null).toList();
    if (coh.isEmpty && sym.isEmpty) {
      return const Text('El headset no tiene par izquierdo/derecho utilizable',
          style: TextStyle(color: Colors.white38, fontSize: 12));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 14,
          children: [
            if (coh.isNotEmpty) const _Legend('Coherencia espectral (MSC)', _coherenceColor),
            if (sym.isNotEmpty) const _Legend('Simetría de potencia', _symmetryColor),
          ],
        ),
        if (coh.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text(
              'Sin coherencia espectral: el headset no entregó EEG crudo en esta sesión '
              '(en Emotiv requiere licencia de datos crudos).',
              style: TextStyle(color: Colors.white38, fontSize: 11),
            ),
          ),
        const SizedBox(height: 8),
        SizedBox(
          height: 150,
          child: LineChart(
            LineChartData(
              minX: 0,
              maxX: capture.duration.inSeconds.toDouble().clamp(1, double.infinity),
              minY: 0,
              maxY: 1,
              lineBarsData: [
                if (sym.isNotEmpty)
                  LineChartBarData(
                    spots: [for (final r in sym) FlSpot(r.t, r.symmetry!)],
                    color: _symmetryColor,
                    barWidth: 1.2,
                    dashArray: const [4, 3],
                    dotData: const FlDotData(show: false),
                  ),
                if (coh.isNotEmpty)
                  LineChartBarData(
                    spots: [for (final r in coh) FlSpot(r.t, r.coherence!)],
                    color: _coherenceColor,
                    barWidth: 1.8,
                    dotData: const FlDotData(show: false),
                    belowBarData: BarAreaData(show: true, color: _coherenceColor.withValues(alpha: 0.12)),
                  ),
              ],
              gridData: FlGridData(
                show: true,
                drawVerticalLine: false,
                horizontalInterval: 0.25,
                getDrawingHorizontalLine: (_) => FlLine(color: Colors.white10, strokeWidth: 1),
              ),
              borderData: FlBorderData(show: false),
              titlesData: _axes(capture, leftFormatter: (v) => v.toStringAsFixed(2)),
              lineTouchData: const LineTouchData(enabled: false),
            ),
          ),
        ),
      ],
    );
  }
}

class _MetricsAvg extends StatelessWidget {
  final EegSessionCapture capture;
  const _MetricsAvg({required this.capture});

  @override
  Widget build(BuildContext context) {
    final m = capture.avgMetrics;
    final rows = <(String, double?, Color)>[
      ('Enfoque', m['focus'], const Color(0xFF64B5F6)),
      ('Relajación', m['relaxation'], const Color(0xFF4DB6AC)),
      ('Engagement', m['engagement'], const Color(0xFFBA68C8)),
      ('Excitación', m['excitement'], const Color(0xFFFFB74D)),
      ('Estrés', m['stress'], const Color(0xFFE57373)),
    ];
    if (rows.every((r) => r.$2 == null)) {
      return const Text('Sin métricas en esta sesión',
          style: TextStyle(color: Colors.white38, fontSize: 12));
    }
    return Column(
      children: [
        for (final (label, value, color) in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                SizedBox(width: 90, child: Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12))),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: (value ?? 0).clamp(0.0, 1.0),
                      minHeight: 6,
                      backgroundColor: Colors.white10,
                      valueColor: AlwaysStoppedAnimation(color),
                    ),
                  ),
                ),
                SizedBox(
                  width: 44,
                  child: Text(value == null ? '—' : '${(value * 100).round()}%',
                      textAlign: TextAlign.right,
                      style: const TextStyle(color: Colors.white54, fontSize: 11)),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _Events extends StatelessWidget {
  final EegSessionCapture capture;
  const _Events({required this.capture});

  @override
  Widget build(BuildContext context) {
    final c = capture;
    if (c.markers.isEmpty && c.contactChanges.isEmpty && c.alerts.isEmpty) {
      return const Text('Sin marcadores, avisos ni cambios de contacto',
          style: TextStyle(color: Colors.white38, fontSize: 12));
    }
    final startMs = c.startedAt.millisecondsSinceEpoch;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final m in c.markers)
          _EventRow(
            icon: Icons.flag,
            color: Colors.amber,
            time: _mmss(((m.at.millisecondsSinceEpoch - startMs) / 1000).round().clamp(0, 1 << 30)),
            text: '${m.label} (${m.value})${m.extras.isEmpty ? '' : ' · ${m.extras}'}',
          ),
        for (final a in c.alerts)
          _EventRow(
            icon: a.markerAdded ? Icons.notifications_active : Icons.notifications_none,
            color: a.severity == 'critical'
                ? Colors.redAccent
                : a.severity == 'warning'
                    ? Colors.amber
                    : Colors.lightBlueAccent,
            time: _mmss(a.t.round()),
            text: '${a.label}${a.pair != null ? ' (${a.pair})' : ''} · '
                '${a.value.toStringAsFixed(2)} vs ${a.threshold.toStringAsFixed(2)} · '
                'sostenido ${a.sustainedSeconds.round()} s'
                '${a.markerAdded ? ' · marcado' : ''}',
          ),
        for (final cc in c.contactChanges)
          _EventRow(
            icon: cc.excluded.isEmpty ? Icons.sensors : Icons.sensors_off,
            color: cc.excluded.isEmpty ? Colors.greenAccent : Colors.redAccent,
            time: _mmss(cc.t.round()),
            text: cc.excluded.isEmpty
                ? 'Todos los electrodos en contacto'
                : 'Sin contacto: ${cc.excluded.join(', ')}',
          ),
      ],
    );
  }
}

// ── Helpers ───────────────────────────────────────────────────────────

FlTitlesData _axes(EegSessionCapture c, {String Function(double)? leftFormatter}) {
  final total = c.duration.inSeconds.toDouble().clamp(1, double.infinity);
  return FlTitlesData(
    topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
    rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
    leftTitles: AxisTitles(
      sideTitles: SideTitles(
        showTitles: true,
        reservedSize: 36,
        getTitlesWidget: (v, _) => Text(
          leftFormatter?.call(v) ?? v.toStringAsFixed(v >= 10 ? 0 : 1),
          style: const TextStyle(color: Colors.white38, fontSize: 9),
        ),
      ),
    ),
    bottomTitles: AxisTitles(
      sideTitles: SideTitles(
        showTitles: true,
        reservedSize: 18,
        interval: (total / 5).clamp(1, double.infinity),
        getTitlesWidget: (v, _) => Text(_mmss(v.round()),
            style: const TextStyle(color: Colors.white38, fontSize: 9)),
      ),
    ),
  );
}

class _Section extends StatelessWidget {
  final String title;
  final IconData icon;
  final Widget child;
  const _Section({required this.title, required this.icon, required this.child});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A2E),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(icon, size: 14, color: Colors.white38),
                const SizedBox(width: 6),
                Text(title,
                    style: const TextStyle(color: Colors.white38, fontSize: 10, letterSpacing: 1.5)),
              ],
            ),
            const SizedBox(height: 10),
            child,
          ],
        ),
      );
}

class _EventRow extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String time;
  final String text;
  const _EventRow({required this.icon, required this.color, required this.time, required this.text});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 8),
            Text(time, style: const TextStyle(color: Colors.white54, fontSize: 11, fontFamily: 'monospace')),
            const SizedBox(width: 10),
            Expanded(child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 12))),
          ],
        ),
      );
}

class _Legend extends StatelessWidget {
  final String label;
  final Color color;
  const _Legend(this.label, this.color);

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 10, height: 3, color: color),
          const SizedBox(width: 4),
          Text(label, style: const TextStyle(color: Colors.white54, fontSize: 10)),
        ],
      );
}

class _Tag extends StatelessWidget {
  final String text;
  const _Tag(this.text);

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(4)),
        child: Text(text, style: const TextStyle(color: Colors.white54, fontSize: 10)),
      );
}

String _two(int v) => v.toString().padLeft(2, '0');

String _mmss(int seconds) => '${_two(seconds ~/ 60)}:${_two(seconds % 60)}';

String _hz(double hz) => '${hz.toStringAsFixed(hz % 1 == 0 ? 0 : 1)} Hz';

/// Share at the end ÷ share at the start, shown as a change: ×1.30 = +30 %.
String _ratio(double r) => '${r >= 1 ? '+' : '−'}${((r - 1).abs() * 100).round()}%';

String _thousands(int n) {
  final s = n.toString();
  final out = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) out.write('.');
    out.write(s[i]);
  }
  return out.toString();
}

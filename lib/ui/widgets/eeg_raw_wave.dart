import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';

import '../../domain/models/eeg_sample.dart';

/// Oscilloscope-style raw EEG waveform display.
///
/// Renders the last 256 samples (~2 seconds at 128 Hz) of a selected
/// channel as a green line on a dark background using [CustomPainter].
class EegRawWave extends StatefulWidget {
  final Stream<EegSample> rawStream;
  final String selectedChannel;

  const EegRawWave({
    super.key,
    required this.rawStream,
    this.selectedChannel = 'AF3',
  });

  @override
  State<EegRawWave> createState() => _EegRawWaveState();
}

class _EegRawWaveState extends State<EegRawWave> {
  static const _bufferSize = 256;

  /// Repaint cadence. Samples arrive at 128-256 Hz; painting on every one
  /// would starve the UI thread (visibly so on web debug builds), so the
  /// buffer fills continuously and the canvas refreshes at ~30 fps.
  static const _repaintInterval = Duration(milliseconds: 33);

  final _buffer = ListQueue<double>(_bufferSize);
  StreamSubscription<EegSample>? _sub;
  Timer? _repaint;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    _subscribe();
    _repaint = Timer.periodic(_repaintInterval, (_) {
      if (_dirty && mounted) {
        _dirty = false;
        setState(() {});
      }
    });
  }

  @override
  void didUpdateWidget(EegRawWave oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Only the channel matters: a broadcast controller hands out a new
    // Stream wrapper on every `stream` access, so comparing streams would
    // resubscribe (and wipe the buffer) on every parent rebuild.
    if (oldWidget.selectedChannel != widget.selectedChannel) {
      _sub?.cancel();
      _buffer.clear();
      _subscribe();
    }
  }

  void _subscribe() {
    _sub = widget.rawStream.listen((sample) {
      final value = sample.channels[widget.selectedChannel] ?? 0.0;
      if (_buffer.length >= _bufferSize) {
        _buffer.removeFirst();
      }
      _buffer.addLast(value);
      _dirty = true;
    });
  }

  @override
  void dispose() {
    _repaint?.cancel();
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 120,
      decoration: BoxDecoration(
        color: const Color(0xFF0A0A14),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white10),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Stack(
          children: [
            CustomPaint(
              size: const Size(double.infinity, 120),
              painter: _WavePainter(samples: _buffer.toList()),
            ),
            // Labels
            Positioned(
              left: 6,
              top: 4,
              child: Text(
                widget.selectedChannel,
                style: const TextStyle(
                  color: Colors.green,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const Positioned(
              right: 6,
              top: 4,
              child: Text(
                '2s',
                style: TextStyle(color: Colors.white24, fontSize: 9),
              ),
            ),
            const Positioned(
              right: 6,
              bottom: 4,
              child: Text(
                'μV',
                style: TextStyle(color: Colors.white24, fontSize: 9),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WavePainter extends CustomPainter {
  final List<double> samples;

  _WavePainter({required this.samples});

  @override
  void paint(Canvas canvas, Size size) {
    if (samples.isEmpty) return;

    // Auto-scale
    double minVal = double.infinity;
    double maxVal = double.negativeInfinity;
    for (final v in samples) {
      if (v < minVal) minVal = v;
      if (v > maxVal) maxVal = v;
    }
    final range = (maxVal - minVal).clamp(1.0, double.infinity);

    // Grid lines
    final gridPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.05)
      ..strokeWidth = 0.5;
    for (var i = 1; i < 4; i++) {
      final y = size.height * i / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    // Center line
    final centerPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.1)
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(0, size.height / 2),
      Offset(size.width, size.height / 2),
      centerPaint,
    );

    // Waveform
    final wavePaint = Paint()
      ..color = const Color(0xFF4CAF50)
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round;

    final path = Path();
    for (var i = 0; i < samples.length; i++) {
      final x = i * size.width / (samples.length - 1).clamp(1, samples.length);
      final normalized = (samples[i] - minVal) / range;
      final y = size.height - normalized * size.height;

      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }

    canvas.drawPath(path, wavePaint);
  }

  @override
  bool shouldRepaint(_WavePainter oldDelegate) => true;
}

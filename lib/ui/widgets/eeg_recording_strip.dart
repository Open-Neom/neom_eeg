import 'dart:async';

import 'package:flutter/material.dart';

import '../../domain/models/eeg_recording.dart';
import '../../domain/use_cases/eeg_recording_service.dart';

/// Start/stop a recording and pin markers to it — the same controls for a
/// Cortex record (Emotiv) or the local Hive recorder (everything else).
///
/// Quick markers cover what the Cyberneom protocol logs during a session;
/// "Nota…" asks for a free label.
class EegRecordingStrip extends StatefulWidget {
  /// Resolve the service on every use: the hub swaps it when the connected
  /// driver changes.
  final EegRecordingService Function() recording;

  /// Title for recordings started from the strip.
  final String Function() defaultTitle;
  final bool compact;

  static const quickMarkers = <(String, IconData, int)>[
    ('Aura', Icons.flare, 1),
    ('Síntoma', Icons.report_gmailerrorred, 2),
    ('Respiración', Icons.air, 3),
    ('Estímulo', Icons.graphic_eq, 4),
    // Closing the eyes raises alpha by itself; marking it keeps an alpha
    // rise from being read as an effect of the audio.
    ('Ojos cerrados', Icons.visibility_off, 5),
  ];

  const EegRecordingStrip({
    super.key,
    required this.recording,
    required this.defaultTitle,
    this.compact = false,
  });

  @override
  State<EegRecordingStrip> createState() => _EegRecordingStripState();
}

class _EegRecordingStripState extends State<EegRecordingStrip> {
  StreamSubscription<EegMarker>? _markerSub;
  EegMarker? _lastMarker;
  String? _error;
  bool _busy = false;

  EegRecordingService get _service => widget.recording();

  @override
  void initState() {
    super.initState();
    _listen();
  }

  void _listen() {
    _markerSub?.cancel();
    _markerSub = _service.markerStream.listen((m) {
      if (mounted) setState(() => _lastMarker = m);
    });
  }

  @override
  void dispose() {
    _markerSub?.cancel();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (e) {
      _error = e.toString().replaceFirst('EegException: ', '');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggleRecording() => _run(() async {
        final s = _service;
        if (s.isRecording) {
          await s.stopRecording();
        } else {
          await s.startRecording(title: widget.defaultTitle());
          _listen(); // the service may have changed since the last marker
        }
      });

  Future<void> _mark(String label, int value) =>
      _run(() => _service.addMarker(label: label, value: value));

  Future<void> _customMarker() async {
    final controller = TextEditingController();
    final label = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        title: const Text('Marcar evento', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: 'Etiqueta (p. ej. "déjà vu", "mareo")',
            hintStyle: TextStyle(color: Colors.white38),
          ),
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: const Text('Marcar'),
          ),
        ],
      ),
    );
    if (label != null && label.trim().isNotEmpty) {
      await _mark(label.trim(), 9);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _service;
    final rec = s.activeRecording;
    final recording = s.isRecording;

    return Container(
      padding: EdgeInsets.all(widget.compact ? 8 : 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A2E),
        borderRadius: BorderRadius.circular(10),
        border: recording
            ? Border.all(color: Colors.redAccent.withValues(alpha: 0.5))
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                recording ? Icons.fiber_manual_record : Icons.radio_button_unchecked,
                size: 14,
                color: recording ? Colors.redAccent : Colors.white38,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  recording
                      ? 'GRABANDO · ${rec?.title ?? ''} · ${rec?.markerCount ?? 0} marcadores'
                      : 'GRABACIÓN',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: recording ? Colors.redAccent : Colors.white38,
                    fontSize: 10,
                    letterSpacing: 1.5,
                  ),
                ),
              ),
              _BackendTag(backend: s.backend),
              const SizedBox(width: 8),
              SizedBox(
                height: 30,
                child: FilledButton.tonalIcon(
                  key: const ValueKey('eeg-record-toggle'),
                  onPressed: _busy ? null : _toggleRecording,
                  icon: Icon(recording ? Icons.stop : Icons.fiber_manual_record, size: 16),
                  label: Text(recording ? 'Detener' : 'Grabar'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    backgroundColor: recording
                        ? Colors.redAccent.withValues(alpha: 0.2)
                        : null,
                    foregroundColor: recording ? Colors.redAccent : null,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: widget.compact ? 6 : 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final (label, icon, value) in EegRecordingStrip.quickMarkers)
                ActionChip(
                  key: ValueKey('eeg-marker-$label'),
                  avatar: Icon(icon, size: 14),
                  label: Text(label, style: const TextStyle(fontSize: 12)),
                  onPressed: recording && !_busy ? () => _mark(label, value) : null,
                ),
              ActionChip(
                key: const ValueKey('eeg-marker-custom'),
                avatar: const Icon(Icons.edit_note, size: 14),
                label: const Text('Nota…', style: TextStyle(fontSize: 12)),
                onPressed: recording && !_busy ? _customMarker : null,
              ),
            ],
          ),
          if (!recording)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                'Los marcadores requieren una grabación activa; quedan en la '
                'línea de tiempo del EEG.',
                style: TextStyle(color: Colors.white38, fontSize: 10),
              ),
            ),
          if (_lastMarker != null && recording)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'Último: ${_lastMarker!.label} · '
                '${_lastMarker!.at.toLocal().toIso8601String().substring(11, 19)}',
                style: const TextStyle(color: Colors.white54, fontSize: 11),
              ),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                _error!,
                style: const TextStyle(color: Colors.redAccent, fontSize: 11),
              ),
            ),
        ],
      ),
    );
  }
}

class _BackendTag extends StatelessWidget {
  final EegRecordingBackend backend;
  const _BackendTag({required this.backend});

  @override
  Widget build(BuildContext context) {
    final native = backend == EegRecordingBackend.native;
    return Tooltip(
      message: native
          ? 'Record nativo del SDK (Cortex): exportable a EDF/CSV con marcadores'
          : 'Grabación local (Hive): bandas por segundo + eventos, exporta CSV',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.white10,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          native ? 'SDK' : 'LOCAL',
          style: const TextStyle(color: Colors.white54, fontSize: 9, letterSpacing: 1),
        ),
      ),
    );
  }
}

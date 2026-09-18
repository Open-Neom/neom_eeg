import 'package:flutter/material.dart';
import 'package:sint/sint.dart';

import '../../data/implementations/eeg_connection_controller.dart';
import '../../data/implementations/eeg_session_capture_controller.dart';
import '../../data/implementations/eeg_session_recorder.dart';
import '../../domain/models/eeg_session.dart';
import '../../domain/models/eeg_session_capture.dart';
import 'eeg_session_report_page.dart';
import '../widgets/eeg_live_dashboard.dart';
import '../widgets/eeg_session_timeline.dart';

/// Main EEG monitoring page.
///
/// Wraps [EegLiveDashboard]: device picker when disconnected, the full
/// dashboard (contact quality, topography, band meters, hemispheric
/// balance, metrics, raw wave) when connected. Session timeline is
/// accessible via the drawer.
class EegMonitorPage extends StatelessWidget {
  /// Extra app-bar actions the host wants next to the monitor — e.g. a
  /// button that opens its chamber in EEG mode. The module itself knows no
  /// routes of the host.
  final List<Widget> actions;

  const EegMonitorPage({super.key, this.actions = const []});

  @override
  Widget build(BuildContext context) {
    return SintBuilder<EegConnectionController>(
      builder: (controller) {
        return Scaffold(
          backgroundColor: const Color(0xFF0D1117),
          appBar: AppBar(
            title: const Text('Monitor EEG'),
            backgroundColor: Colors.transparent,
            elevation: 0,
            actions: actions,
          ),
          drawer: _SessionDrawer(provider: controller.provider),
          body: const SingleChildScrollView(
            padding: EdgeInsets.all(16),
            child: EegLiveDashboard(),
          ),
        );
      },
    );
  }
}

/// Drawer listing captured sessions (newest first). Each opens its
/// [EegSessionReportPage]. Falls back to the legacy Hive session timeline
/// when no [EegSessionCaptureController] is registered.
class _SessionDrawer extends StatefulWidget {
  final dynamic provider;

  const _SessionDrawer({required this.provider});

  @override
  State<_SessionDrawer> createState() => _SessionDrawerState();
}

class _SessionDrawerState extends State<_SessionDrawer> {
  final _recorder = EegSessionRecorder();
  List<EegSession> _sessions = [];

  EegSessionCaptureController? get _capture =>
      Sint.isRegistered<EegSessionCaptureController>()
          ? Sint.find<EegSessionCaptureController>()
          : null;

  @override
  void initState() {
    super.initState();
    final capture = _capture;
    if (capture != null) {
      capture.listCaptures();
    } else {
      _loadSessions();
    }
  }

  Future<void> _loadSessions() async {
    final sessions = await _recorder.getSessions();
    if (mounted) setState(() => _sessions = sessions);
  }

  @override
  Widget build(BuildContext context) {
    final capture = _capture;
    return Drawer(
      backgroundColor: const Color(0xFF0D1117),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Sesiones EEG',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const Divider(color: Colors.white12),
            Expanded(
              child: capture == null
                  ? EegSessionTimeline(
                      sessions: _sessions,
                      onTap: (_) => Navigator.pop(context),
                    )
                  : Obx(() {
                      final items = capture.captures;
                      if (items.isEmpty) {
                        return const Center(
                          child: Padding(
                            padding: EdgeInsets.all(24),
                            child: Text(
                              'Aún no hay sesiones capturadas.\nConecta un headset y '
                              'reproduce en la Cámara Neom o inicia una grabación.',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: Colors.white38, fontSize: 13),
                            ),
                          ),
                        );
                      }
                      return ListView.builder(
                        itemCount: items.length,
                        itemBuilder: (_, i) => _CaptureTile(
                          capture: items[i],
                          onTap: () {
                            Navigator.pop(context);
                            Navigator.of(context).push(MaterialPageRoute<void>(
                              builder: (_) => EegSessionReportPage(capture: items[i]),
                            ));
                          },
                          onDelete: () => capture.deleteCapture(items[i].id),
                        ),
                      );
                    }),
            ),
          ],
        ),
      ),
    );
  }
}

class _CaptureTile extends StatelessWidget {
  final EegSessionCapture capture;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _CaptureTile({
    required this.capture,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final c = capture;
    final start = c.startedAt.toLocal();
    final mins = c.duration.inMinutes;
    final secs = c.duration.inSeconds % 60;
    final coverage = (c.coverage * 100).round();
    return ListTile(
      dense: true,
      onTap: onTap,
      leading: Icon(
        c.practiceSessionId?.startsWith('practice_') == true
            ? Icons.graphic_eq
            : Icons.fiber_manual_record,
        color: coverage >= 90 ? Colors.greenAccent : Colors.amber,
        size: 18,
      ),
      title: Text(
        '${start.day.toString().padLeft(2, '0')}/${start.month.toString().padLeft(2, '0')} '
        '${start.hour.toString().padLeft(2, '0')}:${start.minute.toString().padLeft(2, '0')} · '
        '${mins}m ${secs}s',
        style: const TextStyle(color: Colors.white, fontSize: 13),
      ),
      subtitle: Text(
        '${c.deviceType.displayName} · cobertura $coverage% · '
        '${c.dominantBand ?? '—'} · ${c.markers.length} marcadores'
        '${c.frequenciesUsed.isNotEmpty ? ' · ${c.frequenciesUsed.first.baseHz.toStringAsFixed(0)} Hz' : ''}',
        style: const TextStyle(color: Colors.white54, fontSize: 11),
      ),
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline, size: 18, color: Colors.white38),
        onPressed: onDelete,
        tooltip: 'Eliminar',
      ),
    );
  }
}

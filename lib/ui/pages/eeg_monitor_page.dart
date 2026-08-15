import 'dart:async';

import 'package:flutter/material.dart';
import 'package:sint/sint.dart';

import '../../data/implementations/eeg_connection_controller.dart';
import '../../data/implementations/eeg_session_recorder.dart';
import '../../data/implementations/eeg_signal_processor.dart';
import '../../domain/enums/eeg_connection_state.dart';
import '../../domain/models/eeg_asymmetry.dart';
import '../../domain/models/eeg_band_power.dart';
import '../../domain/models/eeg_session.dart';
import '../widgets/eeg_asymmetry_indicator.dart';
import '../widgets/eeg_band_meter.dart';
import '../widgets/eeg_device_picker.dart';
import '../widgets/eeg_raw_wave.dart';
import '../widgets/eeg_session_timeline.dart';
import '../widgets/eeg_topography.dart';

/// Main EEG monitoring page.
///
/// Shows device picker when disconnected, and a full monitoring
/// dashboard (band meters, topography, raw waveform, asymmetry)
/// when connected. Session timeline is accessible via the drawer.
class EegMonitorPage extends StatelessWidget {
  const EegMonitorPage({super.key});

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
          ),
          drawer: _SessionDrawer(provider: controller.provider),
          body: Obx(() {
            final state = controller.state.value;
            final isConnected =
                state == EegConnectionState.streaming ||
                    state == EegConnectionState.connected;

            return SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (!isConnected)
                    const EegDevicePicker()
                  else
                    _MonitorDashboard(controller: controller),
                ],
              ),
            );
          }),
        );
      },
    );
  }
}

/// Connected dashboard showing all EEG visualizations.
class _MonitorDashboard extends StatefulWidget {
  final EegConnectionController controller;

  const _MonitorDashboard({required this.controller});

  @override
  State<_MonitorDashboard> createState() => _MonitorDashboardState();
}

class _MonitorDashboardState extends State<_MonitorDashboard> {
  final _processor = EegSignalProcessor();
  List<EegBandPower> _latestPowers = [];
  EegAsymmetry? _latestAsymmetry;
  StreamSubscription<List<EegBandPower>>? _bandPowerSub;

  @override
  void initState() {
    super.initState();
    _bandPowerSub =
        widget.controller.provider.bandPowerStream.listen((powers) {
      if (!mounted) return;
      setState(() {
        _latestPowers = powers;

        // Compute asymmetry from T7 vs T8 if available
        final left = powers.where((p) =>
            p.channel == 'T7' || p.channel == 'TP9');
        final right = powers.where((p) =>
            p.channel == 'T8' || p.channel == 'TP10');

        if (left.isNotEmpty && right.isNotEmpty) {
          _latestAsymmetry = _processor.computeAsymmetry(
            left.first,
            right.first,
            'alpha',
          );
        }
      });
    });
  }

  @override
  void dispose() {
    _bandPowerSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final device = widget.controller.connectedDevice.value;
    final channels = device?.channels ?? [];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Band meters + Topography
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: EegBandMeter(bandPowers: _latestPowers),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: EegTopography(
                perChannel: _latestPowers,
                channels: channels,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),

        // Raw waveform
        EegRawWave(
          rawStream: widget.controller.provider.rawStream,
          selectedChannel:
              channels.isNotEmpty ? channels.first.name : 'AF3',
        ),
        const SizedBox(height: 12),

        // Asymmetry indicator
        if (_latestAsymmetry != null)
          EegAsymmetryIndicator(asymmetry: _latestAsymmetry!),
      ],
    );
  }
}

/// Drawer showing session timeline.
class _SessionDrawer extends StatefulWidget {
  final dynamic provider;

  const _SessionDrawer({required this.provider});

  @override
  State<_SessionDrawer> createState() => _SessionDrawerState();
}

class _SessionDrawerState extends State<_SessionDrawer> {
  final _recorder = EegSessionRecorder();
  List<EegSession> _sessions = [];

  @override
  void initState() {
    super.initState();
    _loadSessions();
  }

  Future<void> _loadSessions() async {
    final sessions = await _recorder.getSessions();
    if (mounted) setState(() => _sessions = sessions);
  }

  @override
  Widget build(BuildContext context) {
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
              child: EegSessionTimeline(
                sessions: _sessions,
                onTap: (session) {
                  Navigator.pop(context);
                  // TODO: Navigate to session detail
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

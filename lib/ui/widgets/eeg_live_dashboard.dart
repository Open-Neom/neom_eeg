import 'dart:async';

import 'package:flutter/material.dart';
import 'package:sint/sint.dart';

import '../../data/implementations/eeg_calibration_controller.dart';
import '../../data/implementations/eeg_connection_controller.dart';
import '../../data/implementations/eeg_watch_controller.dart';
import '../../domain/enums/eeg_connection_state.dart';
import '../../domain/models/eeg_band_power.dart';
import '../../domain/models/eeg_device_info.dart';
import '../../domain/models/eeg_device_status.dart';
import '../../domain/models/eeg_mental_state.dart';
import 'eeg_band_meter.dart';
import 'eeg_calibration_panel.dart';
import 'eeg_contact_quality_strip.dart';
import 'eeg_device_picker.dart';
import 'eeg_hemispheric_balance.dart';
import 'eeg_live_stats_badge.dart';
import 'eeg_metrics_row.dart';
import 'eeg_raw_wave.dart';
import 'eeg_recording_strip.dart';
import 'eeg_topography.dart';
import 'eeg_watch_strip.dart';

/// Everything the EEG can show, in one self-contained panel driven by the
/// [EegConnectionController] registered in Sint.
///
/// Disconnected it shows the device picker (scan + connect across vendors);
/// connected it shows the headset header, contact quality per electrode,
/// recording controls, the personal baseline and the watcher (when the host
/// registered their controllers), topography, band meters, hemispheric
/// balance, mental metrics and the raw wave. Model-agnostic: every section
/// reads the channel list, the best left/right pair and the excluded
/// electrodes from the connected device.
///
/// Used full-size by [EegMonitorPage] and, with `compact: true`, as the
/// central panel of the Cámara Neom's EEG mode.
class EegLiveDashboard extends StatelessWidget {
  final bool compact;

  /// Hide the device picker's scan controls (e.g. when the host page has
  /// its own connect flow).
  final bool showPickerWhenDisconnected;

  const EegLiveDashboard({
    super.key,
    this.compact = false,
    this.showPickerWhenDisconnected = true,
  });

  @override
  Widget build(BuildContext context) {
    return SintBuilder<EegConnectionController>(
      builder: (controller) => Obx(() {
        final state = controller.state.value;
        final device = controller.connectedDevice.value;
        final connected = device != null &&
            (state == EegConnectionState.streaming ||
                state == EegConnectionState.connected);

        if (!connected) {
          return showPickerWhenDisconnected
              ? const EegDevicePicker()
              : _DisconnectedHint(state: state);
        }
        return _ConnectedDashboard(
          controller: controller,
          device: device,
          compact: compact,
        );
      }),
    );
  }
}

class _DisconnectedHint extends StatelessWidget {
  final EegConnectionState state;
  const _DisconnectedHint({required this.state});

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                state == EegConnectionState.connecting
                    ? Icons.bluetooth_searching
                    : Icons.psychology_outlined,
                color: Colors.white24,
                size: 40,
              ),
              const SizedBox(height: 12),
              Text(
                state == EegConnectionState.connecting
                    ? 'Conectando headset…'
                    : 'Sin headset EEG conectado',
                style: const TextStyle(color: Colors.white38, fontSize: 13),
              ),
            ],
          ),
        ),
      );
}

class _ConnectedDashboard extends StatefulWidget {
  final EegConnectionController controller;
  final EegDeviceInfo device;
  final bool compact;

  const _ConnectedDashboard({
    required this.controller,
    required this.device,
    required this.compact,
  });

  @override
  State<_ConnectedDashboard> createState() => _ConnectedDashboardState();
}

class _ConnectedDashboardState extends State<_ConnectedDashboard> {
  List<EegBandPower> _frame = const [];
  EegMentalState? _mental;
  String? _selectedChannel;
  StreamSubscription<List<EegBandPower>>? _bandSub;
  StreamSubscription<EegMentalState>? _mentalSub;

  @override
  void initState() {
    super.initState();
    _listen();
  }

  @override
  void didUpdateWidget(covariant _ConnectedDashboard old) {
    super.didUpdateWidget(old);
    if (!identical(old.controller.provider, widget.controller.provider) ||
        old.device.id != widget.device.id) {
      _cancel();
      _frame = const [];
      _mental = null;
      _selectedChannel = null;
      _listen();
    }
  }

  void _listen() {
    final provider = widget.controller.provider;
    _bandSub = provider.bandPowerStream.listen((frame) {
      if (mounted) setState(() => _frame = frame);
    });
    _mentalSub = provider.mentalStateStream.listen((m) {
      if (mounted) setState(() => _mental = m);
    });
  }

  void _cancel() {
    _bandSub?.cancel();
    _mentalSub?.cancel();
  }

  @override
  void dispose() {
    _cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final device = widget.device;
    final channels = device.channels;
    final excluded = controller.hub?.excludedChannels.toSet() ?? const <String>{};
    final estimatedMetrics = controller.hub?.activeDriver
            ?.capabilitiesFor(device.type)
            .nativeMentalMetrics ==
        false;
    final selected = _selectedChannel ??
        channels.where((c) => !excluded.contains(c.name)).firstOrNull?.name ??
        channels.firstOrNull?.name ??
        'AF3';

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 720;
        final gap = SizedBox(height: widget.compact ? 8 : 12);

        final header = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Obx(() => _DeviceHeader(
                  device: device,
                  status: controller.status.value,
                  compact: widget.compact,
                  onDisconnect: controller.disconnectDevice,
                )),
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: EegLiveStatsBadge(compact: widget.compact),
            ),
          ],
        );

        final contact = Obx(() => EegContactQualityStrip(
              channels: channels,
              status: controller.status.value,
              compact: widget.compact,
            ));

        final hub = controller.hub;
        final Widget recording = hub == null
            ? const SizedBox.shrink()
            : EegRecordingStrip(
                key: ValueKey('rec-${device.id}'),
                recording: () => hub.recording,
                defaultTitle: () =>
                    '${device.type.displayName} · ${DateTime.now().toLocal().toIso8601String().substring(0, 16)}',
                compact: widget.compact,
              );

        // Personal baseline and watcher are opt-in: the host registers
        // their controllers; without them the sections are simply absent.
        final hasCalibration = Sint.isRegistered<EegCalibrationController>();
        final hasWatch = Sint.isRegistered<EegWatchController>();
        final calibration = EegCalibrationPanel(compact: widget.compact);
        final watch = EegWatchStrip(compact: widget.compact);

        final topography = _Panel(
          title: 'TOPOGRAFÍA · ALFA',
          child: SizedBox(
            height: widget.compact ? 150 : 200,
            child: EegTopography(perChannel: _frame, channels: channels),
          ),
        );

        final bands = EegBandMeter(bandPowers: _visibleFrame(excluded));

        final balance = EegHemisphericBalance(
          frame: _frame,
          excluded: excluded,
        );

        final metrics = EegMetricsRow(
          state: _mental,
          estimated: estimatedMetrics,
          compact: widget.compact,
        );

        final wave = _Panel(
          title: 'SEÑAL CRUDA',
          trailing: _ChannelChips(
            channels: channels.map((c) => c.name).toList(),
            selected: selected,
            excluded: excluded,
            onSelected: (ch) => setState(() => _selectedChannel = ch),
          ),
          child: EegRawWave(
            key: ValueKey('raw-${device.id}-$selected'),
            rawStream: controller.provider.rawStream,
            selectedChannel: selected,
          ),
        );

        if (wide) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              header,
              gap,
              contact,
              gap,
              recording,
              if (hub != null) gap,
              if (hasCalibration || hasWatch) ...[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (hasCalibration) Expanded(child: calibration),
                    if (hasCalibration && hasWatch) const SizedBox(width: 12),
                    if (hasWatch) Expanded(child: watch),
                  ],
                ),
                gap,
              ],
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [topography, gap, balance],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [bands, gap, metrics],
                    ),
                  ),
                ],
              ),
              gap,
              wave,
            ],
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            header,
            gap,
            contact,
            gap,
            recording,
            if (hub != null) gap,
            if (hasCalibration) ...[calibration, gap],
            if (hasWatch) ...[watch, gap],
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: bands),
                const SizedBox(width: 10),
                Expanded(child: topography),
              ],
            ),
            gap,
            balance,
            gap,
            metrics,
            gap,
            wave,
          ],
        );
      },
    );
  }

  /// Band meter averages across channels; leave out the electrodes the hub
  /// excluded so the panel agrees with what the hub publishes.
  List<EegBandPower> _visibleFrame(Set<String> excluded) =>
      excluded.isEmpty ? _frame : _frame.where((b) => !excluded.contains(b.channel)).toList();
}

class _DeviceHeader extends StatelessWidget {
  final EegDeviceInfo device;
  final EegDeviceStatus? status;
  final bool compact;
  final VoidCallback onDisconnect;

  const _DeviceHeader({
    required this.device,
    required this.status,
    required this.compact,
    required this.onDisconnect,
  });

  @override
  Widget build(BuildContext context) {
    final battery = status?.battery;
    return Container(
      padding: EdgeInsets.all(compact ? 10 : 12),
      decoration: BoxDecoration(
        color: Colors.green.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.green.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          const Icon(Icons.bluetooth_connected, color: Colors.green, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  device.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Wrap(
                  spacing: 6,
                  runSpacing: 2,
                  children: [
                    _Tag(device.vendor.displayName),
                    _Tag(device.type.displayName),
                    _Tag('${device.channels.length} ch · ${device.sampleRate} Hz'),
                    if (device.transport != null)
                      _Tag(device.transport!.displayName),
                  ],
                ),
              ],
            ),
          ),
          if (battery != null) ...[
            Icon(
              battery > 0.6
                  ? Icons.battery_full
                  : battery > 0.2
                      ? Icons.battery_4_bar
                      : Icons.battery_alert,
              size: 18,
              color: battery > 0.2 ? Colors.white54 : Colors.redAccent,
            ),
            Text(
              '${(battery * 100).round()}%',
              style: const TextStyle(color: Colors.white54, fontSize: 11),
            ),
            const SizedBox(width: 4),
          ],
          IconButton(
            icon: const Icon(Icons.link_off, color: Colors.redAccent, size: 20),
            onPressed: onDisconnect,
            tooltip: 'Desconectar',
          ),
        ],
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  final String text;
  const _Tag(this.text);

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: Colors.white10,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          text,
          style: const TextStyle(color: Colors.white54, fontSize: 10),
        ),
      );
}

class _Panel extends StatelessWidget {
  final String title;
  final Widget child;
  final Widget? trailing;

  const _Panel({required this.title, required this.child, this.trailing});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A2E),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      color: Colors.white38,
                      fontSize: 10,
                      letterSpacing: 1.5,
                    ),
                  ),
                ),
                ?trailing,
              ],
            ),
            const SizedBox(height: 6),
            child,
          ],
        ),
      );
}

class _ChannelChips extends StatelessWidget {
  final List<String> channels;
  final String selected;
  final Set<String> excluded;
  final ValueChanged<String> onSelected;

  const _ChannelChips({
    required this.channels,
    required this.selected,
    required this.excluded,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) => Wrap(
        spacing: 4,
        children: [
          for (final ch in channels)
            GestureDetector(
              onTap: () => onSelected(ch),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: ch == selected
                      ? const Color(0xFF1E88E5).withValues(alpha: 0.35)
                      : Colors.white10,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  ch,
                  style: TextStyle(
                    color: excluded.contains(ch)
                        ? Colors.redAccent
                        : ch == selected
                            ? Colors.white
                            : Colors.white54,
                    fontSize: 10,
                    decoration:
                        excluded.contains(ch) ? TextDecoration.lineThrough : null,
                  ),
                ),
              ),
            ),
        ],
      );
}

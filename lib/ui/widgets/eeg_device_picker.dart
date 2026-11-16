import 'dart:async';

import 'package:flutter/material.dart';
import 'package:sint/sint.dart';

import '../../data/implementations/eeg_connection_controller.dart';
import '../../domain/enums/eeg_connection_state.dart';
import '../../domain/enums/eeg_device_type.dart';
import '../../domain/enums/eeg_vendor.dart';
import '../../domain/models/eeg_device_info.dart';

/// Device scanner and picker widget.
///
/// Shows scanning state, found devices as tappable tiles,
/// and connection/disconnection controls.
class EegDevicePicker extends StatefulWidget {
  const EegDevicePicker({super.key});

  @override
  State<EegDevicePicker> createState() => _EegDevicePickerState();
}

class _EegDevicePickerState extends State<EegDevicePicker> {
  @override
  Widget build(BuildContext context) {
    return SintBuilder<EegConnectionController>(
      builder: (controller) {
        return Obx(() {
          final state = controller.state.value;
          final devices = controller.foundDevices;
          final connected = controller.connectedDevice.value;

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Connected device banner
              if (connected != null) ...[
                _ConnectedBanner(
                  device: connected,
                  onDisconnect: () => controller.disconnectDevice(),
                ),
                const SizedBox(height: 12),
              ],

              // Scan button
              if (state != EegConnectionState.streaming)
                ElevatedButton.icon(
                  onPressed: controller.isScanning.value
                      ? null
                      : () => controller.scanDevices(),
                  icon: controller.isScanning.value
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.bluetooth_searching),
                  label: Text(
                    controller.isScanning.value
                        ? 'Buscando dispositivos...'
                        : 'Buscar dispositivos EEG',
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1E88E5),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),

              const SizedBox(height: 12),

              // Pending SDK approval (Cortex: approve app in EMOTIV Launcher)
              if (controller.pendingMessage.value != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    controller.pendingMessage.value!,
                    style: const TextStyle(color: Colors.amber, fontSize: 13),
                  ),
                ),

              // Error state
              if (state == EegConnectionState.error)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    controller.lastError.value ??
                        'Error de conexión. Intente de nuevo.',
                    style: const TextStyle(color: Colors.redAccent, fontSize: 13),
                  ),
                ),

              // Device list, grouped by vendor
              if (devices.isNotEmpty && connected == null)
                ..._groupedByVendor(devices).entries.expand((group) => [
                      _VendorHeader(vendor: group.key),
                      ...group.value.map((device) => _DeviceTile(
                            device: device,
                            isConnecting:
                                state == EegConnectionState.connecting,
                            onTap: () => _connectDevice(controller, device),
                          )),
                    ]),

              // Vendors the hub could not reach (no Launcher, driver pending…)
              if (!controller.isScanning.value &&
                  connected == null &&
                  (controller.skippedVendors.isNotEmpty ||
                      controller.failedVendors.isNotEmpty))
                _UnreachableVendors(
                  skipped: controller.skippedVendors,
                  failed: controller.failedVendors,
                ),

              // Empty state
              if (devices.isEmpty &&
                  !controller.isScanning.value &&
                  connected == null)
                const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'No se encontraron dispositivos.\nAsegúrese de que su headset esté encendido.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white38, fontSize: 13),
                    ),
                  ),
                ),
            ],
          );
        });
      },
    );
  }

  Map<EegVendor, List<EegDeviceInfo>> _groupedByVendor(
    List<EegDeviceInfo> devices,
  ) {
    final map = <EegVendor, List<EegDeviceInfo>>{};
    for (final d in devices) {
      map.putIfAbsent(d.vendor, () => []).add(d);
    }
    return map;
  }

  Future<void> _connectDevice(
    EegConnectionController controller,
    EegDeviceInfo device,
  ) async {
    // The progress dialog must not be awaited: with barrierDismissible false
    // it only closes when we pop it after the connection settles.
    var dialogOpen = true;
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        title: const Text(
          'Conectando...',
          style: TextStyle(color: Colors.white),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(
              device.name,
              style: const TextStyle(color: Colors.white70),
            ),
            // Cortex asks the user to approve the app in EMOTIV Launcher;
            // surface that here instead of leaving a silent spinner.
            Obx(() {
              final pending = controller.pendingMessage.value;
              if (pending == null) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  pending,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.amber, fontSize: 12),
                ),
              );
            }),
          ],
        ),
      ),
    ).whenComplete(() => dialogOpen = false));

    await controller.connectDevice(device);

    if (dialogOpen) Sint.pop();
    if (!mounted) return;

    if (controller.state.value == EegConnectionState.streaming) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Conectado a ${device.name}'),
          backgroundColor: Colors.green,
        ),
      );
    }
  }
}

class _VendorHeader extends StatelessWidget {
  final EegVendor vendor;

  const _VendorHeader({required this.vendor});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 4, left: 4),
      child: Text(
        vendor.displayName.toUpperCase(),
        style: const TextStyle(
          color: Colors.white38,
          fontSize: 11,
          letterSpacing: 1.2,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _UnreachableVendors extends StatelessWidget {
  final Map<EegVendor, String> skipped;
  final Map<EegVendor, String> failed;

  const _UnreachableVendors({required this.skipped, required this.failed});

  @override
  Widget build(BuildContext context) {
    final rows = <MapEntry<EegVendor, String>>[
      ...failed.entries,
      ...skipped.entries,
    ];
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'No consultados',
            style: TextStyle(color: Colors.white38, fontSize: 11),
          ),
          const SizedBox(height: 4),
          for (final e in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    failed.containsKey(e.key)
                        ? Icons.error_outline
                        : Icons.info_outline,
                    size: 14,
                    color: failed.containsKey(e.key)
                        ? Colors.redAccent
                        : Colors.white38,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '${e.key.displayName}: ${e.value}',
                      style: const TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _ConnectedBanner extends StatelessWidget {
  final EegDeviceInfo device;
  final VoidCallback onDisconnect;

  const _ConnectedBanner({required this.device, required this.onDisconnect});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.green.withValues(alpha: 0.15),
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
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  '${device.type.displayName} · ${device.sampleRate} Hz',
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.link_off, color: Colors.redAccent),
            onPressed: onDisconnect,
            tooltip: 'Desconectar',
          ),
        ],
      ),
    );
  }
}

class _DeviceTile extends StatelessWidget {
  final EegDeviceInfo device;
  final bool isConnecting;
  final VoidCallback onTap;

  const _DeviceTile({
    required this.device,
    required this.isConnecting,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color(0xFF1A1A2E),
      margin: const EdgeInsets.only(bottom: 6),
      child: ListTile(
        leading: Icon(
          _iconForType(device.type),
          color: const Color(0xFF64B5F6),
        ),
        title: Text(
          device.name,
          style: const TextStyle(color: Colors.white),
        ),
        subtitle: Text(
          '${device.type.displayName} · ${device.channels.length} ch · '
          '${device.sampleRate} Hz',
          style: const TextStyle(color: Colors.white54, fontSize: 12),
        ),
        trailing: _SignalBars(quality: device.signalQuality),
        onTap: isConnecting ? null : onTap,
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
}

class _SignalBars extends StatelessWidget {
  final double quality;

  const _SignalBars({required this.quality});

  @override
  Widget build(BuildContext context) {
    final bars = (quality * 4).round().clamp(0, 4);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(4, (i) {
        return Container(
          width: 4,
          height: 6.0 + i * 4.0,
          margin: const EdgeInsets.symmetric(horizontal: 1),
          decoration: BoxDecoration(
            color: i < bars ? Colors.green : Colors.white12,
            borderRadius: BorderRadius.circular(1),
          ),
        );
      }),
    );
  }
}

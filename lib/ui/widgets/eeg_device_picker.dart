import 'package:flutter/material.dart';
import 'package:sint/sint.dart';

import '../../data/implementations/eeg_connection_controller.dart';
import '../../domain/enums/eeg_connection_state.dart';
import '../../domain/enums/eeg_device_type.dart';
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

              // Error state
              if (state == EegConnectionState.error)
                const Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: Text(
                    'Error de conexión. Intente de nuevo.',
                    style: TextStyle(color: Colors.redAccent, fontSize: 13),
                  ),
                ),

              // Device list
              if (devices.isNotEmpty && connected == null)
                ...devices.map((device) => _DeviceTile(
                      device: device,
                      isConnecting:
                          state == EegConnectionState.connecting,
                      onTap: () => _connectDevice(controller, device),
                    )),

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

  Future<void> _connectDevice(
    EegConnectionController controller,
    EegDeviceInfo device,
  ) async {
    await showDialog(
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
          ],
        ),
      ),
    );

    await controller.connectDevice(device);

    if (mounted) {
      Navigator.of(context).pop();

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

  IconData _iconForType(EegDeviceType type) {
    switch (type) {
      case EegDeviceType.emotivEpocX:
      case EegDeviceType.emotivInsight:
      case EegDeviceType.emotivMn8:
        return Icons.headset;
      case EegDeviceType.muse:
        return Icons.self_improvement;
      case EegDeviceType.neurosky:
        return Icons.psychology;
      case EegDeviceType.brainbit:
      case EegDeviceType.openbci:
        return Icons.memory;
      case EegDeviceType.simulated:
        return Icons.bug_report;
    }
  }
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

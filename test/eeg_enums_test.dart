// Tests for EEG enums (`EegStreamType`, `EegConnectionState`, `EegDeviceType`).

import 'package:flutter_test/flutter_test.dart';
import 'package:neom_eeg/domain/enums/eeg_stream_type.dart';
import 'package:neom_eeg/domain/enums/eeg_connection_state.dart';
import 'package:neom_eeg/domain/enums/eeg_device_type.dart';

void main() {
  group('EegStreamType enum', () {
    test('tiene 5 tipos de stream', () {
      expect(EegStreamType.values.length, 5);
    });

    test('contiene tipos esperados', () {
      expect(EegStreamType.values, containsAll([
        EegStreamType.raw,
        EegStreamType.bandPower,
        EegStreamType.metrics,
        EegStreamType.motion,
        EegStreamType.quality,
      ]));
    });
  });

  group('EegConnectionState enum', () {
    test('tiene 6 estados de conexión', () {
      expect(EegConnectionState.values.length, 6);
    });

    test('contiene los estados del lifecycle BLE', () {
      expect(EegConnectionState.values, containsAll([
        EegConnectionState.disconnected,
        EegConnectionState.scanning,
        EegConnectionState.connecting,
        EegConnectionState.connected,
        EegConnectionState.streaming,
        EegConnectionState.error,
      ]));
    });

    test('disconnected es el primero (estado inicial)', () {
      expect(EegConnectionState.values.first, EegConnectionState.disconnected);
    });
  });

  group('EegDeviceType enum', () {
    test('tiene 8 dispositivos soportados', () {
      expect(EegDeviceType.values.length, 8);
    });

    test('cada dispositivo tiene channelCount > 0', () {
      for (final dev in EegDeviceType.values) {
        expect(dev.channelCount, greaterThan(0),
            reason: '${dev.displayName} debería tener canales');
      }
    });

    test('cada dispositivo tiene sampleRate sano (> 100 Hz)', () {
      for (final dev in EegDeviceType.values) {
        expect(dev.sampleRate, greaterThanOrEqualTo(128),
            reason: '${dev.displayName} debería muestrear >= 128 Hz');
      }
    });

    test('valores específicos esperados', () {
      expect(EegDeviceType.emotivEpocX.channelCount, 14);
      expect(EegDeviceType.muse.channelCount, 4);
      expect(EegDeviceType.neurosky.channelCount, 1);
      expect(EegDeviceType.openbci.sampleRate, 250);
      expect(EegDeviceType.simulated.displayName, 'Simulated Device');
    });

    test('todos los displayName son únicos', () {
      final names = EegDeviceType.values.map((d) => d.displayName).toSet();
      expect(names.length, EegDeviceType.values.length);
    });
  });
}

// Tests for EEG enums (`EegStreamType`, `EegConnectionState`, `EegDeviceType`).

import 'package:flutter_test/flutter_test.dart';
import 'package:neom_eeg/domain/enums/eeg_stream_type.dart';
import 'package:neom_eeg/domain/enums/eeg_connection_state.dart';
import 'package:neom_eeg/domain/enums/eeg_device_type.dart';
import 'package:neom_eeg/domain/enums/eeg_vendor.dart';

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
    test('tiene 12 modelos soportados', () {
      expect(EegDeviceType.values.length, 12);
    });

    test('cada modelo pertenece a un vendor y cada vendor tiene modelos', () {
      for (final vendor in EegVendor.values) {
        expect(EegDeviceType.ofVendor(vendor), isNotEmpty,
            reason: '${vendor.displayName} debería tener al menos un modelo');
      }
      expect(EegDeviceType.emotivInsight.vendor, EegVendor.emotiv);
      expect(EegDeviceType.muse.vendor, EegVendor.interaxon);
      expect(EegDeviceType.openbciGanglion.vendor, EegVendor.openbci);
    });

    test('resuelve modelos Emotiv desde ids de Cortex', () {
      expect(EegDeviceType.fromCortexId('INSIGHT-A1B2C3D4'),
          EegDeviceType.emotivInsight);
      expect(EegDeviceType.fromCortexId('EPOCX-E5020A3F'),
          EegDeviceType.emotivEpocX);
      expect(EegDeviceType.fromCortexId('EPOCPLUS-3B9AXXXX'),
          EegDeviceType.emotivEpocPlus);
      expect(EegDeviceType.fromCortexId('EPOCFLEX-1234'),
          EegDeviceType.emotivEpocFlex);
      expect(EegDeviceType.fromCortexId('MN8-0001'), EegDeviceType.emotivMn8);
      expect(EegDeviceType.fromCortexId('EPOC'), EegDeviceType.emotivEpocX);
      expect(EegDeviceType.fromCortexId('Muse-1234'), isNull);
    });

    test('cada dispositivo tiene channelCount > 0', () {
      for (final dev in EegDeviceType.values) {
        expect(dev.channelCount, greaterThan(0),
            reason: '${dev.displayName} debería tener canales');
      }
    });

    test('cada dispositivo tiene sampleRate sano (>= 125 Hz)', () {
      // Cyton + Daisy multiplexa 16 canales a 125 Hz; es el mínimo real.
      for (final dev in EegDeviceType.values) {
        expect(dev.sampleRate, greaterThanOrEqualTo(125),
            reason: '${dev.displayName} debería muestrear >= 125 Hz');
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

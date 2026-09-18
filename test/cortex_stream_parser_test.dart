// Column layouts below are copied from the Cortex API reference
// (https://emotiv.gitbook.io/cortex-api/data-subscription/data-sample-object)
// so a change in how Emotiv orders columns shows up here first.

import 'package:flutter_test/flutter_test.dart';
import 'package:neom_eeg/data/providers/emotiv/cortex_stream_parser.dart';
import 'package:neom_eeg/domain/models/eeg_device_status.dart';

void main() {
  const insightEegCols = [
    'COUNTER', 'INTERPOLATED', 'AF3', 'T7', 'Pz', 'T8', 'AF4',
    'RAW_CQ', 'MARKER_HARDWARE', 'MARKERS',
  ];
  const epocEegCols = [
    'COUNTER', 'INTERPOLATED',
    'AF3', 'F7', 'F3', 'FC5', 'T7', 'P7', 'O1', 'O2', 'P8', 'T8', 'FC6',
    'F4', 'F8', 'AF4',
    'RAW_CQ', 'MARKER_HARDWARE', 'MARKERS',
  ];

  group('eeg', () {
    test('skips COUNTER/INTERPOLATED and trailing markers on Insight', () {
      final sample = CortexStreamParser.parseEeg(
        cols: insightEegCols,
        values: [12, 0, 4100.1, 4200.2, 4300.3, 4400.4, 4500.5, 0, 0, []],
        time: 1700000000.5,
      );

      expect(sample, isNotNull);
      expect(sample!.channels.keys, ['AF3', 'T7', 'Pz', 'T8', 'AF4']);
      expect(sample.channels['AF3'], 4100.1);
      expect(sample.channels['AF4'], 4500.5);
      expect(sample.channels.containsKey('COUNTER'), isFalse);
      expect(sample.timestamp.toUtc(),
          DateTime.utc(2023, 11, 14, 22, 13, 20, 500));
    });

    test('handles the 14-channel EPOC layout with the same code', () {
      final values = [
        1, 0,
        ...List.generate(14, (i) => 4000.0 + i),
        0, 0, [],
      ];
      final sample = CortexStreamParser.parseEeg(
        cols: epocEegCols,
        values: values,
      );
      expect(sample!.channels.length, 14);
      expect(sample.channels['O1'], 4006.0);
      expect(sample.channels['AF4'], 4013.0);
    });

    test('attaches contact quality only for known channels', () {
      final sample = CortexStreamParser.parseEeg(
        cols: insightEegCols,
        values: [1, 0, 1, 2, 3, 4, 5, 0, 0, []],
        quality: const {'AF3': 1.0, 'T7': 0.5, 'Oz': 0.2},
      );
      expect(sample!.quality, {'AF3': 1.0, 'T7': 0.5});
    });

    test('returns null when no sensor column carries a number', () {
      expect(
        CortexStreamParser.parseEeg(cols: insightEegCols, values: [1, 0]),
        isNull,
      );
    });

    test('sensorLabels lists electrodes in stream order', () {
      expect(CortexStreamParser.sensorLabels(insightEegCols),
          ['AF3', 'T7', 'Pz', 'T8', 'AF4']);
    });
  });

  group('pow', () {
    const cols = [
      'AF3/theta', 'AF3/alpha', 'AF3/betaL', 'AF3/betaH', 'AF3/gamma',
      'T7/theta', 'T7/alpha', 'T7/betaL', 'T7/betaH', 'T7/gamma',
    ];

    test('maps theta/alpha/betaL/betaH/gamma per sensor, delta is 0', () {
      final powers = CortexStreamParser.parsePow(
        cols: cols,
        values: [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0],
      );

      expect(powers.map((p) => p.channel), ['AF3', 'T7']);
      final af3 = powers.first;
      expect(af3.theta, 1.0);
      expect(af3.alpha, 2.0);
      expect(af3.betaLow, 3.0);
      expect(af3.betaHigh, 4.0);
      expect(af3.gamma, 5.0);
      expect(af3.delta, 0.0);
      expect(powers.last.gamma, 10.0);
    });

    test('tolerates truncated value arrays', () {
      final powers = CortexStreamParser.parsePow(
        cols: cols,
        values: [1.0, 2.0, 3.0],
      );
      expect(powers.length, 1);
      expect(powers.first.betaHigh, 0.0);
    });
  });

  group('met', () {
    const epocCols = [
      'eng.isActive', 'eng', 'exc.isActive', 'exc', 'lex',
      'str.isActive', 'str', 'rel.isActive', 'rel',
      'int.isActive', 'int', 'foc.isActive', 'foc',
    ];

    test('reads values by label, ignoring isActive flags and lex', () {
      final m = CortexStreamParser.parseMet(
        cols: epocCols,
        values: [true, 0.61, true, 0.42, 0.5, true, 0.33, true, 0.71,
          true, 0.5, true, 0.8],
      );
      expect(m, isNotNull);
      expect(m!.engagement, 0.61);
      expect(m.excitement, 0.42);
      expect(m.stress, 0.33);
      expect(m.relaxation, 0.71);
      expect(m.focus, 0.8);
    });

    test('newer builds name focus "attention"', () {
      final cols = [...epocCols]
        ..[11] = 'attention.isActive'
        ..[12] = 'attention';
      final m = CortexStreamParser.parseMet(
        cols: cols,
        values: [true, 0.1, true, 0.2, 0.3, true, 0.4, true, 0.5,
          true, 0.6, true, 0.9],
      );
      expect(m!.focus, 0.9);
    });

    test('MN8 layout maps attention/cognitiveStress', () {
      final m = CortexStreamParser.parseMet(
        cols: const ['attention.isActive', 'attention',
          'cognitiveStress.isActive', 'cognitiveStress'],
        values: [true, 0.7, true, 0.2],
      );
      expect(m!.focus, 0.7);
      expect(m.stress, 0.2);
      expect(m.engagement, 0.0);
    });

    test('null while detections warm up yields null state', () {
      final m = CortexStreamParser.parseMet(
        cols: epocCols,
        values: [false, null, false, null, null, false, null, false, null,
          false, null, false, null],
      );
      expect(m, isNull);
    });
  });

  group('dev', () {
    test('normalises battery, signal, per-sensor CQ and OVERALL', () {
      final s = CortexStreamParser.parseDev(
        cols: const ['Battery', 'Signal',
          ['AF3', 'T7', 'Pz', 'T8', 'AF4', 'OVERALL'], 'BatteryPercent'],
        values: [3, 0.8, [4, 2, 0, 4, 1, 75], 87],
      );
      expect(s.battery, closeTo(0.87, 1e-9));
      expect(s.wirelessSignal, 0.8);
      expect(s.contactQuality['AF3'], 1.0);
      expect(s.contactQuality['T7'], 0.5);
      expect(s.contactQuality['Pz'], 0.0);
      expect(s.contactQuality.containsKey('OVERALL'), isFalse);
      expect(s.overallQuality, 0.75);
      expect(s.poorContacts(), ['Pz', 'AF4']);
    });

    test('falls back to the 0-4 Battery scale without BatteryPercent', () {
      final s = CortexStreamParser.parseDev(
        cols: const ['Battery', 'Signal', ['AF3', 'OVERALL']],
        values: [2, 1.0, [4, 100]],
      );
      expect(s.battery, 0.5);
    });
  });

  group('eq', () {
    test('overrides contact map and keeps wireless signal from previous', () {
      final previous = EegDeviceStatus(
        wirelessSignal: 0.9,
        contactQuality: const {'AF3': 0.25},
        timestamp: DateTime.now(),
      );
      final s = CortexStreamParser.parseEq(
        cols: const ['batteryPercent', 'overall', 'sampleRateQuality',
          'AF3', 'T7'],
        values: [60, 80, -1, 4, 3],
        previous: previous,
      );
      expect(s.battery, closeTo(0.6, 1e-9));
      expect(s.overallQuality, closeTo(0.8, 1e-9));
      expect(s.wirelessSignal, 0.9);
      expect(s.contactQuality['AF3'], 1.0);
      expect(s.contactQuality['T7'], 0.75);
      expect(s.contactQuality.containsKey('sampleRateQuality'), isFalse);
    });
  });
}

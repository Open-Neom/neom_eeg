import 'package:flutter_test/flutter_test.dart';
import 'package:neom_eeg/domain/enums/eeg_device_type.dart';
import 'package:neom_eeg/domain/models/eeg_session_capture.dart';

EegCaptureRow row(double t, {double alpha = 10, double beta = 4, int frames = 4}) => EegCaptureRow(
      t: t,
      delta: 1,
      theta: 2,
      alpha: alpha,
      betaLow: beta * 0.75,
      betaHigh: beta * 0.25,
      gamma: 0.5,
      samples: frames == 0 ? 0 : 128,
      frames: frames,
    );

EegSessionCapture capture(List<EegCaptureRow> rows, {List<EegAlertNote> alerts = const []}) =>
    EegSessionCapture(
      id: 'cap',
      deviceType: EegDeviceType.emotivInsight,
      deviceName: 'Insight',
      channels: const ['AF3', 'T7', 'Pz', 'T8', 'AF4'],
      sampleRate: 128,
      startedAt: DateTime(2026, 9, 21, 8),
      endedAt: DateTime(2026, 9, 21, 8).add(Duration(seconds: rows.length)),
      rows: rows,
      alerts: alerts,
    );

void main() {
  group('entrainmentIndex', () {
    test('compares the alpha share of the last third with the first third', () {
      // 30 s: alpha 10 for the first 10 s, ramps, alpha 20 for the last 10 s.
      final rows = [
        for (var t = 0; t < 30; t++) row(t.toDouble(), alpha: t < 10 ? 10 : t < 20 ? 15 : 20),
      ];
      final c = capture(rows);
      final startShare = 10 / (1 + 2 + 10 + 4 + 0.5);
      final endShare = 20 / (1 + 2 + 20 + 4 + 0.5);
      expect(c.entrainmentIndex('alpha'), closeTo(endShare / startShare, 1e-9));
      // Beta lost share as alpha gained it.
      expect(c.entrainmentIndex('beta'), lessThan(1.0));
    });

    test('ignores seconds without frames and needs at least six of them', () {
      final rows = [
        for (var t = 0; t < 5; t++) row(t.toDouble()),
        for (var t = 5; t < 40; t++) row(t.toDouble(), frames: 0),
      ];
      expect(capture(rows).entrainmentIndex('alpha'), isNull);

      final enough = [for (var t = 0; t < 6; t++) row(t.toDouble())];
      expect(capture(enough).entrainmentIndex('alpha'), closeTo(1.0, 1e-9));
    });

    test('bandShareAt is null for an empty second', () {
      final c = capture([row(0)]);
      expect(c.bandShareAt(row(0, frames: 0), 'alpha'), isNull);
      expect(c.bandShareAt(row(0), 'beta'), closeTo(4 / 17.5, 1e-9));
    });
  });

  group('alerts in the capture', () {
    test('round-trip through JSON and survive an older capture without them', () {
      final c = capture(
        [row(0), row(1)],
        alerts: const [
          EegAlertNote(
            t: 12.5,
            ruleId: 'asymmetry_sustained',
            label: 'Asimetría hemisférica',
            severity: 'warning',
            value: 0.31,
            threshold: 0.2,
            sustainedSeconds: 10.2,
            markerAdded: true,
          ),
        ],
      );
      final back = EegSessionCapture.fromJson(c.toJson());
      expect(back.alerts.length, 1);
      expect(back.alerts.first.ruleId, 'asymmetry_sustained');
      expect(back.alerts.first.markerAdded, isTrue);
      expect(back.alerts.first.sustainedSeconds, 10.2);

      final legacy = Map<String, dynamic>.from(c.toJson())..remove('alerts');
      expect(EegSessionCapture.fromJson(legacy).alerts, isEmpty);
    });
  });
}

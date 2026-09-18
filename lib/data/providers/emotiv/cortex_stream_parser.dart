import '../../../domain/models/eeg_band_power.dart';
import '../../../domain/models/eeg_device_status.dart';
import '../../../domain/models/eeg_mental_state.dart';
import '../../../domain/models/eeg_sample.dart';

/// Pure translation of Cortex data samples into neom_eeg models.
///
/// Cortex describes every subscribed stream with a `cols` array in the
/// `subscribe` result and then sends positional arrays (`{"eeg": [...],
/// "sid": "...", "time": 1.7e9}`). Parsing by column name instead of by
/// position is what makes one code path work for Insight (5 ch), EPOC X
/// (14 ch), Flex (32 ch) and MN8 (2 ch), and keeps it working when Emotiv
/// adds columns.
///
/// Reference layouts (Cortex 2.x/3.x/4.x):
/// * `eeg`: `COUNTER, INTERPOLATED, <sensors…>, RAW_CQ, MARKER_HARDWARE, MARKERS`
/// * `pow`: `<sensor>/theta, <sensor>/alpha, <sensor>/betaL, <sensor>/betaH, <sensor>/gamma, …`
/// * `met`: `eng.isActive, eng, exc.isActive, exc, lex, str.isActive, str,
///   rel.isActive, rel, int.isActive, int, foc.isActive, foc`
///   (newer builds rename `foc` to `attention`; MN8 sends
///   `attention, cognitiveStress`)
/// * `dev`: `Battery, Signal, [<sensors…>, OVERALL], BatteryPercent`
/// * `eq`:  `batteryPercent, overall, sampleRateQuality, <sensors…>`
class CortexStreamParser {
  CortexStreamParser._();

  /// `eeg` columns that are not electrodes.
  static const reservedEegColumns = {
    'COUNTER',
    'INTERPOLATED',
    'RAW_CQ',
    'MARKER_HARDWARE',
    'MARKERS',
    'TIMESTAMP',
  };

  /// Cortex `time` is seconds since the Unix epoch (with fraction).
  static DateTime timestamp(num? seconds) => seconds == null
      ? DateTime.now()
      : DateTime.fromMicrosecondsSinceEpoch((seconds * 1e6).round());

  /// Electrode labels in the order the `eeg` stream carries them.
  static List<String> sensorLabels(List<dynamic> eegCols) => [
        for (final c in eegCols)
          if (c is String && !reservedEegColumns.contains(c.toUpperCase())) c,
      ];

  static EegSample? parseEeg({
    required List<dynamic> cols,
    required List<dynamic> values,
    num? time,
    Map<String, double> quality = const {},
  }) {
    final channels = <String, double>{};
    final n = cols.length < values.length ? cols.length : values.length;
    for (var i = 0; i < n; i++) {
      final col = cols[i];
      if (col is! String || reservedEegColumns.contains(col.toUpperCase())) {
        continue;
      }
      final v = values[i];
      if (v is num) channels[col] = v.toDouble();
    }
    if (channels.isEmpty) return null;

    return EegSample(
      timestamp: timestamp(time),
      channels: channels,
      quality: {
        for (final ch in channels.keys)
          if (quality.containsKey(ch)) ch: quality[ch]!,
      },
    );
  }

  /// Cortex does not expose a delta band; [EegBandPower.delta] is 0 for
  /// device-computed powers. The hub can derive delta from raw EEG when a
  /// consumer needs it.
  static List<EegBandPower> parsePow({
    required List<dynamic> cols,
    required List<dynamic> values,
    num? time,
  }) {
    final perSensor = <String, Map<String, double>>{};
    final order = <String>[];
    final n = cols.length < values.length ? cols.length : values.length;

    for (var i = 0; i < n; i++) {
      final col = cols[i];
      final v = values[i];
      if (col is! String || v is! num) continue;
      final slash = col.indexOf('/');
      if (slash <= 0) continue;
      final sensor = col.substring(0, slash);
      final band = col.substring(slash + 1).toLowerCase();
      if (!perSensor.containsKey(sensor)) order.add(sensor);
      perSensor.putIfAbsent(sensor, () => {})[band] = v.toDouble();
    }

    final ts = timestamp(time);
    return [
      for (final sensor in order)
        EegBandPower(
          channel: sensor,
          delta: perSensor[sensor]!['delta'] ?? 0.0,
          theta: perSensor[sensor]!['theta'] ?? 0.0,
          alpha: perSensor[sensor]!['alpha'] ?? 0.0,
          betaLow: perSensor[sensor]!['betal'] ?? 0.0,
          betaHigh: perSensor[sensor]!['betah'] ?? 0.0,
          gamma: perSensor[sensor]!['gamma'] ?? 0.0,
          timestamp: ts,
        ),
    ];
  }

  /// Null when no metric column carried a value (all detections inactive).
  static EegMentalState? parseMet({
    required List<dynamic> cols,
    required List<dynamic> values,
    num? time,
  }) {
    final metrics = <String, double>{};
    final n = cols.length < values.length ? cols.length : values.length;
    var any = false;

    for (var i = 0; i < n; i++) {
      final col = cols[i];
      if (col is! String || col.endsWith('.isActive')) continue;
      final v = values[i];
      if (v is! num) continue; // null while the detection warms up
      any = true;
      switch (col) {
        case 'eng':
          metrics['engagement'] = v.toDouble();
        case 'exc':
          metrics['excitement'] = v.toDouble();
        case 'str':
        case 'cognitiveStress':
          metrics['stress'] = v.toDouble();
        case 'rel':
          metrics['relaxation'] = v.toDouble();
        case 'foc':
        case 'attention':
          metrics['focus'] = v.toDouble();
        case 'int':
          metrics['interest'] = v.toDouble();
        case 'lex':
          metrics['longTermExcitement'] = v.toDouble();
      }
    }
    if (!any) return null;

    return EegMentalState(
      engagement: metrics['engagement'] ?? 0.0,
      relaxation: metrics['relaxation'] ?? 0.0,
      stress: metrics['stress'] ?? 0.0,
      focus: metrics['focus'] ?? 0.0,
      excitement: metrics['excitement'] ?? 0.0,
      timestamp: timestamp(time),
    );
  }

  static EegDeviceStatus parseDev({
    required List<dynamic> cols,
    required List<dynamic> values,
    num? time,
  }) {
    double? battery;
    double? signal;
    double? overall;
    final contact = <String, double>{};
    final n = cols.length < values.length ? cols.length : values.length;

    for (var i = 0; i < n; i++) {
      final col = cols[i];
      final v = values[i];
      if (col is List && v is List) {
        final m = col.length < v.length ? col.length : v.length;
        for (var j = 0; j < m; j++) {
          final label = col[j];
          final q = v[j];
          if (label is! String || q is! num) continue;
          if (label.toUpperCase() == 'OVERALL') {
            overall = (q / 100.0).clamp(0.0, 1.0);
          } else {
            contact[label] = (q / 4.0).clamp(0.0, 1.0);
          }
        }
      } else if (col is String && v is num) {
        switch (col) {
          case 'BatteryPercent':
            battery = (v / 100.0).clamp(0.0, 1.0);
          case 'Battery':
            battery ??= (v / 4.0).clamp(0.0, 1.0);
          case 'Signal':
            signal = v.toDouble().clamp(0.0, 1.0);
        }
      }
    }

    return EegDeviceStatus(
      battery: battery,
      wirelessSignal: signal,
      contactQuality: contact,
      overallQuality: overall,
      timestamp: timestamp(time),
    );
  }

  /// `eq` refines the contact map with EEG-quality scores; fields it does
  /// not carry (wireless signal) are taken from [previous].
  static EegDeviceStatus parseEq({
    required List<dynamic> cols,
    required List<dynamic> values,
    num? time,
    EegDeviceStatus? previous,
  }) {
    double? battery = previous?.battery;
    double? overall = previous?.overallQuality;
    final contact = <String, double>{...?previous?.contactQuality};
    final n = cols.length < values.length ? cols.length : values.length;

    for (var i = 0; i < n; i++) {
      final col = cols[i];
      final v = values[i];
      if (col is! String || v is! num) continue;
      switch (col) {
        case 'batteryPercent':
          battery = (v / 100.0).clamp(0.0, 1.0);
        case 'overall':
          overall = (v / 100.0).clamp(0.0, 1.0);
        case 'sampleRateQuality':
          break; // -1 flags data loss; not a per-electrode value
        default:
          contact[col] = (v / 4.0).clamp(0.0, 1.0);
      }
    }

    return EegDeviceStatus(
      battery: battery,
      wirelessSignal: previous?.wirelessSignal,
      contactQuality: contact,
      overallQuality: overall,
      timestamp: timestamp(time),
    );
  }
}

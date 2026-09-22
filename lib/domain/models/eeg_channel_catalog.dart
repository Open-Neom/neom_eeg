import '../enums/eeg_device_type.dart';
import 'eeg_channel_info.dart';

/// A left/right electrode pair over the same cortical region, the unit the
/// asymmetry and coherence metrics work on.
class EegHemisphericPair {
  final String left;
  final String right;

  /// Cortical region, e.g. `temporal`, `prefrontal`, `central`.
  final String region;

  const EegHemisphericPair(this.left, this.right, this.region);

  bool get isTemporal => region == 'temporal';

  @override
  String toString() => '$left/$right ($region)';

  @override
  bool operator ==(Object other) =>
      other is EegHemisphericPair &&
      other.left == left &&
      other.right == right &&
      other.region == region;

  @override
  int get hashCode => Object.hash(left, right, region);
}

/// Electrode layouts per headset model, in the 10-20 system.
///
/// Positions are a flat projection of the scalp normalised to `0..1`:
/// x grows from the left ear to the right ear, y from nasion (front) to
/// inion (back). They are what [EegTopography] uses to place each sensor.
///
/// Drivers should prefer the sensor list reported by the hardware (Cortex
/// `queryHeadsets.sensors`, the `cols` of a subscription…) and only use
/// [forType] to fill in positions with [positionOf]; the per-model lists are
/// the fallback when the device does not describe itself.
class EegChannelCatalog {
  EegChannelCatalog._();

  /// 10-20 coordinates for every label the supported headsets expose.
  static const Map<String, ({double x, double y})> positions = {
    'FP1': (x: 0.38, y: 0.10),
    'FP2': (x: 0.62, y: 0.10),
    'FPZ': (x: 0.50, y: 0.08),
    'AF7': (x: 0.22, y: 0.17),
    'AF3': (x: 0.35, y: 0.20),
    'AFZ': (x: 0.50, y: 0.18),
    'AF4': (x: 0.65, y: 0.20),
    'AF8': (x: 0.78, y: 0.17),
    'F7': (x: 0.15, y: 0.30),
    'F5': (x: 0.24, y: 0.31),
    'F3': (x: 0.32, y: 0.32),
    'F1': (x: 0.41, y: 0.31),
    'FZ': (x: 0.50, y: 0.30),
    'F2': (x: 0.59, y: 0.31),
    'F4': (x: 0.68, y: 0.32),
    'F6': (x: 0.76, y: 0.31),
    'F8': (x: 0.85, y: 0.30),
    'FT7': (x: 0.10, y: 0.40),
    'FC5': (x: 0.20, y: 0.42),
    'FC3': (x: 0.30, y: 0.41),
    'FC1': (x: 0.40, y: 0.41),
    'FCZ': (x: 0.50, y: 0.40),
    'FC2': (x: 0.60, y: 0.41),
    'FC4': (x: 0.70, y: 0.41),
    'FC6': (x: 0.80, y: 0.42),
    'FT8': (x: 0.90, y: 0.40),
    'T7': (x: 0.08, y: 0.50),
    'C5': (x: 0.19, y: 0.50),
    'C3': (x: 0.30, y: 0.50),
    'C1': (x: 0.40, y: 0.50),
    'CZ': (x: 0.50, y: 0.50),
    'C2': (x: 0.60, y: 0.50),
    'C4': (x: 0.70, y: 0.50),
    'C6': (x: 0.81, y: 0.50),
    'T8': (x: 0.92, y: 0.50),
    'TP9': (x: 0.05, y: 0.62),
    'TP7': (x: 0.10, y: 0.60),
    'CP5': (x: 0.20, y: 0.58),
    'CP3': (x: 0.30, y: 0.59),
    'CP1': (x: 0.40, y: 0.59),
    'CPZ': (x: 0.50, y: 0.60),
    'CP2': (x: 0.60, y: 0.59),
    'CP4': (x: 0.70, y: 0.59),
    'CP6': (x: 0.80, y: 0.58),
    'TP8': (x: 0.90, y: 0.60),
    'TP10': (x: 0.95, y: 0.62),
    'P7': (x: 0.15, y: 0.70),
    'P5': (x: 0.24, y: 0.69),
    'P3': (x: 0.32, y: 0.68),
    'P1': (x: 0.41, y: 0.69),
    'PZ': (x: 0.50, y: 0.70),
    'P2': (x: 0.59, y: 0.69),
    'P4': (x: 0.68, y: 0.68),
    'P6': (x: 0.76, y: 0.69),
    'P8': (x: 0.85, y: 0.70),
    'PO7': (x: 0.22, y: 0.83),
    'PO3': (x: 0.35, y: 0.80),
    'POZ': (x: 0.50, y: 0.82),
    'PO4': (x: 0.65, y: 0.80),
    'PO8': (x: 0.78, y: 0.83),
    'O1': (x: 0.38, y: 0.90),
    'OZ': (x: 0.50, y: 0.92),
    'O2': (x: 0.62, y: 0.90),
  };

  static const List<String> emotivInsight = ['AF3', 'T7', 'Pz', 'T8', 'AF4'];

  static const List<String> emotivEpoc = [
    'AF3', 'F7', 'F3', 'FC5', 'T7', 'P7', 'O1',
    'O2', 'P8', 'T8', 'FC6', 'F4', 'F8', 'AF4',
  ];

  /// EPOC Flex ships with a configurable cap; this is the 32-channel
  /// factory mapping. Cortex reports the real one in `queryHeadsets`.
  static const List<String> emotivEpocFlex = [
    'Cz', 'Fz', 'Fp1', 'F7', 'F3', 'FC1', 'C3', 'FC5',
    'FT9', 'T7', 'CP5', 'CP1', 'P3', 'P7', 'PO9', 'O1',
    'Pz', 'Oz', 'O2', 'PO10', 'P8', 'P4', 'CP2', 'CP6',
    'T8', 'FT10', 'FC6', 'C4', 'FC2', 'F4', 'F8', 'Fp2',
  ];

  static const List<String> emotivMn8 = ['AF7', 'AF8'];

  static const List<String> muse = ['TP9', 'AF7', 'AF8', 'TP10'];

  static const List<String> brainbit = ['O1', 'O2', 'T3', 'T4'];

  static const List<String> openbciCyton = [
    'Fp1', 'Fp2', 'C3', 'C4', 'P7', 'P8', 'O1', 'O2',
  ];

  static const List<String> openbciCytonDaisy = [
    'Fp1', 'Fp2', 'C3', 'C4', 'P7', 'P8', 'O1', 'O2',
    'F7', 'F8', 'F3', 'F4', 'T7', 'T8', 'P3', 'P4',
  ];

  static const List<String> openbciGanglion = ['Fp1', 'Fp2', 'O1', 'O2'];

  static const List<String> neurosky = ['Fp1'];

  /// Default labels for a model.
  static List<String> labelsFor(EegDeviceType type) => switch (type) {
        EegDeviceType.emotivEpocX ||
        EegDeviceType.emotivEpocPlus =>
          emotivEpoc,
        EegDeviceType.emotivEpocFlex => emotivEpocFlex,
        EegDeviceType.emotivInsight => emotivInsight,
        EegDeviceType.emotivMn8 => emotivMn8,
        EegDeviceType.muse => muse,
        EegDeviceType.brainbit => brainbit,
        EegDeviceType.openbci => openbciCyton,
        EegDeviceType.openbciCytonDaisy => openbciCytonDaisy,
        EegDeviceType.openbciGanglion => openbciGanglion,
        EegDeviceType.neurosky => neurosky,
        EegDeviceType.simulated => emotivInsight,
      };

  /// Default [EegChannelInfo] list for a model.
  static List<EegChannelInfo> forType(EegDeviceType type) =>
      fromLabels(labelsFor(type));

  /// Build channel infos from labels reported by the hardware, resolving
  /// positions from the catalog. Unknown labels (BrainBit's legacy `T3/T4`,
  /// a custom Flex mapping…) are still returned, placed at the centre so
  /// they render rather than vanish.
  static List<EegChannelInfo> fromLabels(Iterable<String> labels) => [
        for (final label in labels)
          EegChannelInfo(
            name: label,
            positionX: positionOf(label)?.x ?? 0.5,
            positionY: positionOf(label)?.y ?? 0.5,
          ),
      ];

  static ({double x, double y})? positionOf(String label) =>
      positions[_legacyAlias[label.toUpperCase()] ?? label.toUpperCase()];

  /// 10-20 labels that were renamed in the 10-10 revision.
  static const Map<String, String> _legacyAlias = {
    'T3': 'T7',
    'T4': 'T8',
    'T5': 'P7',
    'T6': 'P8',
  };

  /// Homologous pairs in priority order for hemispheric metrics. Temporal
  /// first because that is what the Cyberneom protocol tracks; the rest lets
  /// a headset without temporal electrodes (MN8, Ganglion, MindWave…) still
  /// report a left/right balance from whatever it has.
  static const List<EegHemisphericPair> hemisphericPairs = [
    EegHemisphericPair('T7', 'T8', 'temporal'),
    EegHemisphericPair('TP9', 'TP10', 'temporal'),
    EegHemisphericPair('TP7', 'TP8', 'temporal'),
    EegHemisphericPair('FT7', 'FT8', 'frontotemporal'),
    EegHemisphericPair('F7', 'F8', 'frontotemporal'),
    EegHemisphericPair('FC5', 'FC6', 'frontocentral'),
    EegHemisphericPair('C3', 'C4', 'central'),
    EegHemisphericPair('P7', 'P8', 'parietal'),
    EegHemisphericPair('P3', 'P4', 'parietal'),
    EegHemisphericPair('CP5', 'CP6', 'centroparietal'),
    EegHemisphericPair('AF3', 'AF4', 'prefrontal'),
    EegHemisphericPair('AF7', 'AF8', 'prefrontal'),
    EegHemisphericPair('F3', 'F4', 'frontal'),
    EegHemisphericPair('FP1', 'FP2', 'prefrontal'),
    EegHemisphericPair('O1', 'O2', 'occipital'),
    EegHemisphericPair('PO7', 'PO8', 'parieto-occipital'),
  ];

  /// Pairs a device with these [labels] can serve, best first. Legacy
  /// labels (T3/T4…) match their 10-10 names; the returned pair keeps the
  /// device's own spelling so it can index the device's data directly.
  static List<EegHemisphericPair> availablePairs(Iterable<String> labels) {
    final byCanonical = <String, String>{};
    for (final l in labels) {
      final u = l.toUpperCase();
      byCanonical[_legacyAlias[u] ?? u] = l;
    }
    return [
      for (final p in hemisphericPairs)
        if (byCanonical.containsKey(p.left) && byCanonical.containsKey(p.right))
          EegHemisphericPair(byCanonical[p.left]!, byCanonical[p.right]!, p.region),
    ];
  }

  /// Highest-priority pair the device offers, or null for single-hemisphere
  /// layouts (NeuroSky's lone Fp1).
  static EegHemisphericPair? bestPair(Iterable<String> labels) {
    final pairs = availablePairs(labels);
    return pairs.isEmpty ? null : pairs.first;
  }

  /// Cortical region of a 10-20 label, from its letter prefix: `AF3` →
  /// `prefrontal`, `F7` → `frontal`, `FC5` → `frontocentral`, `T7` →
  /// `temporal`, `Pz` → `parietal`, `O1` → `occipital`… Legacy names
  /// resolve through their 10-10 alias. Null for labels that are not
  /// 10-20 positions (`RAW_CQ`, a Flex custom name).
  static String? regionOf(String label) {
    final u = label.toUpperCase();
    final canonical = _legacyAlias[u] ?? u;
    final match = RegExp(r'^[A-Z]+').firstMatch(canonical);
    if (match == null) return null;
    // 'FP' would otherwise be read as frontal + a stray P; 'PZ' has no
    // number, so the prefix is the whole label minus the midline Z.
    var prefix = match.group(0)!;
    if (prefix.length > 1 && prefix.endsWith('Z')) {
      prefix = prefix.substring(0, prefix.length - 1);
    }
    return _regionByPrefix[prefix];
  }

  static const Map<String, String> _regionByPrefix = {
    'FP': 'prefrontal',
    'AF': 'prefrontal',
    'F': 'frontal',
    'FT': 'frontotemporal',
    'FC': 'frontocentral',
    'T': 'temporal',
    'C': 'central',
    'TP': 'temporoparietal',
    'CP': 'centroparietal',
    'P': 'parietal',
    'PO': 'parieto-occipital',
    'O': 'occipital',
  };

  /// Prefrontal and frontal electrodes — where the "analytic processor"
  /// the hypofrontality protocol wants to quiet is read (AF3/AF4 on an
  /// Insight, AF7/AF8 on a Muse or MN8, Fp1 on a MindWave).
  static bool isFrontal(String label) {
    final r = regionOf(label);
    return r == 'prefrontal' || r == 'frontal';
  }

  /// Parietal and occipital electrodes, where resting alpha is strongest
  /// and eyes-closed reactivity is measured (Pz on an Insight, O1/O2 on
  /// BrainBit and Ganglion).
  static bool isPosterior(String label) {
    final r = regionOf(label);
    return r == 'parietal' || r == 'parieto-occipital' || r == 'occipital';
  }

  static bool isTemporal(String label) => regionOf(label) == 'temporal';

  /// Whether a channel set covers the temporal lobes (T7/T8 or the
  /// mastoid-adjacent TP9/TP10), which the Cyberneom epilepsy protocol
  /// relies on for hemispheric asymmetry.
  static bool hasTemporalCoverage(Iterable<String> labels) {
    final upper = labels.map((l) => l.toUpperCase()).toSet();
    final left = upper.contains('T7') || upper.contains('TP9') ||
        upper.contains('T3');
    final right = upper.contains('T8') || upper.contains('TP10') ||
        upper.contains('T4');
    return left && right;
  }
}

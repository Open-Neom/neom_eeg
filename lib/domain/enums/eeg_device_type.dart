import 'eeg_vendor.dart';

/// Concrete headset model.
///
/// [channelCount] and [sampleRate] are the factory defaults; a driver may
/// report different values on a connected [EegDeviceInfo] (e.g. EPOC X can
/// run at 128 or 256 Hz depending on the Cortex headset settings).
enum EegDeviceType {
  // ── Emotiv ─────────────────────────────────────────────────────────
  emotivEpocX(EegVendor.emotiv, 14, 256, 'Emotiv EPOC X'),
  emotivEpocPlus(EegVendor.emotiv, 14, 256, 'Emotiv EPOC+'),
  emotivEpocFlex(EegVendor.emotiv, 32, 256, 'Emotiv EPOC Flex'),
  emotivInsight(EegVendor.emotiv, 5, 128, 'Emotiv Insight'),
  emotivMn8(EegVendor.emotiv, 2, 128, 'Emotiv MN8'),

  /// EEG earbuds, same two-channel T7/T8 family as the MN8 (Emotiv's own
  /// Unity plugin groups them: `HeadsetFamily.MN8`).
  emotivMw20(EegVendor.emotiv, 2, 128, 'Emotiv MW20'),

  // ── Interaxon ──────────────────────────────────────────────────────
  muse(EegVendor.interaxon, 4, 256, 'Muse 2/S'),

  // ── BrainBit ───────────────────────────────────────────────────────
  brainbit(EegVendor.brainbit, 4, 250, 'BrainBit'),

  // ── OpenBCI ────────────────────────────────────────────────────────
  openbci(EegVendor.openbci, 8, 250, 'OpenBCI Cyton'),
  openbciCytonDaisy(EegVendor.openbci, 16, 125, 'OpenBCI Cyton + Daisy'),
  openbciGanglion(EegVendor.openbci, 4, 200, 'OpenBCI Ganglion'),

  // ── NeuroSky ───────────────────────────────────────────────────────
  neurosky(EegVendor.neurosky, 1, 512, 'NeuroSky MindWave'),

  // ── Development ────────────────────────────────────────────────────
  simulated(EegVendor.simulated, 5, 128, 'Simulated Device');

  final EegVendor vendor;
  final int channelCount;
  final int sampleRate;
  final String displayName;

  const EegDeviceType(
    this.vendor,
    this.channelCount,
    this.sampleRate,
    this.displayName,
  );

  bool get isEmotiv => vendor == EegVendor.emotiv;

  /// All models of a given vendor.
  static List<EegDeviceType> ofVendor(EegVendor vendor) =>
      values.where((t) => t.vendor == vendor).toList();

  /// Resolve an Emotiv model from a Cortex headset id (`INSIGHT-A1B2C3D4`,
  /// `INSIGHT2-…`, `EPOCX-…`, `EPOCPLUS-…`, `EPOCFLEX-…`, `MN8-…`, `MW20-…`)
  /// or from the
  /// `settings.mode` field of a `queryHeadsets` result.
  ///
  /// Returns null when the string does not identify an Emotiv headset.
  static EegDeviceType? fromCortexId(String idOrMode) {
    final upper = idOrMode.toUpperCase();
    if (upper.startsWith('INSIGHT')) return emotivInsight;
    if (upper.startsWith('MN8')) return emotivMn8;
    if (upper.startsWith('MW20')) return emotivMw20;
    if (upper.startsWith('EPOCFLEX') || upper.startsWith('FLEX')) {
      return emotivEpocFlex;
    }
    if (upper.startsWith('EPOCX')) return emotivEpocX;
    if (upper.startsWith('EPOCPLUS') || upper.startsWith('EPOC+')) {
      return emotivEpocPlus;
    }
    if (upper.startsWith('EPOC')) return emotivEpocX;
    return null;
  }
}

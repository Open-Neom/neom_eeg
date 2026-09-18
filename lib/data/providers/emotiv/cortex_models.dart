/// `getLicenseInfo` result. The `scopes` decide which streams `subscribe`
/// accepts: `eeg` and `pow` need a scope beyond the free tier, which only
/// covers performance metrics, motion and device status.
class CortexLicenseInfo {
  final String? licenseId;
  final String? licenseName;
  final List<String> scopes;
  final int? sessionCount;
  final int? sessionRemaining;
  final bool expired;
  final DateTime? hardLimitTime;
  final DateTime? softLimitTime;
  final bool isCommercial;

  /// Whether Cortex validated the license against Emotiv's servers or is
  /// working from its cached copy.
  final bool isOnline;
  final Map<String, dynamic> raw;

  const CortexLicenseInfo({
    this.licenseId,
    this.licenseName,
    this.scopes = const [],
    this.sessionCount,
    this.sessionRemaining,
    this.expired = false,
    this.hardLimitTime,
    this.softLimitTime,
    this.isCommercial = false,
    this.isOnline = false,
    this.raw = const {},
  });

  bool get allowsRawEeg => scopes.contains('eeg');

  bool get allowsBandPower => scopes.contains('eeg') || scopes.contains('pow');

  bool get allowsHighResMetrics => scopes.contains('pm');

  factory CortexLicenseInfo.fromResult(Map<String, dynamic> result) {
    final license = (result['license'] as Map?)?.cast<String, dynamic>() ?? {};
    DateTime? date(dynamic v) =>
        v is String && v.isNotEmpty ? DateTime.tryParse(v) : null;
    return CortexLicenseInfo(
      licenseId: license['licenseId'] as String?,
      licenseName: license['licenseName'] as String?,
      scopes: (license['scopes'] as List?)?.map((e) => e.toString()).toList() ??
          const [],
      sessionCount: (license['sessionCount'] as num?)?.toInt(),
      sessionRemaining: (license['sessionRemaining'] as num?)?.toInt(),
      expired: license['expired'] == true,
      hardLimitTime: date(license['hardLimitTime']),
      softLimitTime: date(license['softLimitTime']),
      isCommercial: license['isCommercial'] == true,
      isOnline: result['isOnline'] == true,
      raw: result,
    );
  }

  @override
  String toString() =>
      'CortexLicenseInfo(${licenseName ?? licenseId ?? 'free'} scopes=$scopes '
      'sessions=${sessionRemaining ?? '∞'}/${sessionCount ?? '∞'}'
      '${expired ? ' EXPIRED' : ''})';
}

/// `getCortexInfo` result.
class CortexInfo {
  final String version;
  final String buildNumber;
  final String? buildDate;

  const CortexInfo({
    required this.version,
    required this.buildNumber,
    this.buildDate,
  });

  factory CortexInfo.fromResult(Map<String, dynamic> r) => CortexInfo(
        version: r['version']?.toString() ?? '?',
        buildNumber: r['buildNumber']?.toString() ?? '?',
        buildDate: r['buildDate']?.toString(),
      );

  @override
  String toString() => 'Cortex $version ($buildNumber)';
}

/// Headset configuration accepted by `updateHeadset`.
///
/// 256 Hz is only honoured by EPOC+ and EPOC X (and needs the USB cable
/// connected while changing); Insight, EPOC and Flex stay at 128 Hz.
class CortexHeadsetSettings {
  final String? mode;
  final int? eegRate;
  final int? memsRate;

  const CortexHeadsetSettings({this.mode, this.eegRate, this.memsRate});

  Map<String, dynamic> toJson() => {
        'mode': ?mode,
        'eegRate': ?eegRate,
        'memsRate': ?memsRate,
      };
}

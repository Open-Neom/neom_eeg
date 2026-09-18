import '../enums/eeg_transport.dart';

/// What a driver can deliver for a given headset model.
///
/// The hub reads this to decide what it must synthesise itself so every
/// device exposes the same three streams (raw, band power, mental state):
/// when [nativeBandPower] is false it runs the signal processor over the raw
/// stream, and when [nativeMentalMetrics] is false it estimates metrics from
/// band ratios. UIs can read it to hide panels a device cannot feed.
class EegCapabilities {
  /// The device or its SDK computes band powers (no FFT needed here).
  final bool nativeBandPower;

  /// The SDK provides cognitive metrics (engagement, stress, focus…).
  final bool nativeMentalMetrics;

  /// Per-electrode contact quality is reported.
  final bool contactQuality;

  /// Accelerometer / gyroscope / magnetometer data is available.
  final bool motion;

  /// Battery level is reported.
  final bool battery;

  /// Software/hardware markers can be injected into the record.
  final bool markers;

  /// Electrodes cover both temporal lobes (T7/T8 or TP9/TP10).
  final bool temporalCoverage;

  /// Transports the driver implements for this model.
  final Set<EegTransport> transports;

  const EegCapabilities({
    this.nativeBandPower = false,
    this.nativeMentalMetrics = false,
    this.contactQuality = false,
    this.motion = false,
    this.battery = false,
    this.markers = false,
    this.temporalCoverage = false,
    this.transports = const {},
  });

  static const none = EegCapabilities();

  EegCapabilities copyWith({
    bool? nativeBandPower,
    bool? nativeMentalMetrics,
    bool? contactQuality,
    bool? motion,
    bool? battery,
    bool? markers,
    bool? temporalCoverage,
    Set<EegTransport>? transports,
  }) =>
      EegCapabilities(
        nativeBandPower: nativeBandPower ?? this.nativeBandPower,
        nativeMentalMetrics: nativeMentalMetrics ?? this.nativeMentalMetrics,
        contactQuality: contactQuality ?? this.contactQuality,
        motion: motion ?? this.motion,
        battery: battery ?? this.battery,
        markers: markers ?? this.markers,
        temporalCoverage: temporalCoverage ?? this.temporalCoverage,
        transports: transports ?? this.transports,
      );

  Map<String, dynamic> toJson() => {
        'nativeBandPower': nativeBandPower,
        'nativeMentalMetrics': nativeMentalMetrics,
        'contactQuality': contactQuality,
        'motion': motion,
        'battery': battery,
        'markers': markers,
        'temporalCoverage': temporalCoverage,
        'transports': transports.map((t) => t.name).toList(),
      };

  @override
  String toString() => 'EegCapabilities(${toJson()})';
}

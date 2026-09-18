import '../enums/eeg_device_type.dart';
import 'eeg_channel_catalog.dart';

class EegChannelInfo {
  final String name;
  final double positionX;
  final double positionY;
  final bool isReference;

  const EegChannelInfo({
    required this.name,
    required this.positionX,
    required this.positionY,
    this.isReference = false,
  });

  /// Insight layout. Kept for callers that predate [EegChannelCatalog];
  /// prefer `EegChannelCatalog.forType(EegDeviceType.emotivInsight)`.
  static List<EegChannelInfo> emotivInsightChannels() =>
      EegChannelCatalog.forType(EegDeviceType.emotivInsight);

  Map<String, dynamic> toJson() => {
        'name': name,
        'positionX': positionX,
        'positionY': positionY,
        'isReference': isReference,
      };

  factory EegChannelInfo.fromJson(Map<String, dynamic> json) => EegChannelInfo(
        name: json['name'] as String,
        positionX: (json['positionX'] as num).toDouble(),
        positionY: (json['positionY'] as num).toDouble(),
        isReference: json['isReference'] as bool? ?? false,
      );
}

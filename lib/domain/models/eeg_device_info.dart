import '../enums/eeg_device_type.dart';
import 'eeg_channel_info.dart';

class EegDeviceInfo {
  final String id;
  final String name;
  final EegDeviceType type;
  final List<EegChannelInfo> channels;
  final int sampleRate;
  final int battery;
  final double signalQuality;
  final String? firmwareVersion;

  const EegDeviceInfo({
    required this.id,
    required this.name,
    required this.type,
    required this.channels,
    required this.sampleRate,
    required this.battery,
    required this.signalQuality,
    this.firmwareVersion,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'type': type.name,
        'channels': channels.map((c) => c.toJson()).toList(),
        'sampleRate': sampleRate,
        'battery': battery,
        'signalQuality': signalQuality,
        'firmwareVersion': firmwareVersion,
      };

  factory EegDeviceInfo.fromJson(Map<String, dynamic> json) => EegDeviceInfo(
        id: json['id'] as String,
        name: json['name'] as String,
        type: EegDeviceType.values.byName(json['type'] as String),
        channels: (json['channels'] as List)
            .map((c) => EegChannelInfo.fromJson(c as Map<String, dynamic>))
            .toList(),
        sampleRate: json['sampleRate'] as int,
        battery: json['battery'] as int,
        signalQuality: (json['signalQuality'] as num).toDouble(),
        firmwareVersion: json['firmwareVersion'] as String?,
      );
}

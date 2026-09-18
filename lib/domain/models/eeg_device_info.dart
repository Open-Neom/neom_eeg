import '../enums/eeg_device_type.dart';
import '../enums/eeg_transport.dart';
import '../enums/eeg_vendor.dart';
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

  /// Transport the driver discovered the device on. Null for legacy callers
  /// that build infos by hand; the hub then routes by [type] alone.
  final EegTransport? transport;

  /// Vendor-specific discovery details a driver wants to keep (Cortex
  /// `status`/`connectedBy`, BLE RSSI…). Opaque to consumers.
  final Map<String, dynamic> metadata;

  const EegDeviceInfo({
    required this.id,
    required this.name,
    required this.type,
    required this.channels,
    required this.sampleRate,
    required this.battery,
    required this.signalQuality,
    this.firmwareVersion,
    this.transport,
    this.metadata = const {},
  });

  EegVendor get vendor => type.vendor;

  List<String> get channelLabels => channels.map((c) => c.name).toList();

  EegDeviceInfo copyWith({
    String? id,
    String? name,
    EegDeviceType? type,
    List<EegChannelInfo>? channels,
    int? sampleRate,
    int? battery,
    double? signalQuality,
    String? firmwareVersion,
    EegTransport? transport,
    Map<String, dynamic>? metadata,
  }) =>
      EegDeviceInfo(
        id: id ?? this.id,
        name: name ?? this.name,
        type: type ?? this.type,
        channels: channels ?? this.channels,
        sampleRate: sampleRate ?? this.sampleRate,
        battery: battery ?? this.battery,
        signalQuality: signalQuality ?? this.signalQuality,
        firmwareVersion: firmwareVersion ?? this.firmwareVersion,
        transport: transport ?? this.transport,
        metadata: metadata ?? this.metadata,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'type': type.name,
        'channels': channels.map((c) => c.toJson()).toList(),
        'sampleRate': sampleRate,
        'battery': battery,
        'signalQuality': signalQuality,
        'firmwareVersion': firmwareVersion,
        'transport': transport?.name,
        'metadata': metadata,
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
        transport: json['transport'] != null
            ? EegTransport.values.byName(json['transport'] as String)
            : null,
        metadata: Map<String, dynamic>.from((json['metadata'] as Map?) ?? {}),
      );

  @override
  String toString() =>
      'EegDeviceInfo($name [${type.displayName}] ${channels.length}ch '
      '@${sampleRate}Hz via ${transport?.name ?? '?'})';
}

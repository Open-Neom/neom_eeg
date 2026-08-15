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

  static List<EegChannelInfo> emotivInsightChannels() => const [
        EegChannelInfo(name: 'AF3', positionX: 0.3, positionY: 0.2),
        EegChannelInfo(name: 'T7', positionX: 0.1, positionY: 0.5),
        EegChannelInfo(name: 'Pz', positionX: 0.5, positionY: 0.5),
        EegChannelInfo(name: 'T8', positionX: 0.9, positionY: 0.5),
        EegChannelInfo(name: 'AF4', positionX: 0.7, positionY: 0.2),
      ];

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

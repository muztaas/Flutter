class VideoInformation {
  const VideoInformation({
    required this.durationMilliseconds,
    required this.width,
    required this.height,
    required this.rotationDegrees,
    this.frameRate,
  });

  final int? durationMilliseconds;
  final int? width;
  final int? height;
  final int rotationDegrees;
  final double? frameRate;

  int? get shorterDisplayedSide {
    final width = this.width;
    final height = this.height;
    if (width == null || height == null) return null;
    final swapsDimensions = rotationDegrees % 180 != 0;
    final displayedWidth = swapsDimensions ? height : width;
    final displayedHeight = swapsDimensions ? width : height;
    return displayedWidth < displayedHeight ? displayedWidth : displayedHeight;
  }

  String? get resolutionLabel {
    final side = shorterDisplayedSide;
    if (side == null) return null;
    if (side >= 2160) return '4K';
    if (side >= 1440) return '1440p';
    if (side >= 1080) return '1080p';
    if (side >= 720) return '720p';
    if (side >= 480) return '480p';
    if (side >= 360) return '360p';
    if (side >= 240) return '240p';
    if (side >= 144) return '144p';
    return '${side}p';
  }

  Map<String, Object?> toJson() => {
    'durationMilliseconds': durationMilliseconds,
    'width': width,
    'height': height,
    'rotationDegrees': rotationDegrees,
    'frameRate': frameRate,
  };

  factory VideoInformation.fromJson(Map<String, Object?> json) =>
      VideoInformation(
        durationMilliseconds: json['durationMilliseconds'] as int?,
        width: json['width'] as int?,
        height: json['height'] as int?,
        rotationDegrees: json['rotationDegrees'] as int? ?? 0,
        frameRate: (json['frameRate'] as num?)?.toDouble(),
      );
}

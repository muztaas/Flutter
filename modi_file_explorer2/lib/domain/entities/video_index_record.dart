import 'video_information.dart';

enum VideoStatus {
  none('NONE'),
  newVideo('NEW'),
  inProgress('IN_PROGRESS'),
  finished('FINISHED'),
  lastPlayed('LAST_PLAYED');

  const VideoStatus(this.storageValue);

  final String storageValue;

  static VideoStatus fromStorage(Object? value) => switch (value) {
    'NEW' => VideoStatus.newVideo,
    'IN_PROGRESS' => VideoStatus.inProgress,
    'FINISHED' => VideoStatus.finished,
    'LAST_PLAYED' => VideoStatus.lastPlayed,
    _ => VideoStatus.none,
  };
}

class VideoIndexRecord {
  const VideoIndexRecord({
    this.information,
    this.status = VideoStatus.none,
    this.playedAt,
    this.playCount = 0,
    this.resumePositionMilliseconds = 0,
  });

  final VideoInformation? information;
  final VideoStatus status;
  final DateTime? playedAt;
  final int playCount;
  final int resumePositionMilliseconds;

  Map<String, Object?> toJson() => {
    'information': information?.toJson(),
    'status': status.storageValue,
    'playedAt': playedAt?.millisecondsSinceEpoch,
    'playCount': playCount,
    'resumePositionMilliseconds': resumePositionMilliseconds,
  };

  factory VideoIndexRecord.fromJson(Map<String, Object?> json) =>
      VideoIndexRecord(
        information: json['information'] is Map
            ? VideoInformation.fromJson(
                Map<String, Object?>.from(json['information']! as Map),
              )
            : null,
        status: VideoStatus.fromStorage(json['status']),
        playedAt: (json['playedAt'] as int?) == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(json['playedAt']! as int),
        playCount: json['playCount'] as int? ?? 0,
        resumePositionMilliseconds:
            json['resumePositionMilliseconds'] as int? ?? 0,
      );

  VideoIndexRecord copyWith({
    VideoInformation? information,
    VideoStatus? status,
    DateTime? playedAt,
    bool clearPlayedAt = false,
    int? playCount,
    int? resumePositionMilliseconds,
  }) => VideoIndexRecord(
    information: information ?? this.information,
    status: status ?? this.status,
    playedAt: clearPlayedAt ? null : playedAt ?? this.playedAt,
    playCount: playCount ?? this.playCount,
    resumePositionMilliseconds:
        resumePositionMilliseconds ?? this.resumePositionMilliseconds,
  );
}

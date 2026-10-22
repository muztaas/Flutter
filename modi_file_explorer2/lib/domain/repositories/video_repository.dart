import '../entities/storage_device.dart';
import '../entities/video_file.dart';
import '../entities/video_index_record.dart';
import '../entities/video_library_scan.dart';
import '../entities/video_path_properties.dart';
import '../entities/video_status_target.dart';

abstract interface class VideoRepository {
  Future<VideoLibraryScan> scanVideos({
    required StorageDevice drive,
    required Set<String> extensions,
  });

  Future<VideoFile?> getVideoAtPath({
    required StorageDevice drive,
    required String path,
    required Set<String> extensions,
  });

  Future<List<VideoFile>> listVideosInFolder({
    required StorageDevice drive,
    required String relativeFolderPath,
    required Set<String> extensions,
  });

  Future<VideoIndexRecord?> getInformation(VideoFile video);

  Future<VideoIndexRecord?> getCachedInformation(VideoFile video);

  Future<Map<String, VideoIndexRecord>> getCachedRecords(
    List<VideoFile> videos,
  );

  Future<void> synchronizeSnapshot(VideoLibraryScan library);

  Future<VideoStatusUpdateResult> setStatuses({
    required List<VideoStatusTarget> targets,
    required VideoStatus status,
  });

  Future<void> markPlayed(VideoFile video);

  Future<Duration> getResumePosition(VideoFile video);

  Future<void> saveResumePosition(VideoFile video, Duration position);

  Future<List<VideoFile>> recentlyPlayed(List<VideoFile> availableVideos);

  Future<void> moveRecord(VideoFile oldVideo, VideoFile newVideo);

  Future<VideoPathProperties> getPathProperties({
    required String driveId,
    required String relativePath,
  });

  Future<void> renamePath({
    required String driveId,
    required String relativePath,
    required String newName,
  });

  Future<void> deletePath({
    required String driveId,
    required String relativePath,
  });

  Future<bool> pathExists({
    required String driveId,
    required String relativePath,
  });

  Future<void> copyPath({
    required String sourceDriveId,
    required String sourceRelativePath,
    required String destinationDriveId,
    required String destinationRelativePath,
    required String targetName,
    required bool replaceExisting,
  });

  Future<List<int>?> getThumbnail(
    VideoFile video, {
    required int width,
    required int height,
  });

  void cancelPending(VideoFile video);
}

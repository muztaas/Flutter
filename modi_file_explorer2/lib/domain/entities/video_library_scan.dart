import 'storage_device.dart';
import 'video_file.dart';
import 'video_folder.dart';

class VideoLibraryScan {
  const VideoLibraryScan({
    required this.drive,
    required this.videos,
    required this.folders,
  });

  final StorageDevice drive;
  final List<VideoFile> videos;
  final List<VideoFolder> folders;
}

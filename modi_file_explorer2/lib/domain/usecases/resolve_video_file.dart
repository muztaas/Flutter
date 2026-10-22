import '../entities/storage_device.dart';
import '../entities/video_file.dart';
import '../entities/video_player_item.dart';
import '../repositories/storage_repository.dart';
import '../repositories/video_repository.dart';

class ResolveVideoFile {
  const ResolveVideoFile(this._storageRepository, this._videoRepository);

  final StorageRepository _storageRepository;
  final VideoRepository _videoRepository;

  Future<VideoFile?> call({
    required String path,
    required Set<String> extensions,
  }) async {
    for (final drive in await _matchingDrives(path)) {
      final video = await _videoRepository.getVideoAtPath(
        drive: drive,
        path: path,
        extensions: extensions,
      );
      if (video != null) return video;
    }
    return null;
  }

  Future<List<VideoPlayerItem>> playlist({
    required String path,
    required Set<String> extensions,
  }) async {
    final normalizedPath = _normalize(path);
    for (final drive in await _matchingDrives(path)) {
      final root = _normalize(drive.path);
      final relativeFilePath = normalizedPath.substring(root.length + 1);
      final lastSeparator = relativeFilePath.lastIndexOf('/');
      final relativeFolderPath = lastSeparator < 0
          ? ''
          : relativeFilePath.substring(0, lastSeparator);
      final videos = await _videoRepository.listVideosInFolder(
        drive: drive,
        relativeFolderPath: relativeFolderPath,
        extensions: extensions,
      );
      final absoluteRoot = drive.path.replaceAll(RegExp(r'[\\/]+$'), '');
      return videos
          .map(
            (video) => VideoPlayerItem.fromVideoFile(
              video,
              absolutePath: '$absoluteRoot/${video.relativePath}',
            ),
          )
          .toList(growable: false);
    }
    return const [];
  }

  Future<List<StorageDevice>> _matchingDrives(String path) async {
    final normalizedPath = _normalize(path);
    final drives = await _storageRepository.listStorageDevices();
    final matchingDrives = drives.where((drive) {
      final root = _normalize(drive.path);
      return normalizedPath.startsWith('$root/');
    }).toList()..sort((a, b) => b.path.length.compareTo(a.path.length));
    return matchingDrives;
  }

  String _normalize(String path) =>
      path.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '');
}

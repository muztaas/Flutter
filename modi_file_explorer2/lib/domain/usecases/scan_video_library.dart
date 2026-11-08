import '../entities/video_library_scan.dart';
import '../repositories/storage_repository.dart';
import '../repositories/video_repository.dart';

class ScanVideoLibrary {
  const ScanVideoLibrary(this._storageRepository, this._videoRepository);

  final StorageRepository _storageRepository;
  final VideoRepository _videoRepository;

  Future<VideoLibraryScan?> call(Set<String> extensions) async {
    final drives = await _storageRepository.listStorageDevices();
    final internalDrive = drives.where((drive) => drive.id == 'internal');
    if (internalDrive.isEmpty) return null;
    return _videoRepository.scanVideos(
      drive: internalDrive.first,
      extensions: extensions,
    );
  }

  Future<VideoLibraryScan?> loadSnapshot(Set<String> extensions) async {
    final drives = await _storageRepository.listStorageDevices();
    final internalDrives = drives.where((drive) => drive.id == 'internal');
    final snapshotRepository = _videoRepository;
    if (internalDrives.isEmpty ||
        snapshotRepository is! VideoLibrarySnapshotRepository) {
      return null;
    }
    final drive = internalDrives.first;
    final videos = await (snapshotRepository as VideoLibrarySnapshotRepository)
        .loadVideoLibrarySnapshot(driveId: drive.id);
    if (videos == null) return null;
    return VideoLibraryScan(
      drive: drive,
      videos: videos
          .where((video) => extensions.contains(video.extension))
          .toList(growable: false),
      folders: const [],
    );
  }
}

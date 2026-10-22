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
}

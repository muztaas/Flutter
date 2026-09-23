import '../entities/storage_device.dart';
import '../entities/file_system_entry.dart';

abstract class StorageRepository {
  Future<List<StorageDevice>> listStorageDevices();
  Future<List<FileSystemEntry>> listDirectory(String path);
  // Basic watch API, returns a stream of changes for path
  Stream<List<FileSystemEntry>> watchDirectory(String path);
}

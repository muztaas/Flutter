class StorageDevice {
  final String id;
  final String name;
  final String path;
  final int? usedBytes;
  final int? totalBytes;

  StorageDevice({required this.id, required this.name, required this.path, this.usedBytes, this.totalBytes});
}

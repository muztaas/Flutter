class ArchiveEntry {
  const ArchiveEntry({
    required this.path,
    required this.name,
    required this.isDirectory,
    required this.size,
    required this.modifiedTime,
    required this.isEncrypted,
  });

  final String path;
  final String name;
  final bool isDirectory;
  final int size;
  final DateTime? modifiedTime;
  final bool isEncrypted;
}

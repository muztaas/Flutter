class FileSystemEntry {
  final String name;
  final String path;
  final bool isDirectory;
  final int? size;
  final DateTime? modified;

  FileSystemEntry({required this.name, required this.path, required this.isDirectory, this.size, this.modified});
}

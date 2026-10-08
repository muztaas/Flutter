class FileTypeCategory {
  const FileTypeCategory({
    required this.name,
    required this.extensions,
  });

  final String name;
  final List<String> extensions;

  static const defaults = <FileTypeCategory>[
    FileTypeCategory(
      name: 'Text',
      extensions: [
        '.txt',
        '.text',
        '.md',
        '.markdown',
        '.json',
        '.csv',
        '.tsv',
        '.xml',
        '.html',
        '.htm',
        '.css',
        '.js',
        '.ts',
        '.dart',
        '.kt',
        '.java',
        '.py',
        '.yaml',
        '.yml',
        '.log',
        '.ini',
        '.cfg',
        '.conf',
        '.sh',
        '.c',
        '.h',
        '.cpp',
        '.sql',
        '.toml',
        '.properties',
      ],
    ),
    FileTypeCategory(
      name: 'Image',
      extensions: [
        '.png',
        '.jpg',
        '.jpeg',
        '.gif',
        '.bmp',
        '.webp',
        '.heic',
        '.svg',
        '.tif',
        '.tiff',
        '.ico',
        '.avif',
        '.jfif',
      ],
    ),
    FileTypeCategory(
      name: 'Audio',
      extensions: ['.mp3', '.wav', '.ogg', '.m4a', '.flac', '.aac'],
    ),
    FileTypeCategory(
      name: 'Video',
      extensions: [
        '.mp4',
        '.mkv',
        '.mov',
        '.avi',
        '.webm',
        '.3gp',
        '.m4v',
        '.mpeg',
        '.mpg',
      ],
    ),
    FileTypeCategory(
      name: 'Archives',
      extensions: [
        '.zip',
        '.rar',
        '.7z',
        '.tar',
        '.gz',
        '.tgz',
        '.bz2',
        '.xz',
        '.zst',
        '.lz',
        '.lzma',
        '.cab',
        '.arj',
        '.iso',
        '.cbz',
        '.cbr',
      ],
    ),
  ];

  static String defaultStorageKey(String category) => '__category__$category';
  static const legacyImageDefaultStorageKey = '__all_images__';

  static String? categoryForExtension(
    String extension, {
    List<FileTypeCategory> categories = defaults,
  }) {
    final normalized = normalizeExtension(extension);
    for (final category in categories) {
      if (category.extensions.contains(normalized)) return category.name;
    }

    return null;
  }

  static String normalizeExtension(String extension) {
    final trimmed = extension.trim().toLowerCase();
    if (trimmed.isEmpty) return '';
    return trimmed.startsWith('.') ? trimmed : '.$trimmed';
  }

  Map<String, Object?> toJson() => {'name': name, 'extensions': extensions};

  factory FileTypeCategory.fromJson(Map<String, dynamic> json) {
    final name = json['name'];
    final extensions = json['extensions'];
    if (name is! String || extensions is! List) {
      throw const FormatException('Saved file type category is invalid');
    }
    return FileTypeCategory(
      name: name,
      extensions: extensions.map((extension) {
        if (extension is! String) {
          throw const FormatException('Saved file type extension is invalid');
        }
        return normalizeExtension(extension);
      }).where((extension) => extension.isNotEmpty).toSet().toList()..sort(),
    );
  }
}

import 'package:flutter/material.dart';

import '../../domain/entities/file_type_category.dart';

enum FileTypeColor {
  folder,
  text,
  unknown,
  pdf,
  spreadsheet,
  document,
  presentation,
  archive,
  package,
  code,
  image,
  video,
  audio,
  downloads,
  documents,
  apps,
}

const Map<FileTypeColor, ({Color light, Color dark})> fileTypeColors = {
  FileTypeColor.folder: (light: Color(0xFF9A6700), dark: Color(0xFFFFD54F)),
  FileTypeColor.text: (light: Color(0xFF202124), dark: Color(0xFFF5F5F5)),
  FileTypeColor.unknown: (light: Color(0xFF5F6368), dark: Color(0xFFB0BEC5)),
  FileTypeColor.pdf: (light: Color(0xFFC62828), dark: Color(0xFFEF5350)),
  FileTypeColor.spreadsheet: (
    light: Color(0xFF1B5E20),
    dark: Color(0xFF66BB6A),
  ),
  FileTypeColor.document: (light: Color(0xFF0D47A1), dark: Color(0xFF64B5F6)),
  FileTypeColor.presentation: (
    light: Color(0xFFBF360C),
    dark: Color(0xFFFF8A65),
  ),
  FileTypeColor.archive: (light: Color.fromARGB(255, 85, 76, 91), dark: Color.fromARGB(255, 85, 76, 91)),
  FileTypeColor.package: (light: Color(0xFF455A64), dark: Color(0xFF90A4AE)),
  FileTypeColor.code: (light: Color(0xFF00695C), dark: Color(0xFF4DB6AC)),
  FileTypeColor.image: (light: Color(0xFF1565C0), dark: Color(0xFF64B5F6)),
  FileTypeColor.video: (light: Color(0xFFC62828), dark: Color(0xFFEF5350)),
  FileTypeColor.audio: (light: Color(0xFF6A1B9A), dark: Color(0xFFCE93D8)),
  FileTypeColor.downloads: (light: Color(0xFF2E7D32), dark: Color(0xFF81C784)),
  FileTypeColor.documents: (light: Color(0xFFFADA5E), dark: Color(0xFFFADA5E)),
  FileTypeColor.apps: (light: Color(0xFF5E35B1), dark: Color(0xFFB39DDB)),
};

Color fileTypeColor(BuildContext context, FileTypeColor type) {
  final colors = fileTypeColors[type]!;
  return Theme.of(context).brightness == Brightness.dark
      ? colors.dark
      : colors.light;
}

FileTypeColor fileTypeColorForExtension(
  String extension, {
  List<FileTypeCategory>? categories,
}) {
  final normalized = extension.toLowerCase();
  if (normalized == '.apk' || normalized == '.aab') {
    return FileTypeColor.package;
  }
  final category = categories
      ?.where(
        (candidate) => candidate.extensions
            .map(FileTypeCategory.normalizeExtension)
            .contains(normalized),
      )
      .firstOrNull
      ?.name;
  if (category == 'Image') return FileTypeColor.image;
  if (category == 'Video') return FileTypeColor.video;
  if (category == 'Audio') return FileTypeColor.audio;
  if (const {'.pdf'}.contains(normalized)) return FileTypeColor.pdf;
  if (const {'.xls', '.xlsx', '.ods', '.csv', '.tsv'}.contains(normalized)) {
    return FileTypeColor.spreadsheet;
  }
  if (const {'.doc', '.docx', '.odt', '.rtf', '.epub'}.contains(normalized)) {
    return FileTypeColor.document;
  }
  if (const {'.ppt', '.pptx', '.odp'}.contains(normalized)) {
    return FileTypeColor.presentation;
  }
  if (const {
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
  }.contains(normalized)) {
    return FileTypeColor.archive;
  }
  if (const {
    '.txt',
    '.text',
    '.md',
    '.markdown',
    '.log',
  }.contains(normalized)) {
    return FileTypeColor.text;
  }
  if (const {
    '.json',
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
  }.contains(normalized)) {
    return FileTypeColor.code;
  }
  if (const {
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
  }.contains(normalized)) {
    return FileTypeColor.image;
  }
  if (const {
    '.mp4',
    '.mkv',
    '.mov',
    '.avi',
    '.webm',
    '.3gp',
    '.m4v',
    '.mpeg',
    '.mpg',
  }.contains(normalized)) {
    return FileTypeColor.video;
  }
  if (const {
    '.mp3',
    '.wav',
    '.ogg',
    '.m4a',
    '.flac',
    '.aac',
  }.contains(normalized)) {
    return FileTypeColor.audio;
  }
  return FileTypeColor.unknown;
}

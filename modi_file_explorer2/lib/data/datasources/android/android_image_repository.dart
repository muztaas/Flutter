import 'dart:io';
import 'dart:typed_data';

import '../../../domain/entities/file_system_entry.dart';
import '../../../domain/repositories/image_repository.dart';

class AndroidImageRepository implements ImageRepository {
  @override
  Future<Uint8List> readFileBytes(String path) => File(path).readAsBytes();

  @override
  Future<List<FileSystemEntry>> listImageFiles(
    String directoryPath, {
    required String driveRoot,
    required bool showHiddenFiles,
    required bool showNomediaFiles,
    required Set<String> extensions,
  }) async {
    if (!showNomediaFiles) {
      final normalizedRoot = driveRoot.replaceAll('\\', '/').replaceFirst(
        RegExp(r'/+$'),
        '',
      );
      var current = Directory(directoryPath);
      while (current.path.replaceAll('\\', '/').replaceFirst(
            RegExp(r'/+$'),
            '',
          ) !=
          normalizedRoot) {
        if (await File(
          '${current.path}${Platform.pathSeparator}.nomedia',
        ).exists()) {
          return [];
        }
        final parent = current.parent;
        if (parent.path == current.path) break;
        current = parent;
      }
    }
    final images = <FileSystemEntry>[];
    await for (final entry in Directory(directoryPath).list(
      followLinks: false,
    )) {
      final name = entry.uri.pathSegments
          .where((segment) => segment.isNotEmpty)
          .lastOrNull;
      if (name == null || (!showHiddenFiles && name.startsWith('.'))) continue;
      final extension = entry.path.split('.').last.toLowerCase();
      if (entry is! File || !extensions.contains('.$extension')) continue;
      final stat = await entry.stat();
      images.add(
        FileSystemEntry(
          name: name,
          path: entry.path,
          isDirectory: false,
          size: stat.size,
          modified: stat.modified,
        ),
      );
    }
    return images;
  }
}

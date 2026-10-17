import 'dart:typed_data';

import '../entities/file_system_entry.dart';

abstract class ImageRepository {
  Future<Uint8List> readFileBytes(String path);

  Future<List<FileSystemEntry>> listImageFiles(
    String directoryPath, {
    required String driveRoot,
    required bool showHiddenFiles,
    required bool showNomediaFiles,
    required Set<String> extensions,
  });
}

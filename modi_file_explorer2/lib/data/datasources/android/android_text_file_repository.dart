import 'dart:io';

import '../../../domain/repositories/text_file_repository.dart';

class AndroidTextFileRepository implements TextFileRepository {
  @override
  Future<String> readText(String path) => File(path).readAsString();

  @override
  Future<void> writeText(String path, String contents) =>
      File(path).writeAsString(contents);
}

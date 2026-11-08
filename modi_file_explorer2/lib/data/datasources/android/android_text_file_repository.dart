import 'dart:convert';
import 'dart:io';

import '../../../domain/repositories/text_file_repository.dart';

class AndroidTextFileRepository implements TextFileRepository {
  @override
  Future<String> readText(String path) async =>
      utf8.decode(await File(path).readAsBytes(), allowMalformed: true);

  @override
  Future<void> writeText(String path, String contents) =>
      File(path).writeAsString(contents);
}

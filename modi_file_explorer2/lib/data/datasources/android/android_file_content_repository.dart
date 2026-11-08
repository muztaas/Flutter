import 'dart:io';
import 'dart:typed_data';

import '../../../domain/repositories/file_content_repository.dart';

class AndroidFileContentRepository implements FileContentRepository {
  @override
  Future<Uint8List> readPrefix(String path, {required int maxBytes}) async {
    final file = await File(path).open();
    try {
      return Uint8List.fromList(await file.read(maxBytes));
    } finally {
      await file.close();
    }
  }
}

import 'dart:typed_data';

abstract interface class FileContentRepository {
  Future<Uint8List> readPrefix(String path, {required int maxBytes});
}

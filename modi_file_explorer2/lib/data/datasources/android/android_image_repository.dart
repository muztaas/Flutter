import 'dart:io';
import 'dart:typed_data';

import '../../../domain/repositories/image_repository.dart';

class AndroidImageRepository implements ImageRepository {
  @override
  Future<Uint8List> readFileBytes(String path) => File(path).readAsBytes();
}

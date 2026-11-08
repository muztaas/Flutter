import 'package:flutter/services.dart';

import '../../../domain/repositories/image_editor_repository.dart';

class AndroidImageEditorRepository implements ImageEditorRepository {
  static const _channel = MethodChannel('modi_file_explorer2/image_editor');

  @override
  Future<String> saveEditedImage({
    required String sourcePath,
    required double rotationDegrees,
    required double cropLeft,
    required double cropTop,
    required double cropRight,
    required double cropBottom,
    required double brightness,
    required double contrast,
    required bool overwriteOriginal,
  }) async {
    final result = await _channel.invokeMethod<String>('saveEditedImage', {
      'sourcePath': sourcePath,
      'rotationDegrees': rotationDegrees,
      'cropLeft': cropLeft,
      'cropTop': cropTop,
      'cropRight': cropRight,
      'cropBottom': cropBottom,
      'brightness': brightness,
      'contrast': contrast,
      'overwriteOriginal': overwriteOriginal,
    });
    if (result == null || result.isEmpty) {
      throw PlatformException(
        code: 'IMAGE_SAVE_FAILED',
        message: 'The image editor returned no saved file path.',
      );
    }
    return result;
  }
}

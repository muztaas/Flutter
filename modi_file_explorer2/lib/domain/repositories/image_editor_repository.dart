abstract class ImageEditorRepository {
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
  });
}

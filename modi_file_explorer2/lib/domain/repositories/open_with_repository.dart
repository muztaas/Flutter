import '../entities/open_with_app.dart';

abstract class OpenWithRepository {
  Future<List<OpenWithApp>> listApps({
    required String path,
    required String category,
  });

  Future<void> openFile({
    required String path,
    required String category,
    required String packageName,
    required String mimeType,
  });

  Future<String?> resolveAppName(String packageName);
}

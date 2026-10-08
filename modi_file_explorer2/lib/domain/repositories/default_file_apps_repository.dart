import '../entities/default_file_app.dart';

abstract interface class DefaultFileAppsRepository {
  Future<List<DefaultFileApp>> getAll();
  Future<void> save(DefaultFileApp defaultApp);
  Future<void> delete(String extension);
  Future<void> clear();
}

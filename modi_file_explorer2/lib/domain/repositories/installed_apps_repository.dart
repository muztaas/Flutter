import '../entities/installed_app.dart';

abstract class InstalledAppsRepository {
  Future<List<InstalledApp>> listInstalledApps();
}

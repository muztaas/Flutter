import '../../data/datasources/android/android_installed_apps_repository.dart';
import '../../domain/repositories/installed_apps_repository.dart';

InstalledAppsRepository getInstalledAppsRepository() {
  return AndroidInstalledAppsRepository();
}

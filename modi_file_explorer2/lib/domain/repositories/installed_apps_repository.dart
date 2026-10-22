import 'dart:typed_data';

import '../entities/installed_app.dart';
import '../entities/installed_app_size.dart';

abstract class InstalledAppsRepository {
  Future<List<InstalledApp>> listInstalledApps();
  Future<Uint8List?> getAppIcon(String packageName);
  Future<Uint8List?> getApkIcon(String path, {int size = 64});
  Future<InstalledAppSize> getAppSize(String packageName);
  Future<bool> hasUsageAccess();
  Future<void> openUsageAccessSettings();
  void clearAppSizeCache();
}

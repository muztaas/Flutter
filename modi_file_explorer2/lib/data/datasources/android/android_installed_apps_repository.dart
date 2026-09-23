import 'package:flutter/services.dart';

import '../../../domain/entities/installed_app.dart';
import '../../../domain/repositories/installed_apps_repository.dart';

class AndroidInstalledAppsRepository implements InstalledAppsRepository {
  static const _channel = MethodChannel('modi_file_explorer2/installed_apps');

  @override
  Future<List<InstalledApp>> listInstalledApps() async {
    final result = await _channel.invokeMethod<List<dynamic>>('listInstalledApps');
    return (result ?? const <dynamic>[]).map((item) {
      final app = Map<String, dynamic>.from(item as Map);
      return InstalledApp(
        name: app['name'] as String? ?? app['packageName'] as String? ?? 'Unknown app',
        packageName: app['packageName'] as String? ?? '',
        version: app['version'] as String? ?? 'Unknown version',
      );
    }).toList();
  }
}

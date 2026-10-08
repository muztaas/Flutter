import 'package:flutter/services.dart';

import '../../../domain/entities/open_with_app.dart';
import '../../../domain/repositories/open_with_repository.dart';

class AndroidOpenWithRepository implements OpenWithRepository {
  static const _channel = MethodChannel('modi_file_explorer2/open_with');

  @override
  Future<List<OpenWithApp>> listApps({
    required String path,
    required String category,
  }) async {
    final result = await _channel.invokeMethod<List<dynamic>>(
      'listOpenWithApps',
      {'path': path, 'category': category},
    );
    return _decodeApps(result);
  }

  @override
  Future<List<OpenWithApp>> listAppsForType({
    required String extension,
    required String category,
  }) async {
    final result = await _channel.invokeMethod<List<dynamic>>(
      'listOpenWithAppsForType',
      {'extension': extension, 'category': category},
    );
    return _decodeApps(result);
  }

  List<OpenWithApp> _decodeApps(List<dynamic>? result) {
    return (result ?? const <dynamic>[])
        .map((raw) {
          final app = Map<String, dynamic>.from(raw as Map);
          return OpenWithApp(
            name: app['name'] as String? ?? 'Unknown app',
            packageName: app['packageName'] as String? ?? '',
            mimeType: app['mimeType'] as String? ?? 'application/octet-stream',
            applicationName: app['applicationName'] as String?,
            activityName: app['activityName'] as String?,
            iconBytes: app['icon'] is Uint8List ? app['icon'] as Uint8List : null,
          );
        })
        .where((app) => app.packageName.isNotEmpty)
        .toList();
  }

  @override
  Future<void> openFile({
    required String path,
    required String category,
    required String packageName,
    String? activityName,
    required String mimeType,
  }) async {
    await _channel.invokeMethod<void>('openWithApp', {
      'path': path,
      'category': category,
      'packageName': packageName,
      'activityName': activityName,
      'mimeType': mimeType,
    });
  }

  @override
  Future<String?> resolveAppName(String packageName) {
    return _channel.invokeMethod<String?>('resolveOpenWithAppName', {
      'packageName': packageName,
    });
  }

  @override
  Future<Uint8List?> getOwnApplicationIcon() {
    return _channel.invokeMethod<Uint8List>('getOwnApplicationIcon');
  }
}

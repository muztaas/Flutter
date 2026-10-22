import 'dart:collection';
import 'dart:io';

import 'package:flutter/services.dart';

import '../../../domain/entities/installed_app.dart';
import '../../../domain/entities/installed_app_size.dart';
import '../../../domain/repositories/installed_apps_repository.dart';

class AndroidInstalledAppsRepository implements InstalledAppsRepository {
  static const _channel = MethodChannel('modi_file_explorer2/installed_apps');
  static final Map<String, Future<Uint8List?>> _iconCache = {};
  static final LinkedHashMap<String, Future<Uint8List?>> _apkIconCache =
      LinkedHashMap<String, Future<Uint8List?>>();
  static final Map<String, Future<InstalledAppSize>> _sizeCache = {};
  static Future<bool>? _usageAccessCache;

  @override
  Future<List<InstalledApp>> listInstalledApps() async {
    final result = await _channel.invokeMethod<List<dynamic>>(
      'listInstalledApps',
    );
    return (result ?? const <dynamic>[]).map((item) {
      final app = Map<String, dynamic>.from(item as Map);
      return InstalledApp(
        name:
            app['name'] as String? ??
            app['packageName'] as String? ??
            'Unknown app',
        packageName: app['packageName'] as String? ?? '',
        version: app['version'] as String? ?? 'Unknown version',
      );
    }).toList();
  }

  @override
  Future<Uint8List?> getAppIcon(String packageName) {
    return _iconCache.putIfAbsent(packageName, () async {
      try {
        return await _channel.invokeMethod<Uint8List>('getInstalledAppIcon', {
          'packageName': packageName,
        });
      } catch (_) {
        _iconCache.remove(packageName);
        rethrow;
      }
    });
  }

  @override
  Future<Uint8List?> getApkIcon(String path, {int size = 64}) async {
    final stat = await File(path).stat();
    final cacheKey =
        '$path:${stat.modified.millisecondsSinceEpoch}:${stat.size}:$size';
    final cached = _apkIconCache.remove(cacheKey);
    if (cached != null) {
      _apkIconCache[cacheKey] = cached;
      return cached;
    }
    final request = _channel.invokeMethod<Uint8List>('getApkIcon', {
      'path': path,
      'size': size,
    });
    _apkIconCache[cacheKey] = request;
    while (_apkIconCache.length > 128) {
      _apkIconCache.remove(_apkIconCache.keys.first);
    }
    return request.catchError((Object error) {
      _apkIconCache.remove(cacheKey);
      throw error;
    });
  }

  @override
  Future<InstalledAppSize> getAppSize(String packageName) async {
    final usageAccess = await hasUsageAccess();
    final cacheKey = '$packageName:$usageAccess';
    return _sizeCache.putIfAbsent(cacheKey, () async {
      try {
        final result = await _channel.invokeMapMethod<String, dynamic>(
          'getInstalledAppSize',
          {'packageName': packageName},
        );
        if (result == null || result['apkBytes'] is! int) {
          throw const FormatException('App size response is invalid');
        }
        final totalBytes = result['totalBytes'];
        return InstalledAppSize(
          apkBytes: result['apkBytes'] as int,
          totalBytes: totalBytes is int ? totalBytes : null,
        );
      } catch (_) {
        _sizeCache.remove(cacheKey);
        rethrow;
      }
    });
  }

  @override
  Future<bool> hasUsageAccess() => _usageAccessCache ??= _channel
      .invokeMethod<bool>('hasUsageAccess')
      .then((value) => value ?? false);

  @override
  Future<void> openUsageAccessSettings() =>
      _channel.invokeMethod<void>('openUsageAccessSettings');

  @override
  void clearAppSizeCache() {
    _sizeCache.clear();
    _usageAccessCache = null;
  }
}

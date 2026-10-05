import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/entities/default_file_app.dart';
import '../../domain/repositories/default_file_apps_repository.dart';

class SharedPreferencesDefaultFileAppsRepository
    implements DefaultFileAppsRepository {
  static const _keyPrefix = 'fileOpen.defaultApp.';

  @override
  Future<List<DefaultFileApp>> getAll() async {
    final preferences = await SharedPreferences.getInstance();
    final keys = preferences
        .getKeys()
        .where((key) => key.startsWith(_keyPrefix))
        .toList()
      ..sort();
    return keys.map((key) {
      final extension = key.substring(_keyPrefix.length);
      final encoded = preferences.getString(key);
      if (encoded == null) {
        throw FormatException('Saved default app for $extension is invalid');
      }
      final json = jsonDecode(encoded);
      if (json is! Map<String, dynamic>) {
        throw FormatException('Saved default app for $extension is invalid');
      }
      return DefaultFileApp.fromJson(extension, json);
    }).toList();
  }

  @override
  Future<void> save(DefaultFileApp defaultApp) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      '$_keyPrefix${defaultApp.extension}',
      jsonEncode(defaultApp.toJson()),
    );
  }

  @override
  Future<void> delete(String extension) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove('$_keyPrefix$extension');
  }
}

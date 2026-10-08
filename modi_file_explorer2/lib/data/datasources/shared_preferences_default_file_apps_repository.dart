import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/entities/default_file_app.dart';
import '../../domain/entities/file_type_category.dart';
import '../../domain/repositories/default_file_apps_repository.dart';

class SharedPreferencesDefaultFileAppsRepository
    implements DefaultFileAppsRepository {
  static const _keyPrefix = 'fileOpen.defaultApp.';

  @override
  Future<List<DefaultFileApp>> getAll() async {
    final preferences = await SharedPreferences.getInstance();
    final keys =
        preferences
            .getKeys()
            .where((key) => key.startsWith(_keyPrefix))
            .toList()
          ..sort();
    final entries =
        keys.map((key) {
          final extension = key.substring(_keyPrefix.length);
          final encoded = preferences.getString(key);
          if (encoded == null) {
            throw FormatException(
              'Saved default app for $extension is invalid',
            );
          }
          final json = jsonDecode(encoded);
          if (json is! Map<String, dynamic>) {
            throw FormatException(
              'Saved default app for $extension is invalid',
            );
          }
          final storedExtension = json['extension'];
          return (
            key: key,
            item: DefaultFileApp.fromJson(
              storedExtension is String ? storedExtension : extension,
              json,
            ),
          );
        }).toList()..sort((left, right) {
          int priority(String key) {
            final extension = key.substring(_keyPrefix.length);
            if (extension.startsWith('__category__')) return 0;
            if (extension == FileTypeCategory.legacyImageDefaultStorageKey) {
              return 1;
            }
            return 2;
          }

          final priorityComparison = priority(
            left.key,
          ).compareTo(priority(right.key));
          return priorityComparison == 0
              ? left.key.compareTo(right.key)
              : priorityComparison;
        });

    final normalizedEntries = <String, DefaultFileApp>{};
    for (final entry in entries) {
      final category = entry.item.category == 'Others'
          ? FileTypeCategory.categoryForExtension(entry.item.extension) ??
                entry.item.category
          : entry.item.category;
      final categoryShared =
          !entry.item.extensionSpecific &&
          category != 'Others' &&
          category.isNotEmpty;
      final canonicalExtension = categoryShared
          ? FileTypeCategory.defaultStorageKey(category)
          : entry.item.extension;
      final canonicalDefault = categoryShared || category != entry.item.category
          ? DefaultFileApp(
              extension: canonicalExtension,
              handlerId: entry.item.handlerId,
              category: category,
              mimeType: entry.item.mimeType,
              packageName: entry.item.packageName,
              displayName: entry.item.displayName,
              activityName: entry.item.activityName,
              extensionSpecific: entry.item.extensionSpecific,
              extensions: entry.item.extensions,
            )
          : entry.item;
      normalizedEntries.putIfAbsent(canonicalExtension, () => canonicalDefault);
      if (canonicalExtension != entry.item.extension ||
          entry.key != '$_keyPrefix$canonicalExtension') {
        await preferences.remove(entry.key);
      }
    }
    for (final entry in normalizedEntries.entries) {
      await preferences.setString(
        '$_keyPrefix${entry.key}',
        jsonEncode(entry.value.toJson()),
      );
    }
    return normalizedEntries.values.toList();
  }

  @override
  Future<void> save(DefaultFileApp defaultApp) async {
    final preferences = await SharedPreferences.getInstance();
    final isSharedCategoryDefault =
        !defaultApp.extensionSpecific &&
        defaultApp.category != 'Others' &&
        defaultApp.category.isNotEmpty;
    final extension = isSharedCategoryDefault
        ? FileTypeCategory.defaultStorageKey(defaultApp.category)
        : defaultApp.extension;
    final storedDefault = isSharedCategoryDefault
        ? DefaultFileApp(
            extension: extension,
            handlerId: defaultApp.handlerId,
            category: defaultApp.category,
            mimeType: defaultApp.mimeType,
            packageName: defaultApp.packageName,
            displayName: defaultApp.displayName,
            activityName: defaultApp.activityName,
            extensionSpecific: false,
            extensions: defaultApp.extensions,
          )
        : defaultApp;
    await preferences.setString(
      '$_keyPrefix$extension',
      jsonEncode(storedDefault.toJson()),
    );
  }

  @override
  Future<void> delete(String extension) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove('$_keyPrefix$extension');
  }

  @override
  Future<void> clear() async {
    final preferences = await SharedPreferences.getInstance();
    final keys = preferences
        .getKeys()
        .where((key) => key.startsWith(_keyPrefix))
        .toList();
    for (final key in keys) {
      await preferences.remove(key);
    }
  }
}

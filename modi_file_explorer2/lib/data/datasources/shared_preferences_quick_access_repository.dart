import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/entities/quick_access_item.dart';
import '../../domain/repositories/quick_access_repository.dart';

class SharedPreferencesQuickAccessRepository
    implements QuickAccessRepository {
  static const _key = 'quickAccess.items';

  @override
  Future<List<QuickAccessItem>> getAll() async {
    final preferences = await SharedPreferences.getInstance();
    final encoded = preferences.getString(_key);
    if (encoded == null) return [];
    final decoded = jsonDecode(encoded);
    if (decoded is! List) {
      throw const FormatException('Saved quick access items are invalid');
    }
    return decoded.map((item) {
      if (item is! Map<String, dynamic>) {
        throw const FormatException('Saved quick access item is invalid');
      }
      return QuickAccessItem.fromJson(item);
    }).toList();
  }

  @override
  Future<void> save(QuickAccessItem item) async {
    final items = await getAll();
    if (items.any((existing) => existing.path == item.path)) return;
    items.add(item);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      _key,
      jsonEncode(items.map((entry) => entry.toJson()).toList()),
    );
  }

  @override
  Future<void> delete(String path) async {
    final items = await getAll();
    items.removeWhere((item) => item.path == path);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      _key,
      jsonEncode(items.map((entry) => entry.toJson()).toList()),
    );
  }
}

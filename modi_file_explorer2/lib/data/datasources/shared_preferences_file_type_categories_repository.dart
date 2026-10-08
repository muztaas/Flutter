import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/entities/file_type_category.dart';
import '../../domain/repositories/file_type_categories_repository.dart';

class SharedPreferencesFileTypeCategoriesRepository
    implements FileTypeCategoriesRepository {
  static const _key = 'fileTypes.categories';

  @override
  Future<List<FileTypeCategory>?> load() async {
    final preferences = await SharedPreferences.getInstance();
    final encoded = preferences.getString(_key);
    if (encoded == null) return null;
    final decoded = jsonDecode(encoded);
    if (decoded is! List) {
      throw const FormatException('Saved file type categories are invalid');
    }
    return decoded.map((item) {
      if (item is! Map<String, dynamic>) {
        throw const FormatException('Saved file type category is invalid');
      }
      return FileTypeCategory.fromJson(item);
    }).toList();
  }

  @override
  Future<void> save(List<FileTypeCategory> categories) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      _key,
      jsonEncode(categories.map((category) => category.toJson()).toList()),
    );
  }

  @override
  Future<void> reset() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(_key);
  }
}

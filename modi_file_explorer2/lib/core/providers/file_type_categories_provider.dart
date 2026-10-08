import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/datasources/shared_preferences_file_type_categories_repository.dart';
import '../../domain/entities/file_type_category.dart';
import '../../domain/repositories/file_type_categories_repository.dart';

final fileTypeCategoriesRepositoryProvider =
    Provider<FileTypeCategoriesRepository>(
      (ref) => SharedPreferencesFileTypeCategoriesRepository(),
    );

final fileTypeCategoriesProvider =
    StateNotifierProvider<FileTypeCategoriesController, List<FileTypeCategory>>(
      (ref) => FileTypeCategoriesController(
        ref.watch(fileTypeCategoriesRepositoryProvider),
      ),
    );

class FileTypeCategoriesController
    extends StateNotifier<List<FileTypeCategory>> {
  FileTypeCategoriesController(this._repository)
    : super(FileTypeCategory.defaults) {
    ready = _load();
  }

  final FileTypeCategoriesRepository _repository;
  late final Future<void> ready;

  Future<void> _load() async {
    final categories = await _repository.load();
    if (categories != null) state = _normalize(categories);
  }

  Future<void> save(List<FileTypeCategory> categories) async {
    await ready;
    final normalized = _normalize(categories);
    await _repository.save(normalized);
    state = normalized;
  }

  Future<void> reset() async {
    await ready;
    await _repository.reset();
    state = FileTypeCategory.defaults;
  }

  List<FileTypeCategory> _normalize(List<FileTypeCategory> categories) {
    final usedExtensions = <String>{};
    return categories.map((category) {
      final extensions = category.extensions
          .map(FileTypeCategory.normalizeExtension)
          .where((extension) => extension.isNotEmpty)
          .where(usedExtensions.add)
          .toList()
        ..sort();
      return FileTypeCategory(name: category.name, extensions: extensions);
    }).toList();
  }
}

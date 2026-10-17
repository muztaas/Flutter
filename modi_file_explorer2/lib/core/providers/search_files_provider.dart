import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/datasources/android/android_search_repository.dart';
import '../../domain/usecases/search_files.dart';
import 'file_type_categories_provider.dart';
import 'storage_providers.dart';

final searchFilesProvider = Provider<SearchFiles>((ref) {
  return SearchFiles(
    AndroidSearchRepository(
      ref.watch(storageRepositoryProvider),
      ref.watch(fileTypeCategoriesRepositoryProvider),
    ),
  );
});

import '../entities/file_type_category.dart';

abstract interface class FileTypeCategoriesRepository {
  Future<List<FileTypeCategory>?> load();
  Future<void> save(List<FileTypeCategory> categories);
  Future<void> reset();
}

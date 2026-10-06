import '../entities/quick_access_item.dart';

abstract interface class QuickAccessRepository {
  Future<List<QuickAccessItem>> getAll();
  Future<void> save(QuickAccessItem item);
  Future<void> delete(String path);
}

import '../entities/sort_rule.dart';

abstract interface class SortRulesRepository {
  Future<List<SortRule>> getAll();
  Future<void> save(SortRule rule);
  Future<void> delete(String id);
}

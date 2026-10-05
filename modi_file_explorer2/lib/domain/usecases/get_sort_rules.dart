import '../entities/sort_rule.dart';
import '../repositories/sort_rules_repository.dart';

class GetSortRules {
  final SortRulesRepository _repository;

  const GetSortRules(this._repository);

  Future<List<SortRule>> call() => _repository.getAll();
}

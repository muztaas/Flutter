import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/datasources/android/hive_sort_rules_repository.dart';
import '../../domain/entities/sort_rule.dart';
import '../../domain/repositories/sort_rules_repository.dart';
import '../../domain/usecases/get_sort_rules.dart';

final sortRulesRepositoryProvider = Provider<SortRulesRepository>(
  (ref) => HiveSortRulesRepository(),
);

final sortRulesProvider =
    StateNotifierProvider<SortRulesController, AsyncValue<List<SortRule>>>((
      ref,
    ) {
      final repository = ref.watch(sortRulesRepositoryProvider);
      return SortRulesController(GetSortRules(repository), repository);
    });

class SortRulesController extends StateNotifier<AsyncValue<List<SortRule>>> {
  final GetSortRules _getSortRules;
  final SortRulesRepository _repository;
  late final Future<void> ready;

  SortRulesController(this._getSortRules, this._repository)
    : super(const AsyncLoading()) {
    ready = reload();
  }

  Future<void> reload() async {
    try {
      state = AsyncData(await _getSortRules());
    } catch (error, stackTrace) {
      state = AsyncError(error, stackTrace);
      rethrow;
    }
  }

  Future<void> save(SortRule rule) async {
    await ready;
    await _repository.save(rule);
    state = AsyncData(await _getSortRules());
  }

  Future<void> delete(String id) async {
    await ready;
    await _repository.delete(id);
    state = AsyncData(await _getSortRules());
  }
}

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/datasources/shared_preferences_quick_access_repository.dart';
import '../../domain/entities/quick_access_item.dart';
import '../../domain/repositories/quick_access_repository.dart';

final quickAccessRepositoryProvider = Provider<QuickAccessRepository>(
  (ref) => SharedPreferencesQuickAccessRepository(),
);

final quickAccessProvider =
    StateNotifierProvider<QuickAccessController, AsyncValue<List<QuickAccessItem>>>(
      (ref) => QuickAccessController(ref.watch(quickAccessRepositoryProvider)),
    );

class QuickAccessController
    extends StateNotifier<AsyncValue<List<QuickAccessItem>>> {
  QuickAccessController(this._repository) : super(const AsyncLoading()) {
    ready = reload();
  }

  final QuickAccessRepository _repository;
  late final Future<void> ready;

  Future<void> reload() async {
    try {
      state = AsyncData(await _repository.getAll());
    } catch (error, stackTrace) {
      state = AsyncError(error, stackTrace);
      rethrow;
    }
  }

  Future<void> toggle(QuickAccessItem item) async {
    await ready;
    final exists = state.asData?.value.any(
      (existing) => existing.path == item.path,
    );
    if (exists == true) {
      await _repository.delete(item.path);
    } else {
      await _repository.save(item);
    }
    await reload();
  }

  Future<void> delete(String path) async {
    await ready;
    await _repository.delete(path);
    await reload();
  }
}

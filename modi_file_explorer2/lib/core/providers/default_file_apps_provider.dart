import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/datasources/shared_preferences_default_file_apps_repository.dart';
import '../../domain/entities/default_file_app.dart';
import '../../domain/repositories/default_file_apps_repository.dart';

final defaultFileAppsRepositoryProvider = Provider<DefaultFileAppsRepository>(
  (ref) => SharedPreferencesDefaultFileAppsRepository(),
);

final defaultFileAppsProvider =
    StateNotifierProvider<DefaultFileAppsController,
      AsyncValue<List<DefaultFileApp>>>((ref) {
        final repository = ref.watch(defaultFileAppsRepositoryProvider);
        return DefaultFileAppsController(repository);
      });

class DefaultFileAppsController
    extends StateNotifier<AsyncValue<List<DefaultFileApp>>> {
  DefaultFileAppsController(this._repository) : super(const AsyncLoading()) {
    ready = reload();
  }

  final DefaultFileAppsRepository _repository;
  late final Future<void> ready;

  Future<void> reload() async {
    try {
      state = AsyncData(await _repository.getAll());
    } catch (error, stackTrace) {
      state = AsyncError(error, stackTrace);
      rethrow;
    }
  }

  Future<DefaultFileApp?> find(String extension) async {
    await ready;
    return state.asData?.value
        .where((item) => item.extension == extension)
        .firstOrNull;
  }

  Future<void> save(DefaultFileApp defaultApp) async {
    await ready;
    await _repository.save(defaultApp);
    await reload();
  }

  Future<void> delete(String extension) async {
    await ready;
    await _repository.delete(extension);
    await reload();
  }
}

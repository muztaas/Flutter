import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/datasources/shared_preferences_default_file_apps_repository.dart';
import '../../domain/entities/default_file_app.dart';
import '../../domain/entities/file_type_category.dart';
import '../../domain/repositories/default_file_apps_repository.dart';

final defaultFileAppsRepositoryProvider = Provider<DefaultFileAppsRepository>(
  (ref) => SharedPreferencesDefaultFileAppsRepository(),
);

final defaultFileAppsProvider =
    StateNotifierProvider<
      DefaultFileAppsController,
      AsyncValue<List<DefaultFileApp>>
    >((ref) {
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

  Future<DefaultFileApp?> find(String extension, {String? category}) async {
    await ready;
    final defaults = state.asData?.value ?? const <DefaultFileApp>[];
    final normalizedExtension = FileTypeCategory.normalizeExtension(extension);
    final exact = defaults
        .where(
          (item) =>
              item.extensionSpecific &&
              item.matchedExtensions.contains(normalizedExtension),
        )
        .firstOrNull;
    if (exact != null) return exact;

    final resolvedCategory =
        category ?? FileTypeCategory.categoryForExtension(normalizedExtension);
    if (resolvedCategory != null && resolvedCategory != 'Others') {
      return defaults
          .where(
            (item) =>
                !item.extensionSpecific && item.category == resolvedCategory,
          )
          .firstOrNull;
    }
    return defaults
        .where((item) => item.extension == normalizedExtension)
        .firstOrNull;
  }

  Future<void> save(DefaultFileApp defaultApp) async {
    await ready;
    if (defaultApp.extensionSpecific) {
      final extensions = defaultApp.matchedExtensions
          .map(FileTypeCategory.normalizeExtension)
          .where((extension) => extension.isNotEmpty)
          .toSet();
      if (extensions.isEmpty) {
        throw ArgumentError('A custom default must include an extension');
      }
      if (extensions.length > 25) {
        throw ArgumentError('A custom default can include up to 25 extensions');
      }
      final defaults = state.asData?.value ?? const <DefaultFileApp>[];
      final isNewDefault = !defaults.any(
        (item) => item.extension == defaultApp.extension,
      );
      if (isNewDefault &&
          defaults.where((item) => item.extensionSpecific).length >= 100) {
        throw StateError('Maximum of 100 custom defaults reached');
      }
      final conflicts = defaults.where(
        (item) =>
            item.extensionSpecific &&
            item.extension != defaultApp.extension &&
            item.matchedExtensions.any(extensions.contains),
      );
      if (conflicts.isNotEmpty) {
        throw StateError(
          'A custom default already uses one of these extensions',
        );
      }
    }
    await _repository.save(defaultApp);
    await reload();
  }

  Future<void> replaceExtensions(DefaultFileApp defaultApp) async {
    await ready;
    final extensions = defaultApp.matchedExtensions
        .map(FileTypeCategory.normalizeExtension)
        .where((extension) => extension.isNotEmpty)
        .toSet();
    if (extensions.isEmpty) {
      throw ArgumentError('A custom default must include an extension');
    }
    if (extensions.length > 25) {
      throw ArgumentError('A custom default can include up to 25 extensions');
    }

    final defaults = state.asData?.value ?? const <DefaultFileApp>[];
    final overlappingCustom = defaults.where(
      (item) =>
          item.extensionSpecific &&
          item.matchedExtensions.any(extensions.contains),
    );
    final replacedOtherDefaults = defaults.where(
      (item) =>
          !item.extensionSpecific &&
          item.category == 'Others' &&
          extensions.contains(item.extension),
    );
    final removedCount = overlappingCustom
        .where((item) => item.matchedExtensions.every(extensions.contains))
        .length;
    final customDefaultCount = defaults
        .where((item) => item.extensionSpecific)
        .length;
    if (customDefaultCount - removedCount >= 100) {
      throw StateError('Maximum of 100 custom defaults reached');
    }

    for (final existing in [...overlappingCustom, ...replacedOtherDefaults]) {
      final remaining = existing.matchedExtensions
          .where((extension) => !extensions.contains(extension))
          .toList();
      if (remaining.isEmpty) {
        await _repository.delete(existing.extension);
      } else {
        await _repository.save(
          DefaultFileApp(
            extension: existing.extension,
            handlerId: existing.handlerId,
            category: existing.category,
            mimeType: existing.mimeType,
            packageName: existing.packageName,
            displayName: existing.displayName,
            activityName: existing.activityName,
            extensionSpecific: true,
            extensions: remaining,
          ),
        );
      }
    }
    await _repository.save(defaultApp);
    await reload();
  }

  Future<void> delete(String extension) async {
    await ready;
    await _repository.delete(extension);
    await reload();
  }

  Future<void> clear() async {
    await ready;
    await _repository.clear();
    await reload();
  }
}

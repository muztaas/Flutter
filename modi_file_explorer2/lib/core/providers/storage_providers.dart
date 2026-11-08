import '../../domain/repositories/storage_repository.dart';
import '../../data/datasources/android/android_storage_repository.dart';
import '../../domain/entities/storage_device.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../filesystem/refresh_coordinator.dart';

final storageRepositoryProvider = Provider<StorageRepository>(
  (ref) => AndroidStorageRepositoryImpl(),
);

StorageRepository getStorageRepository() {
  // return a simple singleton for now
  return AndroidStorageRepositoryImpl();
}

final availableStorageDevicesProvider =
    StateNotifierProvider<
      AvailableStorageDevicesController,
      AsyncValue<List<StorageDevice>>
    >(
      (ref) => AvailableStorageDevicesController(
        ref.watch(storageRepositoryProvider),
      ),
    );

class AvailableStorageDevicesController
    extends StateNotifier<AsyncValue<List<StorageDevice>>> {
  AvailableStorageDevicesController(this._repository)
    : super(const AsyncValue.loading());

  final StorageRepository _repository;
  int _requestId = 0;

  Future<void> refresh() async {
    final requestId = ++_requestId;
    try {
      final devices = await RefreshCoordinator.instance
          .run<List<StorageDevice>>(
            scope: 'storage-devices',
            owner: this,
            priority: RefreshPriority.visiblePage,
            work: (token) async {
              token.throwIfCancelled();
              final result = await _repository.listStorageDevices();
              return RefreshWorkResult(result);
            },
          );
      if (requestId == _requestId) {
        state = AsyncValue.data(devices);
      }
    } on RefreshCancelled {
      return;
    } catch (error, stackTrace) {
      if (requestId == _requestId) {
        state = AsyncValue.error(error, stackTrace);
      }
    }
  }

  @override
  void dispose() {
    RefreshCoordinator.instance.cancelOwner(this);
    super.dispose();
  }
}

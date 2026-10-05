import '../../domain/repositories/storage_repository.dart';
import '../../data/datasources/android/android_storage_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final storageRepositoryProvider = Provider<StorageRepository>(
  (ref) => AndroidStorageRepositoryImpl(),
);

StorageRepository getStorageRepository() {
  // return a simple singleton for now
  return AndroidStorageRepositoryImpl();
}

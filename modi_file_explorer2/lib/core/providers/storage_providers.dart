import '../../domain/repositories/storage_repository.dart';
import '../../data/datasources/android/android_storage_repository.dart';

StorageRepository getStorageRepository() {
  // return a simple singleton for now
  return AndroidStorageRepositoryImpl();
}

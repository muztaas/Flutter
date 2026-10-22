import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/datasources/android/android_archive_repository.dart';
import '../../domain/repositories/archive_repository.dart';

final archiveRepositoryProvider = Provider<ArchiveRepository>(
  (ref) => AndroidArchiveRepository(),
);

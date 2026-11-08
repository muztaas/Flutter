import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/datasources/android/android_csv_file_repository.dart';
import '../../domain/repositories/csv_file_repository.dart';

final csvFileRepositoryProvider = Provider<CsvFileRepository>(
  (ref) => AndroidCsvFileRepository(),
);

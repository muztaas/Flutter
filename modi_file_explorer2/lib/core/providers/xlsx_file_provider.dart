import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/datasources/android/android_xlsx_file_repository.dart';
import '../../domain/repositories/xlsx_file_repository.dart';

final xlsxFileRepositoryProvider = Provider<XlsxFileRepository>(
  (ref) => AndroidXlsxFileRepository(),
);

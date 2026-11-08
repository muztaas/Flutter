import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/datasources/android/android_pptx_file_repository.dart';
import '../../domain/repositories/pptx_file_repository.dart';

final pptxFileRepositoryProvider = Provider<PptxFileRepository>(
  (ref) => AndroidPptxFileRepository(),
);

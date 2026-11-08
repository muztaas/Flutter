import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/datasources/android/android_docx_file_repository.dart';
import '../../domain/repositories/docx_file_repository.dart';

final docxFileRepositoryProvider = Provider<DocxFileRepository>(
  (ref) => AndroidDocxFileRepository(),
);

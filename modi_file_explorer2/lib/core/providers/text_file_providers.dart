import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/datasources/android/android_text_file_repository.dart';
import '../../domain/repositories/text_file_repository.dart';

final textFileRepositoryProvider = Provider<TextFileRepository>(
  (ref) => AndroidTextFileRepository(),
);

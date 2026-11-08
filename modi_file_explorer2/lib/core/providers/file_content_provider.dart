import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/datasources/android/android_file_content_repository.dart';
import '../../domain/repositories/file_content_repository.dart';
import '../../domain/usecases/sniff_file_content.dart';

final fileContentRepositoryProvider = Provider<FileContentRepository>(
  (ref) => AndroidFileContentRepository(),
);

final sniffFileContentProvider = Provider<SniffFileContent>(
  (ref) => SniffFileContent(ref.watch(fileContentRepositoryProvider)),
);

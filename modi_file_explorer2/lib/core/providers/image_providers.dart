import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/datasources/android/android_image_editor_repository.dart';
import '../../data/datasources/android/android_image_repository.dart';
import '../../domain/repositories/image_editor_repository.dart';
import '../../domain/repositories/image_repository.dart';

final imageEditorRepositoryProvider = Provider<ImageEditorRepository>(
  (ref) => AndroidImageEditorRepository(),
);

final imageRepositoryProvider = Provider<ImageRepository>(
  (ref) => AndroidImageRepository(),
);

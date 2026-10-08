import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/datasources/android/android_image_repository.dart';
import '../../domain/repositories/image_repository.dart';

final imageRepositoryProvider = Provider<ImageRepository>(
  (ref) => AndroidImageRepository(),
);

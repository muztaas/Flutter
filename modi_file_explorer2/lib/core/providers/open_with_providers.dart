import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/datasources/android/android_open_with_repository.dart';
import '../../domain/repositories/open_with_repository.dart';

final openWithRepositoryProvider = Provider<OpenWithRepository>(
  (ref) => AndroidOpenWithRepository(),
);

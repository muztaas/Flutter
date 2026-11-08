import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/datasources/android/android_device_power_repository.dart';
import '../../domain/repositories/device_power_repository.dart';

final devicePowerRepositoryProvider = Provider<DevicePowerRepository>(
  (ref) => AndroidDevicePowerRepository(),
);

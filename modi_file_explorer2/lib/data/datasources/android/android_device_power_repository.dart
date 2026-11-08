import 'package:flutter/services.dart';

import '../../../domain/repositories/device_power_repository.dart';

class AndroidDevicePowerRepository implements DevicePowerRepository {
  static const _channel = MethodChannel('modi_file_explorer2/device_power');

  @override
  Future<DevicePowerState> getPowerState() async {
    final result = await _channel.invokeMapMethod<String, Object?>(
      'getPowerState',
    );
    if (result == null) {
      throw PlatformException(
        code: 'POWER_STATE_UNAVAILABLE',
        message: 'Android did not return power state.',
      );
    }
    return DevicePowerState(
      isLowBattery: result['lowBattery'] == true,
      isBatterySaverEnabled: result['batterySaver'] == true,
    );
  }
}

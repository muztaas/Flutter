class DevicePowerState {
  const DevicePowerState({
    required this.isLowBattery,
    required this.isBatterySaverEnabled,
  });

  final bool isLowBattery;
  final bool isBatterySaverEnabled;
}

abstract interface class DevicePowerRepository {
  Future<DevicePowerState> getPowerState();
}

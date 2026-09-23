import 'package:flutter_riverpod/flutter_riverpod.dart';

class SettingsPanelController extends StateNotifier<bool> {
  SettingsPanelController(): super(false);

  void open() => state = true;
  void close() => state = false;
  void toggle() => state = !state;
}

final settingsPanelProvider = StateNotifierProvider<SettingsPanelController, bool>((ref) {
  return SettingsPanelController();
});

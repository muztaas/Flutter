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

// Global policy used by every StorageTab for every drive and directory.
// TODO(Copilot): Add a Settings switch bound to this provider and persist it as
// `settings.sort.foldersFirst`; changing the provider already re-sorts open tabs.
final foldersFirstProvider = StateProvider<bool>((ref) => true);

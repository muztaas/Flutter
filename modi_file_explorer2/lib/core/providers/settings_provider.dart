import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppSettings {
  const AppSettings({
    this.darkTheme = false,
    this.fontSize = 'medium',
    this.defaultViewMode = 'list',
    this.showHiddenFiles = false,
    this.showNomediaFiles = true,
    this.useSavedDefaultApps = true,
    this.useSavedDefaultAppsForQuickAccess = true,
    this.showModifiedDate = false,
    this.showModifiedTime = false,
    this.showFolderItemCount = false,
    this.showFileSize = false,
  });

  final bool darkTheme;
  final String fontSize;
  final String defaultViewMode;
  final bool showHiddenFiles;
  final bool showNomediaFiles;
  final bool useSavedDefaultApps;
  final bool useSavedDefaultAppsForQuickAccess;
  final bool showModifiedDate;
  final bool showModifiedTime;
  final bool showFolderItemCount;
  final bool showFileSize;

  double get textSizeOffset => switch (fontSize) {
    'small' => -1,
    'large' => 1,
    _ => 0,
  };

  AppSettings copyWith({
    bool? darkTheme,
    String? fontSize,
    String? defaultViewMode,
    bool? showHiddenFiles,
    bool? showNomediaFiles,
    bool? useSavedDefaultApps,
    bool? useSavedDefaultAppsForQuickAccess,
    bool? showModifiedDate,
    bool? showModifiedTime,
    bool? showFolderItemCount,
    bool? showFileSize,
  }) => AppSettings(
    darkTheme: darkTheme ?? this.darkTheme,
    fontSize: fontSize ?? this.fontSize,
    defaultViewMode: defaultViewMode ?? this.defaultViewMode,
    showHiddenFiles: showHiddenFiles ?? this.showHiddenFiles,
    showNomediaFiles: showNomediaFiles ?? this.showNomediaFiles,
    useSavedDefaultApps: useSavedDefaultApps ?? this.useSavedDefaultApps,
    useSavedDefaultAppsForQuickAccess:
        useSavedDefaultAppsForQuickAccess ??
        this.useSavedDefaultAppsForQuickAccess,
    showModifiedDate: showModifiedDate ?? this.showModifiedDate,
    showModifiedTime: showModifiedTime ?? this.showModifiedTime,
    showFolderItemCount: showFolderItemCount ?? this.showFolderItemCount,
    showFileSize: showFileSize ?? this.showFileSize,
  );

  static AppSettings fromPreferences(SharedPreferences preferences) {
    final savedFontSize = preferences.getString('theme.fontSize');
    final legacyTextScale = preferences.getDouble('theme.textScale') ?? 1;
    final fontSize =
        savedFontSize ??
        (legacyTextScale > 1.05
            ? 'large'
            : legacyTextScale < 0.95
            ? 'small'
            : 'medium');
    return AppSettings(
      darkTheme: preferences.getString('theme.mode') == 'dark',
      fontSize: fontSize,
      defaultViewMode:
          preferences.getString('settings.defaultViewMode') ?? 'list',
      showHiddenFiles: preferences.getBool('settings.showHiddenFiles') ?? false,
      showNomediaFiles:
          preferences.getBool('settings.showNomediaFiles') ?? true,
      useSavedDefaultApps:
          preferences.getBool('settings.files.useSavedDefaultApps') ?? true,
      useSavedDefaultAppsForQuickAccess:
          preferences.getBool(
            'settings.files.useSavedDefaultAppsForQuickAccess',
          ) ??
          true,
      showModifiedDate:
          preferences.getBool('settings.showModifiedDate') ?? false,
      showModifiedTime:
          preferences.getBool('settings.showModifiedTime') ?? false,
      showFolderItemCount:
          preferences.getBool('settings.showFolderItemCount') ?? false,
      showFileSize: preferences.getBool('settings.showFileSize') ?? false,
    );
  }
}

class AppSettingsController extends StateNotifier<AppSettings> {
  AppSettingsController([super.initial = const AppSettings()]);

  Future<void> setDarkTheme(bool value) async {
    state = state.copyWith(darkTheme: value);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString('theme.mode', value ? 'dark' : 'light');
  }

  Future<void> setFontSize(String value) async {
    state = state.copyWith(fontSize: value);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString('theme.fontSize', value);
    await preferences.setDouble('theme.textScale', state.textSizeOffset);
  }

  Future<void> setDefaultViewMode(String value) async {
    state = state.copyWith(defaultViewMode: value);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString('settings.defaultViewMode', value);
  }

  Future<void> setShowHiddenFiles(bool value) async {
    state = state.copyWith(showHiddenFiles: value);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool('settings.showHiddenFiles', value);
  }

  Future<void> setShowNomediaFiles(bool value) async {
    state = state.copyWith(showNomediaFiles: value);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool('settings.showNomediaFiles', value);
  }

  Future<void> setUseSavedDefaultApps(bool value) async {
    state = state.copyWith(useSavedDefaultApps: value);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool('settings.files.useSavedDefaultApps', value);
  }

  Future<void> setUseSavedDefaultAppsForQuickAccess(bool value) async {
    state = state.copyWith(useSavedDefaultAppsForQuickAccess: value);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(
      'settings.files.useSavedDefaultAppsForQuickAccess',
      value,
    );
  }

  Future<void> setShowModifiedDate(bool value) async {
    state = state.copyWith(showModifiedDate: value);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool('settings.showModifiedDate', value);
  }

  Future<void> setShowModifiedTime(bool value) async {
    state = state.copyWith(showModifiedTime: value);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool('settings.showModifiedTime', value);
  }

  Future<void> setShowFolderItemCount(bool value) async {
    state = state.copyWith(showFolderItemCount: value);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool('settings.showFolderItemCount', value);
  }

  Future<void> setShowFileSize(bool value) async {
    state = state.copyWith(showFileSize: value);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool('settings.showFileSize', value);
  }
}

final appSettingsProvider =
    StateNotifierProvider<AppSettingsController, AppSettings>(
      (ref) => AppSettingsController(),
    );

class SettingsPanelController extends StateNotifier<bool> {
  SettingsPanelController() : super(false);

  void open() => state = true;
  void close() => state = false;
  void toggle() => state = !state;
}

final settingsPanelProvider =
    StateNotifierProvider<SettingsPanelController, bool>((ref) {
      return SettingsPanelController();
    });

// Global policy used by every StorageTab for every drive and directory.
final foldersFirstProvider = StateProvider<bool>((ref) => true);

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _fontSizePreferenceVersionKey = 'theme.fontSizeVersion';
const _fontSizePreferenceVersion = 2;
const _fontSizeOptions = {'x-small', 'small', 'medium', 'large', 'x-large'};

class AppSettings {
  const AppSettings({
    this.darkTheme = false,
    this.fontSize = 'medium',
    this.use24HourTime = false,
    this.defaultViewMode = 'list',
    this.showHiddenFiles = false,
    this.showNomediaFiles = true,
    this.showFileExtension = true,
    this.useSavedDefaultApps = true,
    this.useSavedDefaultAppsForQuickAccess = true,
    this.showModifiedDate = false,
    this.showModifiedTime = false,
    this.showFolderItemCount = false,
    this.showFileSize = false,
    this.closeAllTabsOnExit = false,
    this.includeOtherStorageDrivesInRecent = false,
    this.showNomediaFilesInRecent = false,
    this.showHiddenFilesInRecent = false,
    this.showAndroidFolderFilesInRecent = false,
    this.hideAndroidFoldersInCategoryPages = false,
    this.includeOtherDrivesInCategoryPages = true,
    this.defaultStartupTab = 'default',
    this.alwaysOpenTabs = const ['internal'],
  });

  final bool darkTheme;
  final String fontSize;
  final bool use24HourTime;
  final String defaultViewMode;
  final bool showHiddenFiles;
  final bool showNomediaFiles;
  final bool showFileExtension;
  final bool useSavedDefaultApps;
  final bool useSavedDefaultAppsForQuickAccess;
  final bool showModifiedDate;
  final bool showModifiedTime;
  final bool showFolderItemCount;
  final bool showFileSize;
  final bool closeAllTabsOnExit;
  final bool includeOtherStorageDrivesInRecent;
  final bool showNomediaFilesInRecent;
  final bool showHiddenFilesInRecent;
  final bool showAndroidFolderFilesInRecent;
  final bool hideAndroidFoldersInCategoryPages;
  final bool includeOtherDrivesInCategoryPages;
  final String defaultStartupTab;
  final List<String> alwaysOpenTabs;

  double get textSizeOffset => switch (fontSize) {
    'x-small' => -1,
    'small' => 1,
    'medium' => 3,
    'large' => 5,
    'x-large' => 7,
    _ => 3,
  };

  AppSettings copyWith({
    bool? darkTheme,
    String? fontSize,
    bool? use24HourTime,
    String? defaultViewMode,
    bool? showHiddenFiles,
    bool? showNomediaFiles,
    bool? showFileExtension,
    bool? useSavedDefaultApps,
    bool? useSavedDefaultAppsForQuickAccess,
    bool? showModifiedDate,
    bool? showModifiedTime,
    bool? showFolderItemCount,
    bool? showFileSize,
    bool? closeAllTabsOnExit,
    bool? includeOtherStorageDrivesInRecent,
    bool? showNomediaFilesInRecent,
    bool? showHiddenFilesInRecent,
    bool? showAndroidFolderFilesInRecent,
    bool? hideAndroidFoldersInCategoryPages,
    bool? includeOtherDrivesInCategoryPages,
    String? defaultStartupTab,
    List<String>? alwaysOpenTabs,
  }) => AppSettings(
    darkTheme: darkTheme ?? this.darkTheme,
    fontSize: fontSize ?? this.fontSize,
    use24HourTime: use24HourTime ?? this.use24HourTime,
    defaultViewMode: defaultViewMode ?? this.defaultViewMode,
    showHiddenFiles: showHiddenFiles ?? this.showHiddenFiles,
    showNomediaFiles: showNomediaFiles ?? this.showNomediaFiles,
    showFileExtension: showFileExtension ?? this.showFileExtension,
    useSavedDefaultApps: useSavedDefaultApps ?? this.useSavedDefaultApps,
    useSavedDefaultAppsForQuickAccess:
        useSavedDefaultAppsForQuickAccess ??
        this.useSavedDefaultAppsForQuickAccess,
    showModifiedDate: showModifiedDate ?? this.showModifiedDate,
    showModifiedTime: showModifiedTime ?? this.showModifiedTime,
    showFolderItemCount: showFolderItemCount ?? this.showFolderItemCount,
    showFileSize: showFileSize ?? this.showFileSize,
    closeAllTabsOnExit: closeAllTabsOnExit ?? this.closeAllTabsOnExit,
    includeOtherStorageDrivesInRecent:
        includeOtherStorageDrivesInRecent ??
        this.includeOtherStorageDrivesInRecent,
    showNomediaFilesInRecent:
        showNomediaFilesInRecent ?? this.showNomediaFilesInRecent,
    showHiddenFilesInRecent:
        showHiddenFilesInRecent ?? this.showHiddenFilesInRecent,
    showAndroidFolderFilesInRecent:
        showAndroidFolderFilesInRecent ?? this.showAndroidFolderFilesInRecent,
    hideAndroidFoldersInCategoryPages:
        hideAndroidFoldersInCategoryPages ??
        this.hideAndroidFoldersInCategoryPages,
    includeOtherDrivesInCategoryPages:
        includeOtherDrivesInCategoryPages ??
        this.includeOtherDrivesInCategoryPages,
    defaultStartupTab: defaultStartupTab ?? this.defaultStartupTab,
    alwaysOpenTabs: alwaysOpenTabs ?? this.alwaysOpenTabs,
  );

  static AppSettings fromPreferences(SharedPreferences preferences) {
    final savedFontSize = preferences.getString('theme.fontSize');
    final fontSize = _fontSizeOptions.contains(savedFontSize)
        ? savedFontSize!
        : 'medium';
    final legacyStartupDrive = preferences.getString('storage.startupDrive');
    final savedStartupTab = preferences.getString('storage.startupTab');
    final savedAlwaysOpenTabs = preferences.getStringList(
      'storage.alwaysOpenTabs',
    );
    return AppSettings(
      darkTheme: preferences.getString('theme.mode') == 'dark',
      fontSize: fontSize,
      use24HourTime: preferences.getBool('settings.use24HourTime') ?? false,
      defaultViewMode:
          preferences.getString('settings.defaultViewMode') ?? 'list',
      showHiddenFiles: preferences.getBool('settings.showHiddenFiles') ?? false,
      showNomediaFiles:
          preferences.getBool('settings.showNomediaFiles') ?? true,
      showFileExtension:
          preferences.getBool('settings.files.showFileExtension') ?? true,
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
      closeAllTabsOnExit:
          preferences.getBool('settings.closeAllTabsOnExit') ?? false,
      includeOtherStorageDrivesInRecent:
          preferences.getBool('settings.includeOtherStorageDrivesInRecent') ??
          false,
      showNomediaFilesInRecent:
          preferences.getBool('settings.files.showNomediaFilesInRecent') ??
          false,
      showHiddenFilesInRecent:
          preferences.getBool('settings.files.showHiddenFilesInRecent') ??
          false,
      showAndroidFolderFilesInRecent:
          preferences.getBool(
            'settings.files.showAndroidFolderFilesInRecent',
          ) ??
          false,
      hideAndroidFoldersInCategoryPages:
          preferences.getBool(
            'settings.files.hideAndroidFoldersInCategoryPages',
          ) ??
          false,
      includeOtherDrivesInCategoryPages:
          preferences.getBool('settings.includeOtherDrivesInCategoryPages') ??
          true,
      defaultStartupTab:
          savedStartupTab ??
          (legacyStartupDrive == null || legacyStartupDrive.isEmpty
              ? 'default'
              : 'drive:$legacyStartupDrive'),
      alwaysOpenTabs: savedAlwaysOpenTabs == null
          ? const ['internal']
          : List.unmodifiable(
              savedAlwaysOpenTabs.where(
                (page) => page != 'home' && page != 'default',
              ),
            ),
    );
  }
}

class AppSettingsController extends StateNotifier<AppSettings> {
  AppSettingsController([super.initial = const AppSettings()]);

  Future<void> loadFromPreferences(SharedPreferences preferences) async {
    final savedVersion = preferences.getInt(_fontSizePreferenceVersionKey);
    if (savedVersion != _fontSizePreferenceVersion) {
      state = AppSettings.fromPreferences(
        preferences,
      ).copyWith(fontSize: 'medium');
      await preferences.setString('theme.fontSize', 'medium');
      await preferences.remove('theme.textScale');
      await preferences.setInt(
        _fontSizePreferenceVersionKey,
        _fontSizePreferenceVersion,
      );
      return;
    }
    state = AppSettings.fromPreferences(preferences);
  }

  Future<void> setDarkTheme(bool value) async {
    state = state.copyWith(darkTheme: value);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString('theme.mode', value ? 'dark' : 'light');
  }

  Future<void> setFontSize(String value) async {
    if (!_fontSizeOptions.contains(value)) {
      throw ArgumentError.value(value, 'value', 'Unsupported font size');
    }
    state = state.copyWith(fontSize: value);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString('theme.fontSize', value);
    await preferences.setInt(
      _fontSizePreferenceVersionKey,
      _fontSizePreferenceVersion,
    );
  }

  Future<void> setUse24HourTime(bool value) async {
    state = state.copyWith(use24HourTime: value);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool('settings.use24HourTime', value);
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

  Future<void> setShowNomediaFilesInRecent(bool value) async {
    state = state.copyWith(showNomediaFilesInRecent: value);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool('settings.files.showNomediaFilesInRecent', value);
  }

  Future<void> setShowHiddenFilesInRecent(bool value) async {
    state = state.copyWith(showHiddenFilesInRecent: value);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool('settings.files.showHiddenFilesInRecent', value);
  }

  Future<void> setShowFileExtension(bool value) async {
    state = state.copyWith(showFileExtension: value);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool('settings.files.showFileExtension', value);
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

  Future<void> setCloseAllTabsOnExit(bool value) async {
    state = state.copyWith(closeAllTabsOnExit: value);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool('settings.closeAllTabsOnExit', value);
  }

  Future<void> setIncludeOtherStorageDrivesInRecent(bool value) async {
    state = state.copyWith(includeOtherStorageDrivesInRecent: value);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(
      'settings.includeOtherStorageDrivesInRecent',
      value,
    );
  }

  Future<void> setShowAndroidFolderFilesInRecent(bool value) async {
    state = state.copyWith(showAndroidFolderFilesInRecent: value);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(
      'settings.files.showAndroidFolderFilesInRecent',
      value,
    );
  }

  Future<void> setHideAndroidFoldersInCategoryPages(bool value) async {
    state = state.copyWith(hideAndroidFoldersInCategoryPages: value);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(
      'settings.files.hideAndroidFoldersInCategoryPages',
      value,
    );
  }

  Future<void> setIncludeOtherDrivesInCategoryPages(bool value) async {
    state = state.copyWith(includeOtherDrivesInCategoryPages: value);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(
      'settings.includeOtherDrivesInCategoryPages',
      value,
    );
  }

  Future<void> setDefaultStartupTab(String value) async {
    state = state.copyWith(defaultStartupTab: value);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString('storage.startupTab', value);
    await preferences.remove('storage.startupDrive');
  }

  Future<void> setAlwaysOpenTabs(List<String> values) async {
    final uniqueValues = values
        .where((value) => value != 'home' && value != 'default')
        .toSet()
        .toList(growable: false);
    state = state.copyWith(alwaysOpenTabs: List.unmodifiable(uniqueValues));
    final preferences = await SharedPreferences.getInstance();
    await preferences.setStringList('storage.alwaysOpenTabs', uniqueValues);
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

final settingsPanelDragProgressProvider = StateProvider<double?>((ref) => null);

// Global policy used by every StorageTab for every drive and directory.
final foldersFirstProvider = StateProvider<bool>((ref) => true);

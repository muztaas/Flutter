import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/providers/default_file_apps_provider.dart';
import '../../core/providers/file_type_categories_provider.dart';
import '../../core/providers/open_with_providers.dart';
import '../../core/providers/settings_provider.dart';
import '../../core/providers/storage_providers.dart';
import '../../core/providers/video_providers.dart';
import '../../core/constants/branding.dart';
import '../../core/utils/extension_parser.dart';
import '../../core/utils/startup_page_order.dart';
import '../../domain/entities/default_file_app.dart';
import '../../domain/entities/file_type_category.dart';
import '../../domain/entities/open_with_app.dart';
import '../../domain/entities/storage_device.dart';
import '../about/about_page.dart';
import '../video/widgets/video_sort_picker.dart';

const _appThemeChannel = MethodChannel('modi_file_explorer2/app_theme');

String _startupLabel(String pageId, List<StorageDevice> devices) =>
    startupPageChoices(devices, includeDefaultAndHome: false)
        .where((choice) => choice.$1 == pageId)
        .map((choice) => choice.$2)
        .firstOrNull ??
    pageId;

bool _hasOtherDrives(AsyncValue<List<StorageDevice>> devices) =>
    devices.whenOrNull(
      data: (available) => available.any((device) => device.id != 'internal'),
    ) ??
    false;

Widget _otherDrivesSubtitle(AsyncValue<List<StorageDevice>> devices) =>
    devices.when(
      data: (available) => available.any((device) => device.id != 'internal')
          ? const SizedBox.shrink()
          : const Text('No other drives available'),
      loading: () => const Text('Checking drive availability...'),
      error: (error, _) => Text('Could not check drives: $error'),
    );

class SettingsPanel extends ConsumerStatefulWidget {
  /// The key attached to the tab header row. Its rendered height is used as
  /// the overlay's top edge so the header remains visible above the panel.
  const SettingsPanel({super.key, this.tabHeaderKey});

  final GlobalKey? tabHeaderKey;

  @override
  ConsumerState<SettingsPanel> createState() => _SettingsPanelState();
}

class _SettingsPanelState extends ConsumerState<SettingsPanel>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim;
  final ScrollController _settingsScrollController = ScrollController();
  double _tabHeaderHeight = 0;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
  }

  @override
  void dispose() {
    _anim.dispose();
    _settingsScrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scheduleTabHeaderMeasurement();
  }

  void _scheduleTabHeaderMeasurement() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || widget.tabHeaderKey == null) return;
      final renderObject = widget.tabHeaderKey!.currentContext
          ?.findRenderObject();
      if (renderObject is RenderBox &&
          renderObject.hasSize &&
          renderObject.size.height != _tabHeaderHeight) {
        setState(() => _tabHeaderHeight = renderObject.size.height);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final open = ref.watch(settingsPanelProvider);
    final dragProgress = ref.watch(settingsPanelDragProgressProvider);
    ref.listen<double?>(settingsPanelDragProgressProvider, (previous, next) {
      if (next != null) {
        _anim
          ..stop()
          ..value = next.clamp(0, 1).toDouble();
      }
    });
    final settings = ref.watch(appSettingsProvider);
    final availableDevices = ref.watch(availableStorageDevicesProvider);
    _scheduleTabHeaderMeasurement();
    // drive animation
    if (dragProgress == null) {
      if (open) {
        _anim.forward();
      } else {
        _anim.reverse();
      }
    }

    final width = MediaQuery.of(context).size.width * 0.8;
    final topInset = MediaQuery.of(context).padding.top;

    return IgnorePointer(
      ignoring: !open && dragProgress == null,
      child: AnimatedBuilder(
        animation: _anim,
        builder: (context, child) {
          final slide = Tween<Offset>(
            begin: const Offset(-1, 0),
            end: Offset.zero,
          ).evaluate(_anim);
          return Stack(
            children: [
              Positioned(
                // The overlay is positioned in the screen-level Stack, so
                // include the status-bar inset before placing it below the
                // tab header.
                top: topInset + _tabHeaderHeight,
                left: 0,
                right: 0,
                // Cover the complete screen, including the system gesture or
                // navigation-bar area. SafeArea below keeps panel content
                // clear of that area without leaving the underlying screen
                // exposed or hit-testable.
                bottom: 0,
                child: Stack(
                  children: [
                    // scrim + dismiss area (right 20%)
                    GestureDetector(
                      onTap: () =>
                          ref.read(settingsPanelProvider.notifier).close(),
                      child: Container(
                        width: MediaQuery.of(context).size.width,
                        height: MediaQuery.of(context).size.height,
                        color:
                            (settings.darkTheme
                                    ? Colors.black
                                    : Theme.of(context).colorScheme.onSurface)
                                .withValues(alpha: 0.6 * _anim.value),
                      ),
                    ),
                    // panel
                    Transform.translate(
                      offset: Offset(slide.dx * width, 0),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Theme(
                          data: ThemeData(
                            colorScheme:
                                ColorScheme.fromSeed(
                                  seedColor: const Color(0xFF1565C0),
                                  brightness: settings.darkTheme
                                      ? Brightness.dark
                                      : Brightness.light,
                                ).copyWith(
                                  surface: settings.darkTheme
                                      ? const Color(0xFF292B30)
                                      : const Color(0xFFE4E6E9),
                                ),
                            useMaterial3: true,
                          ),
                          child: Material(
                            color: settings.darkTheme
                                ? const Color(0xFF292B30)
                                : const Color(0xFFE4E6E9),
                            child: SizedBox(
                              width: width,
                              height: double.infinity,
                              child: SafeArea(
                                child: Scrollbar(
                                  controller: _settingsScrollController,
                                  thumbVisibility: true,
                                  interactive: true,
                                  child: SingleChildScrollView(
                                    controller: _settingsScrollController,
                                    primary: false,
                                    child: Padding(
                                      padding: const EdgeInsets.all(16.0),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            'Settings',
                                            key: ValueKey(
                                              'settings-title-${settings.fontSize}',
                                            ),
                                            style: TextStyle(fontSize: 24),
                                          ),
                                          const SizedBox(height: 16),
                                          ExpansionTile(
                                            title: Text(
                                              'Appearance',
                                              key: ValueKey(
                                                'settings-appearance-${settings.fontSize}',
                                              ),
                                            ),
                                            children: [
                                              ListTile(
                                                title: Text('Dark Theme'),
                                                trailing: Switch.adaptive(
                                                  value: settings.darkTheme,
                                                  onChanged: (value) =>
                                                      _saveSetting(
                                                        context,
                                                        () async {
                                                          await ref
                                                              .read(
                                                                appSettingsProvider
                                                                    .notifier,
                                                              )
                                                              .setDarkTheme(
                                                                value,
                                                              );
                                                          await _appThemeChannel
                                                              .invokeMethod<
                                                                void
                                                              >(
                                                                'setDarkTheme',
                                                                {
                                                                  'enabled':
                                                                      value,
                                                                },
                                                              );
                                                        },
                                                      ),
                                                ),
                                              ),
                                              ListTile(
                                                title: Text('Default view'),
                                                trailing: DropdownButton<String>(
                                                  value:
                                                      settings.defaultViewMode,
                                                  items: [
                                                    DropdownMenuItem(
                                                      value: 'list',
                                                      child: Text('List'),
                                                    ),
                                                    DropdownMenuItem(
                                                      value: 'grid',
                                                      child: Text('Grid'),
                                                    ),
                                                  ],
                                                  onChanged: (value) {
                                                    if (value == null) return;
                                                    _saveSetting(
                                                      context,
                                                      () => ref
                                                          .read(
                                                            appSettingsProvider
                                                                .notifier,
                                                          )
                                                          .setDefaultViewMode(
                                                            value,
                                                          ),
                                                    );
                                                  },
                                                ),
                                              ),
                                              ListTile(
                                                title: Text('Font size'),
                                                trailing: DropdownButton<String>(
                                                  value: settings.fontSize,
                                                  items: [
                                                    DropdownMenuItem(
                                                      value: 'x-small',
                                                      child: Text('X-small'),
                                                    ),
                                                    DropdownMenuItem(
                                                      value: 'small',
                                                      child: Text('Small'),
                                                    ),
                                                    DropdownMenuItem(
                                                      value: 'medium',
                                                      child: Text('Medium'),
                                                    ),
                                                    DropdownMenuItem(
                                                      value: 'large',
                                                      child: Text('Large'),
                                                    ),
                                                    DropdownMenuItem(
                                                      value: 'x-large',
                                                      child: Text('X-large'),
                                                    ),
                                                  ],
                                                  onChanged: (value) {
                                                    if (value == null) return;
                                                    _saveSetting(
                                                      context,
                                                      () => ref
                                                          .read(
                                                            appSettingsProvider
                                                                .notifier,
                                                          )
                                                          .setFontSize(value),
                                                    );
                                                  },
                                                ),
                                              ),
                                              _SettingsSwitch(
                                                title:
                                                    'Show time in 24-hour format',
                                                value: settings.use24HourTime,
                                                onChanged: (value) =>
                                                    _saveSetting(
                                                      context,
                                                      () => ref
                                                          .read(
                                                            appSettingsProvider
                                                                .notifier,
                                                          )
                                                          .setUse24HourTime(
                                                            value,
                                                          ),
                                                    ),
                                              ),
                                              _SettingsSwitch(
                                                title: 'Show modified date',
                                                value:
                                                    settings.showModifiedDate,
                                                enabled:
                                                    settings.defaultViewMode !=
                                                    'grid',
                                                subtitle:
                                                    settings.defaultViewMode ==
                                                        'grid'
                                                    ? 'Available in List view only'
                                                    : null,
                                                onChanged: (value) =>
                                                    _saveSetting(
                                                      context,
                                                      () => ref
                                                          .read(
                                                            appSettingsProvider
                                                                .notifier,
                                                          )
                                                          .setShowModifiedDate(
                                                            value,
                                                          ),
                                                    ),
                                              ),
                                              _SettingsSwitch(
                                                title: 'Show modified time',
                                                value:
                                                    settings.showModifiedTime,
                                                enabled:
                                                    settings.defaultViewMode !=
                                                    'grid',
                                                subtitle:
                                                    settings.defaultViewMode ==
                                                        'grid'
                                                    ? 'Available in List view only'
                                                    : null,
                                                onChanged: (value) =>
                                                    _saveSetting(
                                                      context,
                                                      () => ref
                                                          .read(
                                                            appSettingsProvider
                                                                .notifier,
                                                          )
                                                          .setShowModifiedTime(
                                                            value,
                                                          ),
                                                    ),
                                              ),
                                              _SettingsSwitch(
                                                title: 'Show folder item count',
                                                value: settings
                                                    .showFolderItemCount,
                                                onChanged: (value) =>
                                                    _saveSetting(
                                                      context,
                                                      () => ref
                                                          .read(
                                                            appSettingsProvider
                                                                .notifier,
                                                          )
                                                          .setShowFolderItemCount(
                                                            value,
                                                          ),
                                                    ),
                                              ),
                                              _SettingsSwitch(
                                                title: 'Show file size',
                                                value: settings.showFileSize,
                                                onChanged: (value) =>
                                                    _saveSetting(
                                                      context,
                                                      () => ref
                                                          .read(
                                                            appSettingsProvider
                                                                .notifier,
                                                          )
                                                          .setShowFileSize(
                                                            value,
                                                          ),
                                                    ),
                                              ),
                                            ],
                                          ),
                                          ExpansionTile(
                                            onExpansionChanged: (expanded) {
                                              if (expanded) {
                                                ref
                                                    .read(
                                                      availableStorageDevicesProvider
                                                          .notifier,
                                                    )
                                                    .refresh();
                                              }
                                            },
                                            title: Text(
                                              'Tab',
                                              key: ValueKey(
                                                'settings-tabs-${settings.fontSize}',
                                              ),
                                            ),
                                            children: [
                                              _TabSettingsSection(
                                                settings: settings,
                                                availableDevices:
                                                    availableDevices,
                                                saveSetting: _saveSetting,
                                              ),
                                            ],
                                          ),
                                          ExpansionTile(
                                            title: Text(
                                              'Files',
                                              key: ValueKey(
                                                'settings-files-${settings.fontSize}',
                                              ),
                                            ),
                                            children: [
                                              _SettingsSwitch(
                                                title: 'Show file extension',
                                                value:
                                                    settings.showFileExtension,
                                                onChanged: (value) =>
                                                    _saveSetting(
                                                      context,
                                                      () => ref
                                                          .read(
                                                            appSettingsProvider
                                                                .notifier,
                                                          )
                                                          .setShowFileExtension(
                                                            value,
                                                          ),
                                                    ),
                                              ),
                                              _SettingsSwitch(
                                                title: 'Show hidden files',
                                                value: settings.showHiddenFiles,
                                                onChanged: (value) =>
                                                    _saveSetting(
                                                      context,
                                                      () => ref
                                                          .read(
                                                            appSettingsProvider
                                                                .notifier,
                                                          )
                                                          .setShowHiddenFiles(
                                                            value,
                                                          ),
                                                    ),
                                              ),
                                              _SettingsSwitch(
                                                title: 'Show .nomedia files',
                                                value:
                                                    settings.showNomediaFiles,
                                                onChanged: (value) =>
                                                    _saveSetting(
                                                      context,
                                                      () => ref
                                                          .read(
                                                            appSettingsProvider
                                                                .notifier,
                                                          )
                                                          .setShowNomediaFiles(
                                                            value,
                                                          ),
                                                    ),
                                              ),
                                              _SettingsSwitch(
                                                title:
                                                    'Hide Android folders in category pages',
                                                value: settings
                                                    .hideAndroidFoldersInCategoryPages,
                                                onChanged: (value) => _saveSetting(
                                                  context,
                                                  () => ref
                                                      .read(
                                                        appSettingsProvider
                                                            .notifier,
                                                      )
                                                      .setHideAndroidFoldersInCategoryPages(
                                                        value,
                                                      ),
                                                ),
                                              ),
                                              _SettingsSwitch(
                                                title:
                                                    'Show .nomedia files in Recent',
                                                value: settings
                                                    .showNomediaFilesInRecent,
                                                onChanged: (value) => _saveSetting(
                                                  context,
                                                  () => ref
                                                      .read(
                                                        appSettingsProvider
                                                            .notifier,
                                                      )
                                                      .setShowNomediaFilesInRecent(
                                                        value,
                                                      ),
                                                ),
                                              ),
                                              _SettingsSwitch(
                                                title:
                                                    'Show hidden files in Recent',
                                                value: settings
                                                    .showHiddenFilesInRecent,
                                                onChanged: (value) => _saveSetting(
                                                  context,
                                                  () => ref
                                                      .read(
                                                        appSettingsProvider
                                                            .notifier,
                                                      )
                                                      .setShowHiddenFilesInRecent(
                                                        value,
                                                      ),
                                                ),
                                              ),
                                              _SettingsSwitch(
                                                title:
                                                    'Show Android folder files in Recent',
                                                value: settings
                                                    .showAndroidFolderFilesInRecent,
                                                onChanged: (value) => _saveSetting(
                                                  context,
                                                  () => ref
                                                      .read(
                                                        appSettingsProvider
                                                            .notifier,
                                                      )
                                                      .setShowAndroidFolderFilesInRecent(
                                                        value,
                                                      ),
                                                ),
                                              ),
                                              _DefaultAppsSection(
                                                saveSetting: _saveSetting,
                                              ),
                                            ],
                                          ),
                                          ExpansionTile(
                                            onExpansionChanged: (expanded) {
                                              if (expanded) {
                                                ref
                                                    .read(
                                                      availableStorageDevicesProvider
                                                          .notifier,
                                                    )
                                                    .refresh();
                                              }
                                            },
                                            title: Text(
                                              'Storage',
                                              key: ValueKey(
                                                'settings-storage-${settings.fontSize}',
                                              ),
                                            ),
                                            children: [
                                              ListTile(
                                                title: const Text(
                                                  'Include other storage drives in Recent',
                                                ),
                                                subtitle: _otherDrivesSubtitle(
                                                  availableDevices,
                                                ),
                                                trailing: Switch.adaptive(
                                                  value: settings
                                                      .includeOtherStorageDrivesInRecent,
                                                  onChanged:
                                                      _hasOtherDrives(
                                                        availableDevices,
                                                      )
                                                      ? (value) => _saveSetting(
                                                          context,
                                                          () => ref
                                                              .read(
                                                                appSettingsProvider
                                                                    .notifier,
                                                              )
                                                              .setIncludeOtherStorageDrivesInRecent(
                                                                value,
                                                              ),
                                                        )
                                                      : null,
                                                ),
                                              ),
                                              ListTile(
                                                title: const Text(
                                                  'Include other drives in Images, Videos, Documents and other card pages',
                                                ),
                                                subtitle: _otherDrivesSubtitle(
                                                  availableDevices,
                                                ),
                                                trailing: Switch.adaptive(
                                                  value: settings
                                                      .includeOtherDrivesInCategoryPages,
                                                  onChanged:
                                                      _hasOtherDrives(
                                                        availableDevices,
                                                      )
                                                      ? (value) => _saveSetting(
                                                          context,
                                                          () => ref
                                                              .read(
                                                                appSettingsProvider
                                                                    .notifier,
                                                              )
                                                              .setIncludeOtherDrivesInCategoryPages(
                                                                value,
                                                              ),
                                                        )
                                                      : null,
                                                ),
                                              ),
                                              ListTile(
                                                title: const Text('About'),
                                                onTap: () {
                                                  Navigator.of(context).push(
                                                    MaterialPageRoute(
                                                      builder: (_) =>
                                                          const AboutPage(),
                                                    ),
                                                  );
                                                },
                                              ),
                                            ],
                                          ),
                                          _VideoSettingsSection(
                                            saveSetting: _saveSetting,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _saveSetting(
    BuildContext context,
    Future<void> Function() save,
  ) async {
    try {
      await save();
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not save setting: $error')));
    }
  }
}

class _TabSettingsSection extends ConsumerWidget {
  const _TabSettingsSection({
    required this.settings,
    required this.availableDevices,
    required this.saveSetting,
  });

  final AppSettings settings;
  final AsyncValue<List<StorageDevice>> availableDevices;
  final Future<void> Function(
    BuildContext context,
    Future<void> Function() save,
  )
  saveSetting;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final devices = availableDevices.asData?.value ?? const <StorageDevice>[];
    final choices = startupPageChoices(devices);
    final alwaysOpenChoices = startupPageChoices(
      devices,
      includeDefaultAndHome: false,
    );
    final orderedAlwaysOpenTabs = orderStartupPages(
      settings.alwaysOpenTabs,
      devices,
    );
    final defaultTab =
        choices.any((choice) => choice.$1 == settings.defaultStartupTab)
        ? settings.defaultStartupTab
        : 'default';

    return Column(
      children: [
        ListTile(
          title: const Text('Default startup tab'),
          trailing: DropdownButton<String>(
            value: defaultTab,
            items: [
              for (final choice in choices)
                DropdownMenuItem(value: choice.$1, child: Text(choice.$2)),
            ],
            onChanged: (value) {
              if (value == null) return;
              saveSetting(
                context,
                () => ref
                    .read(appSettingsProvider.notifier)
                    .setDefaultStartupTab(value),
              );
            },
          ),
        ),
        ListTile(
          title: const Text('Always open these tabs on startup'),
          subtitle: Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              for (final page in orderedAlwaysOpenTabs)
                InputChip(
                  label: Text(_startupLabel(page, devices)),
                  onDeleted: () {
                    final pages = [...orderedAlwaysOpenTabs]..remove(page);
                    saveSetting(
                      context,
                      () => ref
                          .read(appSettingsProvider.notifier)
                          .setAlwaysOpenTabs(pages),
                    );
                  },
                ),
              PopupMenuButton<String>(
                tooltip: 'Add startup tab',
                onSelected: (page) => saveSetting(
                  context,
                  () => ref
                      .read(appSettingsProvider.notifier)
                      .setAlwaysOpenTabs([...orderedAlwaysOpenTabs, page]),
                ),
                itemBuilder: (context) => [
                  for (final choice in alwaysOpenChoices.where(
                    (choice) => !settings.alwaysOpenTabs.contains(choice.$1),
                  ))
                    PopupMenuItem(value: choice.$1, child: Text(choice.$2)),
                ],
                child: const Padding(
                  padding: EdgeInsets.all(8),
                  child: Icon(Icons.add),
                ),
              ),
            ],
          ),
        ),
        ListTile(
          title: const Text('Close all tabs on exit'),
          trailing: Switch.adaptive(
            value: settings.closeAllTabsOnExit,
            onChanged: (value) => saveSetting(
              context,
              () => ref
                  .read(appSettingsProvider.notifier)
                  .setCloseAllTabsOnExit(value),
            ),
          ),
        ),
      ],
    );
  }
}

class _SettingsSwitch extends StatelessWidget {
  const _SettingsSwitch({
    required this.title,
    required this.value,
    required this.onChanged,
    this.enabled = true,
    this.subtitle,
  });

  final String title;
  final bool value;
  final ValueChanged<bool> onChanged;
  final bool enabled;
  final String? subtitle;

  @override
  Widget build(BuildContext context) => SwitchListTile.adaptive(
    title: Text(title),
    subtitle: subtitle == null ? null : Text(subtitle!),
    value: value,
    onChanged: enabled ? onChanged : null,
  );
}

class _VideoSettingsSection extends ConsumerWidget {
  const _VideoSettingsSection({required this.saveSetting});

  final Future<void> Function(
    BuildContext context,
    Future<void> Function() save,
  )
  saveSetting;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(videoPageSettingsProvider);
    final fontSize = ref.watch(appSettingsProvider).fontSize;
    final controller = ref.read(videoPageSettingsProvider.notifier);
    final headingStyle = Theme.of(context).textTheme.titleMedium;
    Future<void> update(VideoPageSettings next) =>
        saveSetting(context, () => controller.update(next));

    return ExpansionTile(
      title: Text('Video', key: ValueKey('settings-video-$fontSize')),
      children: [
        ExpansionTile(
          title: Text('View', key: ValueKey('settings-video-view-$fontSize')),
          children: [
            ListTile(
              title: Text('View Mode', style: headingStyle),
              dense: true,
              visualDensity: VisualDensity.compact,
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Wrap(
                spacing: 2,
                runSpacing: 2,
                children: [
                  _VideoModeChoice(
                    label: 'Folders',
                    icon: Icons.folder_copy_outlined,
                    selected: settings.viewMode == 'folders',
                    onTap: () => update(settings.copyWith(viewMode: 'folders')),
                  ),
                  _VideoModeChoice(
                    label: 'All folders',
                    icon: Icons.folder_open_outlined,
                    selected: settings.viewMode == 'allFolders',
                    onTap: () =>
                        update(settings.copyWith(viewMode: 'allFolders')),
                  ),
                  _VideoModeChoice(
                    label: 'Files',
                    icon: Icons.video_library_outlined,
                    selected: settings.viewMode == 'files',
                    onTap: () => update(settings.copyWith(viewMode: 'files')),
                  ),
                ],
              ),
            ),
            ListTile(
              title: Text('Layout', style: headingStyle),
              dense: true,
              visualDensity: VisualDensity.compact,
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Wrap(
                spacing: 4,
                children: [
                  ChoiceChip(
                    avatar: const Icon(Icons.view_list, size: 16),
                    label: Text('List', style: headingStyle),
                    selected: settings.layout == 'list',
                    onSelected: (_) =>
                        update(settings.copyWith(layout: 'list')),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                  ),
                  ChoiceChip(
                    avatar: const Icon(Icons.grid_view, size: 16),
                    label: Text('Grid', style: headingStyle),
                    selected: settings.layout == 'grid',
                    onSelected: (_) =>
                        update(settings.copyWith(layout: 'grid')),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                  ),
                ],
              ),
            ),
            ListTile(
              title: Text('Sort', style: headingStyle),
              dense: true,
              visualDensity: VisualDensity.compact,
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: VideoSortPicker(
                field: settings.sortField,
                ascending: settings.sortAscending,
                onChanged: (field, ascending) => update(
                  settings.copyWith(sortField: field, sortAscending: ascending),
                ),
              ),
            ),
          ],
        ),
        ExpansionTile(
          title: Text(
            'Fields',
            key: ValueKey('settings-video-fields-$fontSize'),
          ),
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final cellWidth = constraints.maxWidth / 3;
                  return Wrap(
                    children: [
                      _VideoFieldCheckbox(
                        width: cellWidth,
                        label: 'Thumbnail',
                        value: settings.showThumbnail,
                        onChanged: (value) =>
                            update(settings.copyWith(showThumbnail: value)),
                      ),
                      _VideoFieldCheckbox(
                        width: cellWidth,
                        label: 'Length',
                        value: settings.showLength,
                        onChanged: (value) =>
                            update(settings.copyWith(showLength: value)),
                      ),
                      _VideoFieldCheckbox(
                        width: cellWidth,
                        label: 'File extension',
                        value: settings.showFileExtension,
                        onChanged: (value) =>
                            update(settings.copyWith(showFileExtension: value)),
                      ),
                      _VideoFieldCheckbox(
                        width: cellWidth,
                        label: 'Played time',
                        value: settings.showPlayedTime,
                        onChanged: (value) =>
                            update(settings.copyWith(showPlayedTime: value)),
                      ),
                      _VideoFieldCheckbox(
                        width: cellWidth,
                        label: 'Resolution',
                        value: settings.showResolution,
                        onChanged: (value) =>
                            update(settings.copyWith(showResolution: value)),
                      ),
                      _VideoFieldCheckbox(
                        width: cellWidth,
                        label: 'Frame rate',
                        value: settings.showFrameRate,
                        onChanged: (value) =>
                            update(settings.copyWith(showFrameRate: value)),
                      ),
                      _VideoFieldCheckbox(
                        width: cellWidth,
                        label: 'Path',
                        value: settings.showPath,
                        onChanged: (value) =>
                            update(settings.copyWith(showPath: value)),
                      ),
                      _VideoFieldCheckbox(
                        width: cellWidth,
                        label: 'Size',
                        value: settings.showSize,
                        onChanged: (value) =>
                            update(settings.copyWith(showSize: value)),
                      ),
                      _VideoFieldCheckbox(
                        width: cellWidth,
                        label: 'Date',
                        value: settings.showDate,
                        onChanged: (value) =>
                            update(settings.copyWith(showDate: value)),
                      ),
                      _VideoFieldCheckbox(
                        width: cellWidth,
                        label: 'Contents',
                        value: settings.showContents,
                        onChanged: (value) =>
                            update(settings.copyWith(showContents: value)),
                      ),
                    ],
                  );
                },
              ),
            ),
            SwitchListTile.adaptive(
              title: const Text('Scroll long names'),
              value: settings.scrollLongNames,
              onChanged: (value) =>
                  update(settings.copyWith(scrollLongNames: value)),
            ),
            ListTile(
              title: const Text('Name character limit'),
              enabled: !settings.scrollLongNames,
              trailing: DropdownButton<int>(
                value: settings.nameCharacterLimit,
                items: const [
                  DropdownMenuItem(value: 1000, child: Text('Full / 1000')),
                  DropdownMenuItem(value: 250, child: Text('250')),
                  DropdownMenuItem(value: 120, child: Text('120')),
                  DropdownMenuItem(value: 100, child: Text('100')),
                  DropdownMenuItem(value: 50, child: Text('50')),
                ],
                onChanged: settings.scrollLongNames
                    ? null
                    : (value) {
                        if (value != null) {
                          update(settings.copyWith(nameCharacterLimit: value));
                        }
                      },
              ),
            ),
          ],
        ),
        ExpansionTile(
          title: Text(
            'Advanced',
            key: ValueKey('settings-video-advanced-$fontSize'),
          ),
          children: [
            SwitchListTile.adaptive(
              title: const Text('Display length over thumbnail'),
              value: settings.displayLengthOverThumbnail,
              onChanged: (value) =>
                  update(settings.copyWith(displayLengthOverThumbnail: value)),
            ),
            SwitchListTile.adaptive(
              title: const Text('Show hidden files and folders'),
              value: settings.showHiddenFilesAndFolders,
              onChanged: (value) =>
                  update(settings.copyWith(showHiddenFilesAndFolders: value)),
            ),
            SwitchListTile.adaptive(
              title: const Text('Recognize .nomedia'),
              value: settings.recognizeNomedia,
              onChanged: (value) =>
                  update(settings.copyWith(recognizeNomedia: value)),
            ),
            SwitchListTile.adaptive(
              title: const Text('Return to Videos page after playing'),
              value: settings.returnToVideosAfterPlaying,
              onChanged: (value) =>
                  update(settings.copyWith(returnToVideosAfterPlaying: value)),
            ),
            SwitchListTile.adaptive(
              title: const Text('Show path bar'),
              value: settings.showPathBar,
              onChanged: (value) =>
                  update(settings.copyWith(showPathBar: value)),
            ),
          ],
        ),
      ],
    );
  }
}

class _VideoModeChoice extends StatelessWidget {
  const _VideoModeChoice({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final headingStyle = Theme.of(context).textTheme.titleMedium;
    return ChoiceChip(
      avatar: Icon(icon, size: 16),
      label: Text(label, style: headingStyle),
      selected: selected,
      onSelected: (_) => onTap(),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      padding: const EdgeInsets.symmetric(horizontal: 4),
    );
  }
}

class _VideoFieldCheckbox extends StatelessWidget {
  const _VideoFieldCheckbox({
    required this.width,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final double width;
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 28,
            height: 28,
            child: Checkbox(
              value: value,
              onChanged: (next) {
                if (next != null) onChanged(next);
              },
              visualDensity: VisualDensity.compact,
            ),
          ),
          const SizedBox(width: 3),
          Expanded(
            child: InkWell(
              onTap: () => onChanged(!value),
              child: Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _DefaultAppsSection extends ConsumerWidget {
  const _DefaultAppsSection({required this.saveSetting});

  final Future<void> Function(
    BuildContext context,
    Future<void> Function() save,
  )
  saveSetting;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final defaults = ref.watch(defaultFileAppsProvider);
    return ExpansionTile(
      title: const Text('Default Apps'),
      initiallyExpanded: false,
      children: [
        SwitchListTile.adaptive(
          title: const Text('Open files with saved default apps'),
          subtitle: const Text(
            'When off, show the available apps and built-in features instead',
          ),
          value: ref.watch(appSettingsProvider).useSavedDefaultApps,
          onChanged: (value) => saveSetting(
            context,
            () => ref
                .read(appSettingsProvider.notifier)
                .setUseSavedDefaultApps(value),
          ),
        ),
        SwitchListTile.adaptive(
          title: const Text('Use saved defaults for Quick Access files'),
          subtitle: const Text(
            'When off, Quick Access files show the available apps and built-in features',
          ),
          value: ref
              .watch(appSettingsProvider)
              .useSavedDefaultAppsForQuickAccess,
          onChanged: (value) => saveSetting(
            context,
            () => ref
                .read(appSettingsProvider.notifier)
                .setUseSavedDefaultAppsForQuickAccess(value),
          ),
        ),
        const _FileTypeCategoriesSection(),
        ExpansionTile(
          title: const Text('Your default apps'),
          initiallyExpanded: false,
          children: [
            defaults.when(
              loading: () => const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (error, _) => Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Text('Could not load default apps: $error'),
              ),
              data: (items) => items.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('No default apps'),
                    )
                  : _SettingsScrollableList(
                      height: (items.length.clamp(1, 4) * 76).toDouble(),
                      itemCount: items.length,
                      itemBuilder: (context, index) =>
                          _DefaultFileAppTile(defaultApp: items[index]),
                    ),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            children: [
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () => _addCustomDefault(context, ref),
                  icon: const Icon(Icons.add),
                  label: const Text('Add default'),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () => _resetDefaults(context, ref),
                  icon: const Icon(Icons.restart_alt),
                  label: const Text('Reset defaults'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _addCustomDefault(BuildContext context, WidgetRef ref) async {
    try {
      await ref.read(defaultFileAppsProvider.notifier).ready;
      await ref.read(fileTypeCategoriesProvider.notifier).ready;
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not load defaults: $error')),
      );
      return;
    }
    if (!context.mounted) return;
    final currentDefaults =
        ref.read(defaultFileAppsProvider).asData?.value ?? const [];
    final extensions = await showDialog<List<String>>(
      context: context,
      useRootNavigator: true,
      builder: (_) => const _CustomExtensionsDialog(
        title: 'Add default',
        actionLabel: 'Choose app',
      ),
    );
    if (extensions == null || !context.mounted) return;

    final selected = await _chooseAppForExtensions(context, ref, extensions);
    if (selected == null || !context.mounted) return;

    final categories = ref.read(fileTypeCategoriesProvider);
    final replacements = <(String, DefaultFileApp)>[];
    for (final extension in extensions) {
      final category =
          FileTypeCategory.categoryForExtension(
            extension,
            categories: categories,
          ) ??
          'Others';
      final existing =
          currentDefaults
              .where(
                (item) =>
                    item.extensionSpecific &&
                    item.matchedExtensions.contains(extension),
              )
              .firstOrNull ??
          currentDefaults
              .where(
                (item) =>
                    !item.extensionSpecific &&
                    item.category == category &&
                    category != 'Others',
              )
              .firstOrNull ??
          currentDefaults
              .where((item) => item.extension == extension)
              .firstOrNull;
      if (existing != null) replacements.add((extension, existing));
    }
    if (replacements.isNotEmpty) {
      final confirmed = await showDialog<bool>(
        context: context,
        useRootNavigator: true,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Replace existing defaults?'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(
              shrinkWrap: true,
              children: [
                Text(
                  'These assignments will be replaced with ${selected.name}:',
                ),
                const SizedBox(height: 8),
                for (final (extension, existing) in replacements)
                  Text(
                    '$extension — ${_defaultAppName(existing)}',
                    style: Theme.of(dialogContext).textTheme.bodyMedium,
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () =>
                  Navigator.of(dialogContext, rootNavigator: true).pop(false),
              child: const Text('No'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(dialogContext, rootNavigator: true).pop(true),
              child: const Text('Replace'),
            ),
          ],
        ),
      );
      if (confirmed != true || !context.mounted) return;
    }

    final isTextEditor =
        selected.packageName == DefaultFileApp.textEditorHandlerId;
    final isImageViewer =
        selected.packageName == DefaultFileApp.imageViewerHandlerId;
    final isVideoPlayer =
        selected.packageName == DefaultFileApp.videoPlayerHandlerId;
    final isArchiveManager =
        selected.packageName == DefaultFileApp.archiveManagerHandlerId;
    final distinctCategories = extensions
        .map(
          (extension) =>
              FileTypeCategory.categoryForExtension(
                extension,
                categories: categories,
              ) ??
              'Others',
        )
        .toSet();
    try {
      await ref
          .read(defaultFileAppsProvider.notifier)
          .replaceExtensions(
            DefaultFileApp(
              extension: '__custom__${DateTime.now().microsecondsSinceEpoch}',
              handlerId: isTextEditor
                  ? DefaultFileApp.textEditorHandlerId
                  : isImageViewer
                  ? DefaultFileApp.imageViewerHandlerId
                  : isVideoPlayer
                  ? DefaultFileApp.videoPlayerHandlerId
                  : isArchiveManager
                  ? DefaultFileApp.archiveManagerHandlerId
                  : 'external',
              category: distinctCategories.length == 1
                  ? distinctCategories.single
                  : 'Others',
              mimeType: selected.mimeType,
              packageName:
                  isTextEditor ||
                      isImageViewer ||
                      isVideoPlayer ||
                      isArchiveManager
                  ? null
                  : selected.packageName,
              displayName:
                  isTextEditor ||
                      isImageViewer ||
                      isVideoPlayer ||
                      isArchiveManager
                  ? null
                  : selected.name,
              activityName:
                  isTextEditor ||
                      isImageViewer ||
                      isVideoPlayer ||
                      isArchiveManager
                  ? null
                  : selected.activityName,
              extensionSpecific: true,
              extensions: extensions,
            ),
          );
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save extension defaults: $error')),
      );
    }
  }

  static Future<OpenWithApp?> _chooseAppForExtensions(
    BuildContext context,
    WidgetRef ref,
    List<String> extensions,
  ) async {
    final categories = ref.read(fileTypeCategoriesProvider);
    final repository = ref.read(openWithRepositoryProvider);
    final appsByActivity = <String, OpenWithApp>{};
    final Uint8List? builtInIcon;
    try {
      builtInIcon = await repository.getOwnApplicationIcon();
      final queries = <(String, String)>{
        for (final extension in extensions)
          (
            extension,
            FileTypeCategory.categoryForExtension(
                  extension,
                  categories: categories,
                ) ??
                'Others',
          ),
        for (final extension in extensions) (extension, 'Others'),
        for (final category in categories)
          (
            category.extensions.firstOrNull ??
                FileTypeCategory.defaults
                    .where(
                      (defaultCategory) =>
                          defaultCategory.name == category.name,
                    )
                    .firstOrNull
                    ?.extensions
                    .firstOrNull ??
                '.unknown',
            category.name,
          ),
        ('.unknown', 'Others'),
      };
      final appsByQuery = await Future.wait(
        queries.map(
          (query) => repository.listAppsForType(
            extension: query.$1,
            category: query.$2,
          ),
        ),
      );
      for (final apps in appsByQuery) {
        for (final app in apps) {
          final key = '${app.packageName}/${app.activityName ?? ''}';
          appsByActivity.putIfAbsent(key, () => app);
        }
      }
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not load apps for these extensions: $error'),
          ),
        );
      }
      return null;
    }

    final choices = <OpenWithApp>[
      OpenWithApp(
        name: 'Text Editor (built-in)',
        packageName: DefaultFileApp.textEditorHandlerId,
        mimeType: 'text/plain',
        iconBytes: builtInIcon,
      ),
      OpenWithApp(
        name: 'Image Viewer (built-in)',
        packageName: DefaultFileApp.imageViewerHandlerId,
        mimeType: 'image/*',
        iconBytes: builtInIcon,
      ),
      if (extensions.every(
        (extension) =>
            FileTypeCategory.categoryForExtension(
              extension,
              categories: categories,
            ) ==
            'Video',
      ))
        OpenWithApp(
          name: 'Video Player (built-in)',
          packageName: DefaultFileApp.videoPlayerHandlerId,
          mimeType: 'video/*',
          iconBytes: builtInIcon,
        ),
      if (extensions.every(
        (extension) =>
            FileTypeCategory.categoryForExtension(
              extension,
              categories: categories,
            ) ==
            'Archives',
      ))
        OpenWithApp(
          name: 'Archive Manager (built-in)',
          packageName: DefaultFileApp.archiveManagerHandlerId,
          mimeType: 'application/x-archive',
          iconBytes: builtInIcon,
        ),
      ...appsByActivity.values,
    ];
    if (!context.mounted) return null;

    return showDialog<OpenWithApp>(
      context: context,
      useRootNavigator: true,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('Choose default app'),
        children: [
          for (final app in choices)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialogContext, app),
              child: Row(
                children: [
                  _openWithLeadingIcon(app),
                  const SizedBox(width: 12),
                  Expanded(child: Text(app.name)),
                ],
              ),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(
              'Cancel',
              style: Theme.of(dialogContext).textTheme.labelLarge,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _resetDefaults(BuildContext context, WidgetRef ref) async {
    final scope = await showDialog<_ResetDefaultsScope>(
      context: context,
      useRootNavigator: true,
      builder: (_) => const _ResetDefaultsDialog(),
    );
    if (scope == null || !context.mounted) return;

    try {
      if (scope == _ResetDefaultsScope.extensions ||
          scope == _ResetDefaultsScope.both) {
        await ref.read(fileTypeCategoriesProvider.notifier).reset();
      }
      if (scope == _ResetDefaultsScope.apps ||
          scope == _ResetDefaultsScope.both) {
        await ref.read(defaultFileAppsProvider.notifier).clear();
      }
      if (!context.mounted) return;
      final message = switch (scope) {
        _ResetDefaultsScope.extensions =>
          'Restored built-in file type extensions',
        _ResetDefaultsScope.apps => 'Removed all saved default-app assignments',
        _ResetDefaultsScope.both =>
          'Restored built-in file type extensions and removed saved default-app assignments',
      };
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not reset defaults: $error')),
      );
    }
  }
}

class _FileTypeCategoriesSection extends ConsumerWidget {
  const _FileTypeCategoriesSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final categories = ref.watch(fileTypeCategoriesProvider);
    return ExpansionTile(
      title: const Text('File type extensions'),
      subtitle: const Text('Edit extensions by category'),
      initiallyExpanded: false,
      children: categories.isEmpty
          ? const [ListTile(title: Text('No file type categories'))]
          : [
              _SettingsScrollableList(
                height: (categories.length.clamp(1, 4) * 76).toDouble(),
                itemCount: categories.length,
                itemBuilder: (context, index) {
                  final category = categories[index];
                  return ListTile(
                    title: Text(category.name),
                    subtitle: Text(
                      category.extensions.isEmpty
                          ? 'No extensions'
                          : category.extensions.join(', '),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () => _editCategory(context, ref, category),
                  );
                },
              ),
            ],
    );
  }

  Future<void> _editCategory(
    BuildContext context,
    WidgetRef ref,
    FileTypeCategory category,
  ) async {
    final extensions = await showDialog<List<String>>(
      context: context,
      useRootNavigator: true,
      builder: (_) => _CategoryExtensionsDialog(category: category),
    );
    if (extensions == null || !context.mounted) return;

    final notifier = ref.read(fileTypeCategoriesProvider.notifier);
    try {
      await notifier.ready;
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not load file type categories: $error')),
      );
      return;
    }
    if (!context.mounted) return;
    final currentCategories = ref.read(fileTypeCategoriesProvider);
    final updated = currentCategories
        .map(
          (current) => current.name == category.name
              ? FileTypeCategory(name: current.name, extensions: extensions)
              : current,
        )
        .toList();
    final ownedByOtherCategory = {
      for (final current in currentCategories.where(
        (current) => current.name != category.name,
      ))
        for (final extension in current.extensions) extension: current.name,
    };
    final conflicts = extensions.where((extension) {
      final owner = ownedByOtherCategory[extension];
      final textDocumentsOverlap =
          (category.name == 'Text' && owner == 'Documents') ||
          (category.name == 'Documents' && owner == 'Text');
      return owner != null && !textDocumentsOverlap;
    }).toList();
    if (conflicts.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${conflicts.join(', ')} already belongs to another category',
          ),
        ),
      );
      return;
    }
    try {
      await notifier.save(updated);
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save file type extensions: $error')),
      );
    }
  }
}

class _CategoryExtensionsDialog extends StatefulWidget {
  const _CategoryExtensionsDialog({required this.category});

  final FileTypeCategory category;

  @override
  State<_CategoryExtensionsDialog> createState() =>
      _CategoryExtensionsDialogState();
}

class _CategoryExtensionsDialogState extends State<_CategoryExtensionsDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: widget.category.extensions.join(', '),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('${widget.category.name} extensions'),
    content: TextField(
      controller: _controller,
      minLines: 3,
      maxLines: 6,
      decoration: const InputDecoration(
        labelText: 'Extensions',
        hintText: '.png, .jpg, .jpeg',
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () {
          final parsed =
              _controller.text
                  .split(RegExp(r'[,;\s]+'))
                  .map(FileTypeCategory.normalizeExtension)
                  .where((extension) => extension.length > 1)
                  .toSet()
                  .toList()
                ..sort();
          Navigator.of(context, rootNavigator: true).pop(parsed);
        },
        child: const Text('Save'),
      ),
    ],
  );
}

class _CustomExtensionsDialog extends StatefulWidget {
  const _CustomExtensionsDialog({
    required this.title,
    required this.actionLabel,
    this.initialExtensions = const [],
    this.allowDelete = false,
  });

  final String title;
  final String actionLabel;
  final List<String> initialExtensions;
  final bool allowDelete;

  @override
  State<_CustomExtensionsDialog> createState() =>
      _CustomExtensionsDialogState();
}

class _CustomExtensionsDialogState extends State<_CustomExtensionsDialog> {
  late final TextEditingController _controller;
  String? _validationMessage;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: widget.initialExtensions.join(', '),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final parsed = parseExtensions(
      _controller.text,
      allowSemicolon: widget.allowDelete,
    );
    if (parsed.errors.isNotEmpty) {
      setState(() => _validationMessage = parsed.errors.join('\n'));
      return;
    }
    if (parsed.extensions.length > 25) {
      setState(
        () => _validationMessage =
            'A default can include up to 25 distinct extensions.',
      );
      return;
    }
    Navigator.of(context, rootNavigator: true).pop(parsed.extensions);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: SizedBox(
      width: double.maxFinite,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _controller,
            minLines: widget.allowDelete ? 2 : 1,
            maxLines: widget.allowDelete ? 4 : 3,
            onChanged: (_) {
              if (_validationMessage != null) {
                setState(() => _validationMessage = null);
              }
            },
            decoration: const InputDecoration(
              labelText: 'Extensions (up to 25)',
              hintText: '.zip, .cbz',
              helperText: 'Separate extensions with commas or spaces.',
            ),
          ),
          if (_validationMessage != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 120),
                child: SingleChildScrollView(
                  child: Text(
                    _validationMessage!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
    actions: [
      if (widget.allowDelete)
        TextButton(
          onPressed: () =>
              Navigator.of(context, rootNavigator: true).pop(const <String>[]),
          child: const Text('Delete default'),
        ),
      TextButton(
        onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _submit, child: Text(widget.actionLabel)),
    ],
  );
}

String _defaultAppName(DefaultFileApp defaultApp) {
  if (defaultApp.isTextEditor) return 'Text Editor (built-in)';
  if (defaultApp.isImageViewer) return 'Image Viewer (built-in)';
  if (defaultApp.isVideoPlayer) return 'Video Player (built-in)';
  if (defaultApp.isArchiveManager) return 'Archive Manager (built-in)';
  return defaultApp.displayName?.trim().isNotEmpty == true
      ? defaultApp.displayName!
      : defaultApp.packageName ?? 'Unknown app';
}

enum _ResetDefaultsScope { extensions, apps, both }

class _ResetDefaultsDialog extends StatefulWidget {
  const _ResetDefaultsDialog();

  @override
  State<_ResetDefaultsDialog> createState() => _ResetDefaultsDialogState();
}

class _ResetDefaultsDialogState extends State<_ResetDefaultsDialog> {
  _ResetDefaultsScope? _selected;
  bool _confirming = false;

  String _confirmationText(_ResetDefaultsScope scope) => switch (scope) {
    _ResetDefaultsScope.extensions =>
      'Restore the built-in file type extension lists? Your saved app '
          'assignments will stay unchanged.',
    _ResetDefaultsScope.apps =>
      'Remove all saved default-app assignments? Your file type extension '
          'lists will stay unchanged.',
    _ResetDefaultsScope.both =>
      'Restore the built-in file type extension lists and remove all saved '
          'default-app assignments?',
  };

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(_confirming ? 'Confirm reset' : 'Reset defaults'),
    content: _confirming
        ? Text(_confirmationText(_selected!))
        : SizedBox(
            width: double.maxFinite,
            child: RadioGroup<_ResetDefaultsScope>(
              groupValue: _selected,
              onChanged: (value) => setState(() => _selected = value),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const RadioListTile<_ResetDefaultsScope>(
                    value: _ResetDefaultsScope.extensions,
                    title: Text('App-defined defaults only'),
                    subtitle: Text('Restore the built-in file type extensions'),
                  ),
                  const RadioListTile<_ResetDefaultsScope>(
                    value: _ResetDefaultsScope.apps,
                    title: Text('User-defined defaults only'),
                    subtitle: Text('Remove all saved default-app assignments'),
                  ),
                  const RadioListTile<_ResetDefaultsScope>(
                    value: _ResetDefaultsScope.both,
                    title: Text('Both'),
                    subtitle: Text('Restore extensions and remove assignments'),
                  ),
                ],
              ),
            ),
          ),
    actions: _confirming
        ? [
            TextButton(
              onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
              child: const Text('No'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(context, rootNavigator: true).pop(_selected),
              child: const Text('Yes'),
            ),
          ]
        : [
            TextButton(
              onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: _selected == null
                  ? null
                  : () => setState(() => _confirming = true),
              child: const Text('Continue'),
            ),
          ],
  );
}

class _DefaultFileAppTile extends ConsumerWidget {
  const _DefaultFileAppTile({required this.defaultApp});

  final DefaultFileApp defaultApp;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isCategoryDefault =
        !defaultApp.extensionSpecific && defaultApp.category != 'Others';
    final categoryLabel = switch (defaultApp.category) {
      'Image' => 'Pictures / Images',
      'Video' => 'Videos',
      'Audio' => 'Audio',
      'Archives' => 'Archives',
      'Text' => 'Text',
      _ => defaultApp.category,
    };
    final appName = defaultApp.isTextEditor
        ? Future<String?>.value('Text Editor (built-in)')
        : defaultApp.isImageViewer
        ? Future<String?>.value('Image Viewer (built-in)')
        : defaultApp.activityName != null
        ? Future<String?>.value(defaultApp.displayName)
        : ref
              .read(openWithRepositoryProvider)
              .resolveAppName(defaultApp.packageName ?? '');
    return FutureBuilder<String?>(
      future: appName,
      builder: (context, snapshot) {
        final label = snapshot.data?.trim().isNotEmpty == true
            ? snapshot.data!
            : defaultApp.displayName?.trim().isNotEmpty == true
            ? defaultApp.displayName!
            : defaultApp.packageName ?? 'Unknown app';
        return ListTile(
          title: Text(
            defaultApp.extensionSpecific
                ? defaultApp.matchedExtensions.join(', ')
                : isCategoryDefault
                ? categoryLabel
                : defaultApp.extension,
          ),
          subtitle: Text('Opens with $label'),
          onTap: () => _editDefaultApp(context, ref),
        );
      },
    );
  }

  Future<void> _editDefaultApp(BuildContext context, WidgetRef ref) async {
    if (defaultApp.extensionSpecific) {
      await _editCustomDefault(context, ref);
      return;
    }
    try {
      await ref.read(fileTypeCategoriesProvider.notifier).ready;
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not load file type categories: $error')),
      );
      return;
    }
    if (!context.mounted) return;
    final categories = ref.read(fileTypeCategoriesProvider);
    final appQueryExtension =
        !defaultApp.extensionSpecific && defaultApp.category != 'Others'
        ? categories
              .where((category) => category.name == defaultApp.category)
              .firstOrNull
              ?.extensions
              .firstOrNull
        : defaultApp.extension;
    if (appQueryExtension == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Add an extension to the ${defaultApp.category} category first',
          ),
        ),
      );
      return;
    }
    final List<OpenWithApp> apps;
    try {
      apps = await ref
          .read(openWithRepositoryProvider)
          .listAppsForType(
            extension: appQueryExtension,
            category: defaultApp.category,
          );
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not load compatible apps: $error')),
      );
      return;
    }
    final choices = [
      if (defaultApp.category == 'Text')
        OpenWithApp(
          name: 'Text Editor (built-in)',
          packageName: DefaultFileApp.textEditorHandlerId,
          mimeType: defaultApp.mimeType,
        ),
      if (defaultApp.category == 'Image')
        OpenWithApp(
          name: 'Image Viewer (built-in)',
          packageName: DefaultFileApp.imageViewerHandlerId,
          mimeType: defaultApp.mimeType,
        ),
      if (defaultApp.category == 'Video')
        OpenWithApp(
          name: 'Video Player (built-in)',
          packageName: DefaultFileApp.videoPlayerHandlerId,
          mimeType: 'video/*',
        ),
      if (defaultApp.category == 'Archives')
        OpenWithApp(
          name: 'Archive Manager (built-in)',
          packageName: DefaultFileApp.archiveManagerHandlerId,
          mimeType: 'application/x-archive',
        ),
      ...apps,
    ];
    if (!context.mounted) return;

    final selection = await showDialog<_DefaultAppSelection>(
      context: context,
      useRootNavigator: true,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          defaultApp.category == 'Image'
              ? 'Default app for all images'
              : !defaultApp.extensionSpecific && defaultApp.category != 'Others'
              ? 'Default app for all ${defaultApp.category == 'Archives' ? 'archive' : defaultApp.category.toLowerCase()} files'
              : 'Default app for ${defaultApp.extension}',
        ),
        content: SizedBox(
          width: double.maxFinite,
          height: (choices.length.clamp(1, 4) * 64).toDouble(),
          child: choices.isEmpty
              ? const Center(child: Text('No compatible apps found'))
              : ListView.builder(
                  itemCount: choices.length,
                  itemBuilder: (context, index) => ListTile(
                    leading: _openWithLeadingIcon(choices[index]),
                    title: Text(choices[index].name),
                    subtitle: choices[index].applicationName == null
                        ? null
                        : Text(choices[index].applicationName!),
                    onTap: () => Navigator.of(
                      dialogContext,
                      rootNavigator: true,
                    ).pop(_DefaultAppSelection(app: choices[index])),
                  ),
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(
              dialogContext,
              rootNavigator: true,
            ).pop(const _DefaultAppSelection(delete: true)),
            child: const Text('Delete default'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.of(dialogContext, rootNavigator: true).pop(),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    if (selection == null || !context.mounted) return;

    try {
      if (selection.delete) {
        await ref
            .read(defaultFileAppsProvider.notifier)
            .delete(defaultApp.extension);
      } else if (selection.app != null) {
        final app = selection.app!;
        final isTextEditor =
            app.packageName == DefaultFileApp.textEditorHandlerId;
        final isImageViewer =
            app.packageName == DefaultFileApp.imageViewerHandlerId;
        final isVideoPlayer =
            app.packageName == DefaultFileApp.videoPlayerHandlerId;
        final isArchiveManager =
            app.packageName == DefaultFileApp.archiveManagerHandlerId;
        await ref
            .read(defaultFileAppsProvider.notifier)
            .save(
              DefaultFileApp(
                extension: defaultApp.extension,
                handlerId: isTextEditor
                    ? DefaultFileApp.textEditorHandlerId
                    : isImageViewer
                    ? DefaultFileApp.imageViewerHandlerId
                    : isVideoPlayer
                    ? DefaultFileApp.videoPlayerHandlerId
                    : isArchiveManager
                    ? DefaultFileApp.archiveManagerHandlerId
                    : 'external',
                category: defaultApp.category,
                mimeType: app.mimeType,
                packageName:
                    isTextEditor ||
                        isImageViewer ||
                        isVideoPlayer ||
                        isArchiveManager
                    ? null
                    : app.packageName,
                displayName:
                    isTextEditor ||
                        isImageViewer ||
                        isVideoPlayer ||
                        isArchiveManager
                    ? null
                    : app.name,
                activityName:
                    isTextEditor ||
                        isImageViewer ||
                        isVideoPlayer ||
                        isArchiveManager
                    ? null
                    : app.activityName,
                extensionSpecific: defaultApp.extensionSpecific,
              ),
            );
      }
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not update default app: $error')),
      );
    }
  }

  Future<void> _editCustomDefault(BuildContext context, WidgetRef ref) async {
    try {
      await ref.read(fileTypeCategoriesProvider.notifier).ready;
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not load file type categories: $error')),
      );
      return;
    }
    if (!context.mounted) return;
    final extensions = await showDialog<List<String>>(
      context: context,
      useRootNavigator: true,
      builder: (_) => _CustomExtensionsDialog(
        title: 'Edit extension default',
        actionLabel: 'Change app',
        initialExtensions: defaultApp.matchedExtensions,
        allowDelete: true,
      ),
    );
    if (extensions == null || !context.mounted) return;
    final defaults =
        ref.read(defaultFileAppsProvider).asData?.value ?? const [];
    if (extensions.isEmpty) {
      try {
        await ref
            .read(defaultFileAppsProvider.notifier)
            .delete(defaultApp.extension);
      } catch (error) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not delete default app: $error')),
        );
      }
      return;
    }
    final conflicts = extensions.where((extension) {
      return defaults.any(
        (item) =>
            item.extension != defaultApp.extension &&
            item.extensionSpecific &&
            item.matchedExtensions.contains(extension),
      );
    }).toList();
    if (conflicts.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('A default already exists for ${conflicts.join(', ')}'),
        ),
      );
      return;
    }
    final selected = await _DefaultAppsSection._chooseAppForExtensions(
      context,
      ref,
      extensions,
    );
    if (selected == null || !context.mounted) return;
    final isTextEditor =
        selected.packageName == DefaultFileApp.textEditorHandlerId;
    final isImageViewer =
        selected.packageName == DefaultFileApp.imageViewerHandlerId;
    final isVideoPlayer =
        selected.packageName == DefaultFileApp.videoPlayerHandlerId;
    final isArchiveManager =
        selected.packageName == DefaultFileApp.archiveManagerHandlerId;
    try {
      await ref
          .read(defaultFileAppsProvider.notifier)
          .save(
            DefaultFileApp(
              extension: defaultApp.extension,
              handlerId: isTextEditor
                  ? DefaultFileApp.textEditorHandlerId
                  : isImageViewer
                  ? DefaultFileApp.imageViewerHandlerId
                  : isVideoPlayer
                  ? DefaultFileApp.videoPlayerHandlerId
                  : isArchiveManager
                  ? DefaultFileApp.archiveManagerHandlerId
                  : 'external',
              category: 'Others',
              mimeType: selected.mimeType,
              packageName:
                  isTextEditor ||
                      isImageViewer ||
                      isVideoPlayer ||
                      isArchiveManager
                  ? null
                  : selected.packageName,
              displayName:
                  isTextEditor ||
                      isImageViewer ||
                      isVideoPlayer ||
                      isArchiveManager
                  ? null
                  : selected.name,
              activityName:
                  isTextEditor ||
                      isImageViewer ||
                      isVideoPlayer ||
                      isArchiveManager
                  ? null
                  : selected.activityName,
              extensionSpecific: true,
              extensions: extensions,
            ),
          );
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not update default app: $error')),
      );
    }
  }
}

class _DefaultAppSelection {
  const _DefaultAppSelection({this.app, this.delete = false});

  final OpenWithApp? app;
  final bool delete;
}

Widget _openWithLeadingIcon(OpenWithApp app) {
  if (app.iconBytes != null) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.memory(
        app.iconBytes!,
        width: 32,
        height: 32,
        fit: BoxFit.contain,
        errorBuilder: (context, error, stackTrace) => const Icon(Icons.apps),
      ),
    );
  }
  if (app.packageName == DefaultFileApp.textEditorHandlerId) {
    return const Icon(Icons.text_snippet_outlined);
  }
  if (app.packageName == DefaultFileApp.imageViewerHandlerId) {
    return const Icon(Icons.image_outlined);
  }
  if (app.packageName == DefaultFileApp.videoPlayerHandlerId) {
    return const Icon(Icons.play_circle_outline);
  }
  if (app.packageName == DefaultFileApp.archiveManagerHandlerId) {
    return Image.asset(
      Branding.logoPng,
      width: 32,
      height: 32,
      fit: BoxFit.contain,
    );
  }
  return const Icon(Icons.apps);
}

class _SettingsScrollableList extends StatefulWidget {
  const _SettingsScrollableList({
    required this.height,
    required this.itemCount,
    required this.itemBuilder,
  });

  final double height;
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;

  @override
  State<_SettingsScrollableList> createState() =>
      _SettingsScrollableListState();
}

class _SettingsScrollableListState extends State<_SettingsScrollableList> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    height: widget.height,
    child: Scrollbar(
      controller: _controller,
      thumbVisibility: true,
      interactive: true,
      child: ListView.builder(
        controller: _controller,
        primary: false,
        itemCount: widget.itemCount,
        itemBuilder: widget.itemBuilder,
      ),
    ),
  );
}

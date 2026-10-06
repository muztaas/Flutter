import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/providers/default_file_apps_provider.dart';
import '../../core/providers/open_with_providers.dart';
import '../../core/providers/settings_provider.dart';
import '../../domain/entities/default_file_app.dart';
import '../../domain/entities/open_with_app.dart';
import '../about/about_page.dart';

const _appThemeChannel = MethodChannel('modi_file_explorer2/app_theme');

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
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
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
    final settings = ref.watch(appSettingsProvider);
    // drive animation
    if (open) {
      _anim.forward();
    } else {
      _anim.reverse();
    }

    final width = MediaQuery.of(context).size.width * 0.8;
    final topInset = MediaQuery.of(context).padding.top;

    return IgnorePointer(
      ignoring: !open,
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
                                child: SingleChildScrollView(
                                  child: Padding(
                                    padding: const EdgeInsets.all(16.0),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        const Text(
                                          'Settings',
                                          style: TextStyle(fontSize: 24),
                                        ),
                                        const SizedBox(height: 16),
                                        ExpansionTile(
                                          title: const Text('Appearance'),
                                          children: [
                                            ListTile(
                                              title: const Text('Dark Theme'),
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
                                                            .invokeMethod<void>(
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
                                              title: const Text('Default view'),
                                              trailing: DropdownButton<String>(
                                                value: settings.defaultViewMode,
                                                items: const [
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
                                              title: const Text('Font size'),
                                              trailing: DropdownButton<String>(
                                                value: settings.fontSize,
                                                items: const [
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
                                              title: 'Show modified date',
                                              value: settings.showModifiedDate,
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
                                              value: settings.showModifiedTime,
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
                                              value:
                                                  settings.showFolderItemCount,
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
                                                        .setShowFileSize(value),
                                                  ),
                                            ),
                                          ],
                                        ),
                                        ExpansionTile(
                                          title: const Text('Files'),
                                          children: [
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
                                              value: settings.showNomediaFiles,
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
                                            const _DefaultAppsSection(),
                                          ],
                                        ),
                                        ExpansionTile(
                                          title: const Text('Storage'),
                                          children: [
                                            ListTile(
                                              title: const Text(
                                                'Default startup drive',
                                              ),
                                              subtitle: const Text(
                                                'Internal Storage',
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

class _DefaultAppsSection extends ConsumerWidget {
  const _DefaultAppsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final defaults = ref.watch(defaultFileAppsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          title: const Text('Default apps'),
          subtitle: const Text('Apps used automatically for file extensions'),
        ),
        defaults.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (error, _) => Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text('Could not load default apps: $error'),
          ),
          data: (items) => items.isEmpty
              ? Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: Center(
                    child: Text(
                      'No default apps',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                )
              : SizedBox(
                  height: items.length > 4 ? 4 * 72 : items.length * 72,
                  child: ListView.builder(
                    primary: false,
                    itemCount: items.length,
                    itemBuilder: (context, index) =>
                        _DefaultFileAppTile(defaultApp: items[index]),
                  ),
                ),
        ),
      ],
    );
  }
}

class _DefaultFileAppTile extends ConsumerWidget {
  const _DefaultFileAppTile({required this.defaultApp});

  final DefaultFileApp defaultApp;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appName = defaultApp.isTextEditor
        ? Future<String?>.value('Text Editor (built-in)')
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
          title: Text(defaultApp.extension),
          subtitle: Text('Opens with $label'),
          onTap: () => _editDefaultApp(context, ref),
        );
      },
    );
  }

  Future<void> _editDefaultApp(BuildContext context, WidgetRef ref) async {
    final List<OpenWithApp> apps;
    try {
      apps = await ref
          .read(openWithRepositoryProvider)
          .listAppsForType(
            extension: defaultApp.extension,
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
      ...apps,
    ];
    if (!context.mounted) return;

    final selection = await showDialog<_DefaultAppSelection>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Default app for ${defaultApp.extension}'),
        content: SizedBox(
          width: double.maxFinite,
          height: (choices.length.clamp(1, 4) * 64).toDouble(),
          child: choices.isEmpty
              ? const Center(child: Text('No compatible apps found'))
              : ListView.builder(
                  itemCount: choices.length,
                  itemBuilder: (context, index) => ListTile(
                    title: Text(choices[index].name),
                    onTap: () => Navigator.pop(
                      dialogContext,
                      _DefaultAppSelection(app: choices[index]),
                    ),
                  ),
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(
              dialogContext,
              const _DefaultAppSelection(delete: true),
            ),
            child: const Text('Delete default'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
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
        await ref
            .read(defaultFileAppsProvider.notifier)
            .save(
              DefaultFileApp(
                extension: defaultApp.extension,
                handlerId: isTextEditor
                    ? DefaultFileApp.textEditorHandlerId
                    : 'external',
                category: defaultApp.category,
                mimeType: app.mimeType,
                packageName: isTextEditor ? null : app.packageName,
                displayName: isTextEditor ? null : app.name,
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
}

class _DefaultAppSelection {
  const _DefaultAppSelection({this.app, this.delete = false});

  final OpenWithApp? app;
  final bool delete;
}

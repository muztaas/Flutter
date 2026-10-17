import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../core/providers/default_file_apps_provider.dart';
import '../../core/providers/file_type_categories_provider.dart';
import '../../core/providers/open_with_providers.dart';
import '../../core/providers/settings_provider.dart';
import '../../core/providers/quick_access_provider.dart';
import '../../core/providers/storage_providers.dart';
import '../../core/tabs/tabs_manager.dart';
import '../../core/utils/format_bytes.dart';
import '../../core/utils/time_format.dart';
import '../../domain/entities/default_file_app.dart';
import '../../domain/entities/file_type_category.dart';
import '../../domain/entities/open_with_app.dart';
import '../../domain/entities/quick_access_item.dart';
import '../../domain/entities/search_scope.dart';
import '../../domain/entities/storage_device.dart';
import '../common/marquee_text.dart';
import '../common/open_with_label.dart';
import '../common/search_action_button.dart';

class _RecentFile {
  const _RecentFile({
    required this.path,
    required this.name,
    required this.driveId,
    required this.modified,
  });

  final String path;
  final String name;
  final String driveId;
  final DateTime modified;
}

class _DriveScanData {
  const _DriveScanData({
    required this.weeklyRecent,
    required this.overallRecent,
    required this.categoryBytes,
  });

  final List<_RecentFile> weeklyRecent;
  final List<_RecentFile> overallRecent;
  final Map<String, int?> categoryBytes;
}

Future<Directory?> _findDownloadsDirectory(String rootPath) async {
  try {
    final matches = await Directory(rootPath)
        .list(followLinks: false)
        .where((entry) => entry is Directory)
        .where((entry) {
          final name = entry.uri.pathSegments
              .where((segment) => segment.isNotEmpty)
              .lastOrNull;
          return name?.toLowerCase() == 'download' ||
              name?.toLowerCase() == 'downloads';
        })
        .toList();
    if (matches.isEmpty) return null;
    matches.sort((left, right) {
      final leftName = left.uri.pathSegments
          .where((segment) => segment.isNotEmpty)
          .lastOrNull
          ?.toLowerCase();
      final rightName = right.uri.pathSegments
          .where((segment) => segment.isNotEmpty)
          .lastOrNull
          ?.toLowerCase();
      if (leftName == 'download' && rightName != 'download') return -1;
      if (rightName == 'download' && leftName != 'download') return 1;
      return 0;
    });
    return matches.first as Directory;
  } on FileSystemException catch (error) {
    debugPrint('Could not locate the Downloads folder: $error');
    return null;
  }
}

Future<int?> _calculateDirectoryBytes(Directory root) async {
  var total = 0;
  final pending = <Directory>[root];
  final visited = <String>{};
  try {
    while (pending.isNotEmpty) {
      final directory = pending.removeLast();
      final canonicalPath = await directory.resolveSymbolicLinks();
      if (!visited.add(canonicalPath)) continue;
      final entries = await directory.list(followLinks: false).toList();
      for (final entry in entries) {
        if (entry is Directory) {
          pending.add(entry);
        } else if (entry is File) {
          total += await entry.length();
        }
      }
    }
    return total;
  } on FileSystemException catch (error) {
    debugPrint('Could not calculate Downloads folder size: $error');
    return null;
  }
}

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage>
    with AutomaticKeepAliveClientMixin<HomePage> {
  final _storageKey = GlobalKey<_AvailableStorageSectionState>();
  final _quickAccessKey = GlobalKey<_QuickAccessSectionState>();
  final TabsManager _tabs = TabsManager.instance;
  final Map<String, _DriveScanData> _driveScans = {};
  Map<String, String?> _categorySizes = const {};
  List<_RecentFile> _recentFiles = const [];
  bool _scanLoading = true;
  bool _storagePermissionAvailable = true;
  String? _scanError;
  bool _scanInProgress = false;
  bool _scanRequestedAgain = false;
  bool _forceRescanRequested = false;
  bool _isHomeVisible = true;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _isHomeVisible = _tabs.selectedIndex == 0;
    _tabs.addListener(_onTabsChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scanHomeStorage();
    });
  }

  @override
  void dispose() {
    _tabs.removeListener(_onTabsChanged);
    super.dispose();
  }

  void _onTabsChanged() {
    final isHomeVisible = _tabs.selectedIndex == 0;
    if (_isHomeVisible == isHomeVisible || !mounted) return;
    setState(() => _isHomeVisible = isHomeVisible);
  }

  void _refresh() {
    _scanHomeStorage(forceRefresh: true);
    _storageKey.currentState?.refresh();
  }

  Future<void> _scanHomeStorage({bool forceRefresh = false}) async {
    if (_scanInProgress) {
      _scanRequestedAgain = true;
      _forceRescanRequested = _forceRescanRequested || forceRefresh;
      return;
    }
    _scanInProgress = true;
    final settings = ref.read(appSettingsProvider);
    try {
      await ref.read(fileTypeCategoriesProvider.notifier).ready;
      if (Platform.isAndroid) {
        final storagePermission = await Permission.storage.status;
        final managePermission = await Permission.manageExternalStorage.status;
        _storagePermissionAvailable =
            storagePermission.isGranted ||
            storagePermission.isLimited ||
            managePermission.isGranted;
        if (!_storagePermissionAvailable) {
          if (mounted) {
            setState(() {
              _scanLoading = false;
              _scanError = null;
              _recentFiles = const [];
            });
          }
          return;
        }
      }

      final devices = await getStorageRepository().listStorageDevices();
      final internal = devices.where((device) => device.id == 'internal');
      if (internal.isEmpty) {
        if (mounted) {
          setState(() {
            _scanLoading = false;
            _scanPermissionError();
          });
        }
        return;
      }
      final includedDevices = devices
          .where(
            (device) =>
                device.id == 'internal' ||
                settings.includeOtherStorageDrivesInRecent,
          )
          .toList();
      final needsScan = includedDevices.any(
        (device) => forceRefresh || !_driveScans.containsKey(device.id),
      );
      if (mounted && needsScan) {
        setState(() {
          _scanLoading = true;
          _scanError = null;
        });
      }
      final categories = ref.read(fileTypeCategoriesProvider);
      final showHiddenFiles = settings.showHiddenFiles;
      final showNomediaFiles = settings.showNomediaFiles;
      for (final device in includedDevices) {
        if (!forceRefresh && _driveScans.containsKey(device.id)) continue;
        _driveScans[device.id] = await _scanStorageDrive(
          device,
          categories,
          showHiddenFiles: showHiddenFiles,
          showNomediaFiles: showNomediaFiles,
        );
      }
      if (!mounted) return;
      final internalScan = _driveScans['internal'];
      setState(() {
        _categorySizes = {
          for (final category in const [
            'Downloads',
            'Documents',
            'Images',
            'Videos',
            'Audio',
          ])
            category: internalScan == null
                ? null
                : internalScan.categoryBytes[category] == null
                ? null
                : formatBytes(internalScan.categoryBytes[category]!),
        };
        _recentFiles = _mergeRecentFiles(
          includedDevices.map((device) => _driveScans[device.id]),
        );
        _scanLoading = false;
        _scanError = null;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _scanLoading = false;
          _scanError = 'Could not scan storage: $error';
        });
      }
    } finally {
      _scanInProgress = false;
      if (mounted && _scanRequestedAgain) {
        final forceRescan = _forceRescanRequested;
        _scanRequestedAgain = false;
        _forceRescanRequested = false;
        unawaited(_scanHomeStorage(forceRefresh: forceRescan));
      } else if (mounted &&
          ref.read(appSettingsProvider).includeOtherStorageDrivesInRecent !=
              settings.includeOtherStorageDrivesInRecent) {
        unawaited(_scanHomeStorage());
      }
    }
  }

  void _scanPermissionError() {
    _categorySizes = const {};
    _recentFiles = const [];
    _scanError = 'No internal storage is available';
  }

  Future<_DriveScanData> _scanStorageDrive(
    StorageDevice device,
    List<FileTypeCategory> categories, {
    required bool showHiddenFiles,
    required bool showNomediaFiles,
  }) async {
    final documentExtensions =
        categories
            .where((category) => category.name == 'Documents')
            .firstOrNull
            ?.extensions
            .toSet() ??
        FileTypeCategory.documentsExtensions.toSet();
    final imageExtensions =
        categories
            .where((category) => category.name == 'Image')
            .firstOrNull
            ?.extensions
            .toSet() ??
        const <String>{};
    final root = Directory(device.path);
    final rootNoMedia =
        !showNomediaFiles && await File('${root.path}/.nomedia').exists();
    final downloadsDirectory = await _findDownloadsDirectory(device.path);
    final downloadsBytes = downloadsDirectory == null
        ? null
        : await _calculateDirectoryBytes(downloadsDirectory);
    final categoryBytes = <String, int?>{
      'Downloads': downloadsBytes,
      'Documents': 0,
      'Images': 0,
      'Videos': 0,
      'Audio': 0,
    };
    final weeklyRecent = <_RecentFile>[];
    final overallRecent = <_RecentFile>[];
    final cutoff = DateTime.now().subtract(const Duration(days: 7));
    final pending = <({Directory directory, String relative, bool noMedia})>[
      (directory: root, relative: '', noMedia: rootNoMedia),
    ];
    while (pending.isNotEmpty) {
      final current = pending.removeLast();
      List<FileSystemEntity> entries;
      try {
        entries = await current.directory.list(followLinks: false).toList();
      } on FileSystemException {
        continue;
      }
      for (final entry in entries) {
        final name = entry.uri.pathSegments.isEmpty
            ? entry.path
            : entry.uri.pathSegments.last;
        if (!showHiddenFiles && name.startsWith('.')) continue;
        final relative = current.relative.isEmpty
            ? name
            : '${current.relative}/$name';
        if (entry is Directory) {
          final hasNoMedia =
              !showNomediaFiles &&
              await File(
                '${entry.path}${Platform.pathSeparator}.nomedia',
              ).exists();
          pending.add((
            directory: entry,
            relative: relative,
            noMedia: current.noMedia || hasNoMedia,
          ));
          continue;
        }
        if (entry is! File) continue;
        FileStat stat;
        try {
          stat = await entry.stat();
        } on FileSystemException {
          continue;
        }
        final extension = _extensionOf(name);
        final pathComponents = relative
            .split('/')
            .map((component) => component.toLowerCase())
            .toList();
        final isRecentExcluded = _containsAndroidAppData(pathComponents);
        final normalizedRelative = relative.toLowerCase();
        if (documentExtensions.contains(extension)) {
          categoryBytes['Documents'] = categoryBytes['Documents']! + stat.size;
        }
        if (imageExtensions.contains(extension)) {
          categoryBytes['Images'] = categoryBytes['Images']! + stat.size;
        }
        if (normalizedRelative.startsWith('movies/')) {
          categoryBytes['Videos'] = categoryBytes['Videos']! + stat.size;
        }
        if (normalizedRelative.startsWith('music/')) {
          categoryBytes['Audio'] = categoryBytes['Audio']! + stat.size;
        }
        if (isRecentExcluded || current.noMedia) continue;
        final candidate = _RecentFile(
          path: entry.path,
          name: name,
          driveId: device.id,
          modified: stat.modified,
        );
        _insertRecent(overallRecent, candidate, 10);
        if (!stat.modified.isBefore(cutoff)) {
          _insertRecent(weeklyRecent, candidate, 100);
        }
      }
    }
    return _DriveScanData(
      weeklyRecent: weeklyRecent,
      overallRecent: overallRecent,
      categoryBytes: categoryBytes,
    );
  }

  String _extensionOf(String name) {
    final dot = name.lastIndexOf('.');
    return dot <= 0
        ? ''
        : FileTypeCategory.normalizeExtension(name.substring(dot));
  }

  bool _containsAndroidAppData(List<String> pathComponents) {
    for (var index = 0; index + 1 < pathComponents.length; index++) {
      if (pathComponents[index] == 'android' &&
          (pathComponents[index + 1] == 'data' ||
              pathComponents[index + 1] == 'obb')) {
        return true;
      }
    }
    return false;
  }

  void _insertRecent(
    List<_RecentFile> files,
    _RecentFile candidate,
    int limit,
  ) {
    var low = 0;
    var high = files.length;
    while (low < high) {
      final middle = (low + high) ~/ 2;
      if (files[middle].modified.isBefore(candidate.modified)) {
        high = middle;
      } else {
        low = middle + 1;
      }
    }
    files.insert(low, candidate);
    if (files.length > limit) files.removeLast();
  }

  List<_RecentFile> _mergeRecentFiles(Iterable<_DriveScanData?> scans) {
    final available = scans.whereType<_DriveScanData>().toList();
    final weekly = available.expand((scan) => scan.weeklyRecent).toList()
      ..sort((a, b) => b.modified.compareTo(a.modified));
    if (weekly.isNotEmpty) return weekly.take(100).toList();
    final overall = available.expand((scan) => scan.overallRecent).toList()
      ..sort((a, b) => b.modified.compareTo(a.modified));
    return overall.take(10).toList();
  }

  void _removeRecentFile(_RecentFile file) {
    setState(() {
      _recentFiles = _recentFiles
          .where((candidate) => candidate.path != file.path)
          .toList();
      final driveScan = _driveScans[file.driveId];
      if (driveScan != null) {
        _driveScans[file.driveId] = _DriveScanData(
          weeklyRecent: driveScan.weeklyRecent
              .where((candidate) => candidate.path != file.path)
              .toList(),
          overallRecent: driveScan.overallRecent
              .where((candidate) => candidate.path != file.path)
              .toList(),
          categoryBytes: driveScan.categoryBytes,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    ref.listen<AppSettings>(appSettingsProvider, (previous, next) {
      if (previous?.includeOtherStorageDrivesInRecent !=
          next.includeOtherStorageDrivesInRecent) {
        unawaited(_scanHomeStorage());
      }
    });
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= 900) {
          // desktop layout stub
          return Center(
            child: Text(
              'Desktop Home (stub)',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
          );
        }

        // mobile layout
        return Scaffold(
          appBar: AppBar(
            leading: Consumer(
              builder: (context, ref, _) {
                return IconButton(
                  icon: const Icon(Icons.menu),
                  onPressed: () =>
                      ref.read(settingsPanelProvider.notifier).toggle(),
                );
              },
            ),
            title: const Text('Home', style: TextStyle(fontSize: 19)),
            actions: [
              IconButton(onPressed: _refresh, icon: const Icon(Icons.refresh)),
              SearchActionButton(
                sessionId: 'home',
                scope: const SearchScope.allStorage(),
                onResultSelected: (result) async {
                  if (!context.mounted) return;
                  if (result.isDirectory) {
                    TabsManager.instance.openStorageTab(result.path);
                    return;
                  }
                  await _quickAccessKey.currentState?.openSearchFile(
                    path: result.path,
                    name: result.name,
                  );
                },
              ),
            ],
          ),
          body: Column(
            children: [
              SizedBox(
                height: 145,
                child: _CategoryCards(
                  categorySizes: _categorySizes,
                  scanLoading: _scanLoading,
                ),
              ),
              Container(
                width: double.infinity,
                height: 2,
                color: const Color(0xFF29B6F6),
              ),
              Expanded(
                child: _QuickAccessSection(
                  key: _quickAccessKey,
                  isHomeVisible: _isHomeVisible,
                  recentFiles: _recentFiles,
                  recentLoading: _scanLoading,
                  storagePermissionAvailable: _storagePermissionAvailable,
                  recentError: _scanError,
                  onRecentFileMissing: _removeRecentFile,
                ),
              ),
              Container(
                width: double.infinity,
                height: 2,
                color: const Color(0xFF29B6F6),
              ),
              SizedBox(
                height: 215,
                child: _AvailableStorageSection(
                  key: _storageKey,
                  isActive: _isHomeVisible,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _CategoryCards extends ConsumerStatefulWidget {
  const _CategoryCards({
    required this.categorySizes,
    required this.scanLoading,
  });

  final Map<String, String?> categorySizes;
  final bool scanLoading;

  @override
  ConsumerState<_CategoryCards> createState() => _CategoryCardsState();
}

class _CategoryCardsState extends ConsumerState<_CategoryCards> {
  final List<Map<String, dynamic>> categories = const [
    {'name': 'Downloads', 'icon': Icons.download},
    {'name': 'Documents', 'icon': Icons.description},
    {'name': 'Images', 'icon': Icons.image},
    {'name': 'Videos', 'icon': Icons.movie},
    {'name': 'Audio', 'icon': Icons.audiotrack},
    {'name': 'Apps', 'icon': Icons.apps},
  ];

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 145,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(),
          primary: false,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemBuilder: (context, index) {
            final c = categories[index];
            return SizedBox(
              width: MediaQuery.of(context).size.width * 0.4,
              height: 137,
              child: InkWell(
                onTap: () async {
                  if (c['name'] == 'Apps') {
                    TabsManager.instance.openAppsTab();
                    return;
                  }

                  // Resolve a sensible base path (prefer internal storage, then external, then app docs)
                  final repo = getStorageRepository();
                  final devices = await repo.listStorageDevices();
                  if (!context.mounted) return;
                  final base = devices.isEmpty
                      ? null
                      : devices
                            .firstWhere(
                              (d) => d.id == 'internal',
                              orElse: () => devices.firstWhere(
                                (d) => d.id == 'external',
                                orElse: () => devices.first,
                              ),
                            )
                            .path;

                  if (base == null) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('No storage available')),
                      );
                    }
                    return;
                  }

                  final name = (c['name'] as String).toLowerCase();
                  String folder;
                  if (name.contains('download')) {
                    folder = 'Download';
                  } else if (name.contains('document')) {
                    folder = '';
                  } else if (name.contains('image')) {
                    folder = '';
                  } else if (name.contains('video')) {
                    folder = 'Movies';
                  } else if (name.contains('audio')) {
                    folder = 'Music';
                  } else {
                    folder = '';
                  }

                  final downloadsDirectory = name.contains('download')
                      ? await _findDownloadsDirectory(base)
                      : null;
                  if (!context.mounted) return;
                  if (name.contains('download') && downloadsDirectory == null) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Downloads folder is unavailable'),
                      ),
                    );
                    return;
                  }
                  final target =
                      downloadsDirectory?.path ??
                      (folder.isEmpty ? base : '$base/$folder');
                  TabsManager.instance.openStorageTab(
                    target,
                    title: name.contains('image')
                        ? 'Images'
                        : name.contains('document')
                        ? 'Documents'
                        : null,
                    imageOnly: name.contains('image'),
                    documentOnly: name.contains('document'),
                  );
                },
                child: Card(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(c['icon'] as IconData, size: 36),
                        const SizedBox(height: 12),
                        Text(
                          c['name'] as String,
                          style: Theme.of(context).textTheme.titleMedium,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 8),
                        _CategorySize(
                          category: c['name'] as String,
                          size: widget.categorySizes[c['name'] as String],
                          loading: widget.scanLoading,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
          separatorBuilder: (_, _) => const SizedBox(width: 12),
          itemCount: categories.length,
        ),
      ),
    );
  }
}

class _CategorySize extends StatelessWidget {
  final String category;
  final String? size;
  final bool loading;

  const _CategorySize({
    required this.category,
    required this.size,
    required this.loading,
  });

  @override
  Widget build(BuildContext context) {
    if (category == 'Apps') {
      return const SizedBox.shrink();
    }

    return Text(
      loading ? 'Calculating…' : size ?? 'Unavailable',
      style: Theme.of(context).textTheme.bodySmall,
    );
  }
}

class _QuickAccessSection extends ConsumerStatefulWidget {
  const _QuickAccessSection({
    super.key,
    required this.isHomeVisible,
    required this.recentFiles,
    required this.recentLoading,
    required this.storagePermissionAvailable,
    required this.recentError,
    required this.onRecentFileMissing,
  });

  final bool isHomeVisible;
  final List<_RecentFile> recentFiles;
  final bool recentLoading;
  final bool storagePermissionAvailable;
  final String? recentError;
  final ValueChanged<_RecentFile> onRecentFileMissing;

  @override
  ConsumerState<_QuickAccessSection> createState() =>
      _QuickAccessSectionState();
}

class _QuickAccessSectionState extends ConsumerState<_QuickAccessSection> {
  List<String> _orderedPaths = [];
  bool _showRecent = false;

  @override
  Widget build(BuildContext context) {
    final ref = this.ref;
    final quickAccess = ref.watch(quickAccessProvider);
    final use24HourTime = ref.watch(appSettingsProvider).use24HourTime;
    return Padding(
      padding: const EdgeInsets.only(left: 16, right: 16, top: 4),
      child: Column(
        children: [
          Row(
            children: [
              _buildSectionTab(context, 'Quick Access', selected: !_showRecent),
              _buildSectionTab(context, 'Recent', selected: _showRecent),
            ],
          ),
          Container(height: 2, color: const Color(0xFF29B6F6)),
          Expanded(
            child: _showRecent
                ? _buildRecentList(context, ref, use24HourTime)
                : quickAccess.when(
                    loading: () =>
                        const Center(child: CircularProgressIndicator()),
                    error: (error, _) => Center(
                      child: Text('Could not load Quick Access: $error'),
                    ),
                    data: (items) => items.isEmpty
                        ? Center(
                            child: Text(
                              'No favourites',
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                          )
                        : _buildReorderableList(context, ref, items),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionTab(
    BuildContext context,
    String title, {
    required bool selected,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return Expanded(
      child: Semantics(
        button: true,
        selected: selected,
        label: title,
        child: InkWell(
          onTap: () => setState(() => _showRecent = title == 'Recent'),
          child: SizedBox(
            height: 36,
            child: Center(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                padding: const EdgeInsets.symmetric(horizontal: 6),
                decoration: BoxDecoration(
                  color: selected
                      ? colorScheme.secondaryContainer
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Center(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      title,
                      maxLines: 1,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        color: selected
                            ? null
                            : colorScheme.onSurface.withValues(alpha: 0.6),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildReorderableList(
    BuildContext context,
    WidgetRef ref,
    List<QuickAccessItem> items,
  ) {
    final paths = items.map((item) => item.path).toSet();
    final orderedPaths = [
      ..._orderedPaths.where(paths.contains),
      ...items
          .map((item) => item.path)
          .where((path) => !_orderedPaths.contains(path)),
    ];
    final orderedItems = orderedPaths
        .map((path) => items.firstWhere((item) => item.path == path))
        .toList();

    return ReorderableListView.builder(
      padding: EdgeInsets.zero,
      primary: false,
      shrinkWrap: false,
      physics: const ClampingScrollPhysics(),
      buildDefaultDragHandles: false,
      itemCount: orderedItems.length,
      onReorder: (oldIndex, newIndex) {
        if (newIndex > oldIndex) newIndex--;
        final reordered = List<QuickAccessItem>.of(orderedItems);
        final movedItem = reordered.removeAt(oldIndex);
        reordered.insert(newIndex, movedItem);
        setState(() {
          _orderedPaths = reordered.map((item) => item.path).toList();
        });
      },
      itemBuilder: (context, index) {
        final item = orderedItems[index];
        return ReorderableDelayedDragStartListener(
          key: ValueKey(item.path),
          index: index,
          child: ListTile(
            dense: true,
            contentPadding: const EdgeInsets.only(left: 16, right: 0),
            leading: Icon(
              item.isDirectory ? Icons.folder : Icons.insert_drive_file,
            ),
            title: MarqueeText(
              item.name,
              style: Theme.of(context).textTheme.titleSmall,
              styleMode: MarqueeStyle.pauseAndLoop,
              isActive: widget.isHomeVisible && !_showRecent,
            ),
            subtitle: MarqueeText(
              item.path,
              style: Theme.of(context).textTheme.labelSmall,
              styleMode: MarqueeStyle.pauseAndLoop,
              isActive: widget.isHomeVisible && !_showRecent,
            ),
            onTap: () => _openQuickAccess(context, ref, item),
            trailing: IconButton(
              tooltip: 'Remove from Quick Access',
              icon: const Icon(Icons.star, color: Colors.amber),
              onPressed: () => _confirmRemoveQuickAccess(context, ref, item),
            ),
          ),
        );
      },
    );
  }

  Widget _buildRecentList(
    BuildContext context,
    WidgetRef ref,
    bool use24HourTime,
  ) {
    if (!widget.storagePermissionAvailable) {
      return const Center(child: Text('Storage permission required'));
    }
    if (widget.recentLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (widget.recentError != null) {
      return Center(child: Text(widget.recentError!));
    }
    if (widget.recentFiles.isEmpty) {
      return const Center(child: Text('No recent files'));
    }
    return ListView.builder(
      primary: false,
      physics: const ClampingScrollPhysics(),
      itemCount: widget.recentFiles.length,
      itemBuilder: (context, index) {
        final file = widget.recentFiles[index];
        final date = file.modified;
        const months = [
          'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
          'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
        ];
        final dateText = '${date.day} ${months[date.month - 1]} ${date.year}';
        final timeText = formatClockTime(
          date,
          use24HourTime: use24HourTime,
        );
        final detailStyle = Theme.of(context).textTheme.labelSmall;
        final datePainter = TextPainter(
          text: TextSpan(text: dateText, style: detailStyle),
          textDirection: Directionality.of(context),
          maxLines: 1,
        )..layout();
        return ListTile(
          dense: true,
          contentPadding: const EdgeInsets.only(left: 16, right: 0),
          leading: const Icon(Icons.insert_drive_file),
          title: MarqueeText(
            file.name,
            style: Theme.of(context).textTheme.titleSmall,
            styleMode: MarqueeStyle.pauseAndLoop,
            isActive: widget.isHomeVisible && _showRecent,
          ),
          subtitle: MarqueeText(
            file.path,
            style: Theme.of(context).textTheme.labelSmall,
            styleMode: MarqueeStyle.pauseAndLoop,
            isActive: widget.isHomeVisible && _showRecent,
          ),
          trailing: SizedBox(
            width: datePainter.width.ceilToDouble(),
            height: 48,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                MarqueeText(
                  dateText,
                  style: detailStyle,
                  textAlign: TextAlign.center,
                  styleMode: MarqueeStyle.pauseAndLoop,
                  isActive: widget.isHomeVisible && _showRecent,
                ),
                MarqueeText(
                  timeText,
                  style: detailStyle,
                  textAlign: TextAlign.center,
                  styleMode: MarqueeStyle.pauseAndLoop,
                  isActive: widget.isHomeVisible && _showRecent,
                ),
              ],
            ),
          ),
          onTap: () => _openRecentFile(context, ref, file),
        );
      },
    );
  }

  Future<void> _openRecentFile(
    BuildContext context,
    WidgetRef ref,
    _RecentFile file,
  ) async {
    final exists = await File(file.path).exists();
    if (!context.mounted) return;
    if (!exists) {
      widget.onRecentFileMissing(file);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This file is no longer available')),
      );
      return;
    }
    await _openQuickAccess(
      context,
      ref,
      QuickAccessItem(path: file.path, name: file.name, isDirectory: false),
    );
  }

  Future<void> _confirmRemoveQuickAccess(
    BuildContext context,
    WidgetRef ref,
    QuickAccessItem item,
  ) async {
    final shouldRemove = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Remove from Quick Access?'),
        content: Text('Are you sure you want to remove "${item.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('No'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Yes'),
          ),
        ],
      ),
    );

    if (shouldRemove == true && context.mounted) {
      await _removeQuickAccess(context, ref, item);
    }
  }

  Future<void> _removeQuickAccess(
    BuildContext context,
    WidgetRef ref,
    QuickAccessItem item,
  ) async {
    try {
      await ref.read(quickAccessProvider.notifier).delete(item.path);
      if (mounted) {
        setState(() => _orderedPaths.remove(item.path));
      }
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not remove favourite: $error')),
        );
      }
    }
  }

  Future<void> openSearchFile({required String path, required String name}) =>
      _openQuickAccess(
        context,
        ref,
        QuickAccessItem(path: path, name: name, isDirectory: false),
        fromSearch: true,
      );

  Future<void> _openQuickAccess(
    BuildContext context,
    WidgetRef ref,
    QuickAccessItem item, {
    bool fromSearch = false,
  }) async {
    if (item.isDirectory) {
      TabsManager.instance.openStorageTab(item.path);
      return;
    }

    final file = File(item.path);
    final extension = item.name.contains('.')
        ? '.${item.name.split('.').last.toLowerCase()}'
        : '';
    try {
      await ref.read(fileTypeCategoriesProvider.notifier).ready;
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not load file type categories: $error'),
          ),
        );
      }
      return;
    }
    var category = _categoryForExtension(
      extension,
      ref.read(fileTypeCategoriesProvider),
    );
    if (extension.isNotEmpty &&
        (fromSearch
            ? ref.read(appSettingsProvider).useSavedDefaultApps
            : ref
                  .read(appSettingsProvider)
                  .useSavedDefaultAppsForQuickAccess)) {
      final DefaultFileApp? savedDefault;
      try {
        savedDefault = await ref
            .read(defaultFileAppsProvider.notifier)
            .find(extension, category: category);
      } catch (error) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Could not load saved default apps: $error'),
            ),
          );
        }
        return;
      }

      if (savedDefault != null) {
        final selectedActivityName = savedDefault.activityName;
        if (savedDefault.category != 'Others') {
          category = savedDefault.category;
        }
        if (savedDefault.isTextEditor) {
          TabsManager.instance.openTextEditor(item.path);
          return;
        }
        if (savedDefault.isImageViewer) {
          TabsManager.instance.openImageViewer(item.path);
          return;
        }

        final packageName = savedDefault.packageName;
        final repository = ref.read(openWithRepositoryProvider);
        if (packageName != null && packageName.isNotEmpty) {
          try {
            final availableApps = await repository.listApps(
              path: item.path,
              category: category,
            );
            final availableApp = availableApps
                .where(
                  (app) =>
                      app.packageName == packageName &&
                      (selectedActivityName == null ||
                          app.activityName == selectedActivityName),
                )
                .firstOrNull;
            if (availableApp != null) {
              await repository.openFile(
                path: item.path,
                category: category,
                packageName: packageName,
                activityName: selectedActivityName,
                mimeType: availableApp.mimeType,
              );
              return;
            }
          } on PlatformException catch (error) {
            if (error.code != 'APP_UNAVAILABLE') {
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(error.message ?? 'Could not open file'),
                  ),
                );
              }
              return;
            }
          } catch (error) {
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Could not open file: $error')),
              );
            }
            return;
          }
        }

        try {
          await ref.read(defaultFileAppsProvider.notifier).delete(extension);
        } catch (error) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  'Could not clear the unavailable default app: $error',
                ),
              ),
            );
          }
          return;
        }
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'The app previously used to open $extension files is no longer available',
            ),
          ),
        );
      }
    }

    final List<OpenWithApp> apps;
    try {
      apps = await ref
          .read(openWithRepositoryProvider)
          .listApps(path: item.path, category: category);
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not load apps for this file: $error')),
        );
      }
      return;
    }

    final canUseTextEditor = category == 'Text';
    final canUseImageViewer = category == 'Image';

    if (apps.isEmpty && !canUseTextEditor && !canUseImageViewer) {
      TabsManager.instance.openStorageTab(file.parent.path);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'No compatible app found; opened its containing folder',
            ),
          ),
        );
      }
      return;
    }
    if (!context.mounted) return;

    final Uint8List? builtInIcon;
    try {
      builtInIcon = await ref
          .read(openWithRepositoryProvider)
          .getOwnApplicationIcon();
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not load the built-in app icon: $error'),
          ),
        );
      }
      return;
    }
    if (!context.mounted) return;

    final selection = await showDialog<OpenWithApp?>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: Text(shortenOpenWithHeading('Open ${item.name} with')),
        children: [
          if (canUseImageViewer)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(
                dialogContext,
                OpenWithApp(
                  name: 'Image Viewer (built-in)',
                  packageName: DefaultFileApp.imageViewerHandlerId,
                  mimeType: 'image/*',
                  iconBytes: builtInIcon,
                ),
              ),
              child: Row(
                children: [
                  _openWithAppIcon(
                    OpenWithApp(
                      name: 'Image Viewer (built-in)',
                      packageName: DefaultFileApp.imageViewerHandlerId,
                      mimeType: 'image/*',
                      iconBytes: builtInIcon,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Text('Image Viewer (built-in)'),
                ],
              ),
            ),
          if (canUseTextEditor)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(
                dialogContext,
                OpenWithApp(
                  name: 'Text Editor (built-in)',
                  packageName: DefaultFileApp.textEditorHandlerId,
                  mimeType: 'text/plain',
                  iconBytes: builtInIcon,
                ),
              ),
              child: Row(
                children: [
                  _openWithAppIcon(
                    OpenWithApp(
                      name: 'Text Editor (built-in)',
                      packageName: DefaultFileApp.textEditorHandlerId,
                      mimeType: 'text/plain',
                      iconBytes: builtInIcon,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Text('Text Editor (built-in)'),
                ],
              ),
            ),
          for (final app in apps)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialogContext, app),
              child: Row(
                children: [
                  _openWithAppIcon(app),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      shortenOpenWithAppName(app.name),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
    if (!context.mounted) return;
    if (selection == null) return;
    if (selection.packageName == DefaultFileApp.textEditorHandlerId) {
      TabsManager.instance.openTextEditor(item.path);
      return;
    }

    if (selection.packageName == DefaultFileApp.imageViewerHandlerId) {
      TabsManager.instance.openImageViewer(item.path);
      return;
    }

    try {
      await ref
          .read(openWithRepositoryProvider)
          .openFile(
            path: item.path,
            category: category,
            packageName: selection.packageName,
            activityName: selection.activityName,
            mimeType: selection.mimeType,
          );
    } on PlatformException catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.message ?? 'Could not open file')),
      );
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not open file: $error')));
    }
  }

  String _categoryForExtension(
    String extension,
    List<FileTypeCategory> categories,
  ) {
    return FileTypeCategory.categoryForExtension(
          extension,
          categories: categories,
        ) ??
        'Others';
  }
}

Widget _openWithAppIcon(OpenWithApp app) {
  if (app.iconBytes != null) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Image.memory(
        app.iconBytes!,
        width: 32,
        height: 32,
        fit: BoxFit.contain,
        errorBuilder: (context, error, stackTrace) => const Icon(Icons.apps),
      ),
    );
  }
  return const Icon(Icons.apps);
}

class _AvailableStorageSection extends StatefulWidget {
  final bool isActive;

  const _AvailableStorageSection({super.key, required this.isActive});

  @override
  State<_AvailableStorageSection> createState() =>
      _AvailableStorageSectionState();
}

class _AvailableStorageSectionState extends State<_AvailableStorageSection> {
  late Future<List<StorageDevice>> _devices;

  @override
  void initState() {
    super.initState();
    _devices = getStorageRepository().listStorageDevices();
  }

  void refresh() {
    setState(() {
      _devices = getStorageRepository().listStorageDevices();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Available Storage',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Expanded(
            child: FutureBuilder<List<StorageDevice>>(
              future: _devices,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                final devices = snap.data ?? [];
                if (devices.isEmpty) {
                  return const Center(child: Text('No storage devices found'));
                }
                return GridView.count(
                  crossAxisCount: 2,
                  childAspectRatio: 1.7,
                  crossAxisSpacing: 8,
                  mainAxisSpacing: 8,
                  shrinkWrap: true,
                  children: devices
                      .map(
                        (d) =>
                            _StorageCard(device: d, isActive: widget.isActive),
                      )
                      .toList(),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _StorageCard extends StatelessWidget {
  final StorageDevice device;
  final bool isActive;

  const _StorageCard({required this.device, required this.isActive});

  @override
  Widget build(BuildContext context) {
    final occupied = formatBytes(device.usedBytes);
    final total = formatBytes(device.totalBytes);
    final totalBytes = device.totalBytes;
    final usedBytes = device.usedBytes ?? 0;
    final freePercent = totalBytes != null && totalBytes > 0
        ? (((totalBytes - usedBytes) / totalBytes) * 100).clamp(0, 100)
        : null;
    final usageText = freePercent == null
        ? 'Storage info unavailable'
        : '$occupied / $total used - ${freePercent.toStringAsFixed(1)}% free';

    return InkWell(
      onTap: () {
        TabsManager.instance.openStorageTab(
          device.path,
          title: device.name,
          allowDuplicate: true,
        );
      },
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              const Icon(Icons.sd_storage, size: 32),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    MarqueeText(
                      device.name,
                      style: Theme.of(context).textTheme.titleSmall,
                      styleMode: MarqueeStyle.pauseAndLoop,
                      isActive: isActive,
                    ),
                    const SizedBox(height: 4),
                    MarqueeText(
                      usageText,
                      style: Theme.of(context).textTheme.labelSmall,
                      styleMode: MarqueeStyle.pauseAndLoop,
                      isActive: isActive,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

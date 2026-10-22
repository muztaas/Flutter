import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../core/providers/default_file_apps_provider.dart';
import '../../core/providers/file_type_categories_provider.dart';
import '../../core/providers/installed_apps_providers.dart';
import '../../core/providers/open_with_providers.dart';
import '../../core/providers/settings_provider.dart';
import '../../core/providers/quick_access_provider.dart';
import '../../core/providers/storage_providers.dart';
import '../../core/tabs/tabs_manager.dart';
import '../../core/utils/format_bytes.dart';
import '../../core/utils/font_scaled_spacing.dart';
import '../../core/utils/display_file_name.dart';
import '../../core/utils/file_type_colors.dart';
import '../../core/utils/time_format.dart';
import '../../domain/entities/default_file_app.dart';
import '../../domain/entities/file_type_category.dart';
import '../../domain/entities/open_with_app.dart';
import '../../domain/entities/quick_access_item.dart';
import '../../domain/entities/search_scope.dart';
import '../../domain/entities/storage_device.dart';
import '../../domain/entities/video_file.dart';
import '../../domain/utils/shared_storage_scan_scope.dart';
import '../../domain/utils/storage_display_name.dart';
import '../common/marquee_text.dart';
import '../common/file_type_icon.dart';
import '../common/open_with_label.dart';
import '../common/open_video_file.dart';
import '../common/search_action_button.dart';

const _homeRefreshStaleDelay = Duration(seconds: 5);
const _homeCategoryCardsHeight = 159.5;
const _homeAvailableStorageHeight = 215.0;
const _homeSectionMinimumHeightFactor = 0.2;
const _homeSectionSeparatorGap = 8.0;

class _RecentFile {
  const _RecentFile({
    required this.path,
    required this.name,
    required this.driveId,
    required this.modified,
    required this.relativePath,
    required this.video,
  });

  final String path;
  final String name;
  final String driveId;
  final DateTime modified;
  final String relativePath;
  final VideoFile? video;
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

bool _isAndroidFolderPath(String path) {
  return SharedStorageScanScope.isInsideAndroidFolder(path);
}

String _fileExtensionForDisplay(String name) {
  final dot = name.lastIndexOf('.');
  return dot <= 0 ? '' : name.substring(dot).toLowerCase();
}

bool _sameCategorySizes(
  Map<String, String?> current,
  Map<String, String?> next,
) =>
    current.length == next.length &&
    current.entries.every((entry) => next[entry.key] == entry.value);

bool _sameRecentFiles(List<_RecentFile> current, List<_RecentFile> next) {
  if (current.length != next.length) return false;
  for (var index = 0; index < current.length; index++) {
    final oldFile = current[index];
    final newFile = next[index];
    if (oldFile.path != newFile.path ||
        oldFile.name != newFile.name ||
        oldFile.modified != newFile.modified ||
        oldFile.video?.size != newFile.video?.size ||
        oldFile.video?.modified != newFile.video?.modified) {
      return false;
    }
  }
  return true;
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
    with AutomaticKeepAliveClientMixin<HomePage>, WidgetsBindingObserver {
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
  bool _refreshExceededDelay = false;
  Timer? _refreshDisplayTimer;
  int? _availableDriveCount;
  bool? _lastStoragePermissionAvailable;
  bool? _lastAppUsageAccess;
  String? _appsSizeError;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _isHomeVisible = _tabs.selectedIndex == 0;
    _tabs.addListener(_onTabsChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(ref.read(availableStorageDevicesProvider.notifier).refresh());
      _scanHomeStorage();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tabs.removeListener(_onTabsChanged);
    _refreshDisplayTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && Platform.isAndroid) {
      unawaited(_refreshIfStorageAccessWasGranted());
      unawaited(_refreshAppsTotalIfUsageAccessChanged());
    }
  }

  Future<void> _refreshAppsTotalIfUsageAccessChanged() async {
    final repository = getInstalledAppsRepository();
    repository.clearAppSizeCache();
    try {
      final hasAccess = await repository.hasUsageAccess();
      final previouslyHadAccess = _lastAppUsageAccess;
      _lastAppUsageAccess = hasAccess;
      if (previouslyHadAccess == null || previouslyHadAccess == hasAccess) {
        return;
      }
      final total = await _calculateAppsTotalBytes();
      if (!mounted) return;
      setState(() {
        _categorySizes = {
          ..._categorySizes,
          'Apps': total == null ? null : formatBytes(total),
        };
      });
    } catch (error) {
      _appsSizeError = 'Could not refresh app sizes: $error';
      if (mounted) {
        setState(() {
          _categorySizes = {..._categorySizes, 'Apps': 'Unavailable'};
        });
      }
    }
  }

  Future<void> _refreshIfStorageAccessWasGranted() async {
    unawaited(ref.read(availableStorageDevicesProvider.notifier).refresh());
    final storage = await Permission.storage.status;
    final manageStorage = await Permission.manageExternalStorage.status;
    final hasAccess =
        storage.isGranted || storage.isLimited || manageStorage.isGranted;
    final previouslyHadAccess =
        _lastStoragePermissionAvailable ?? _storagePermissionAvailable;
    _lastStoragePermissionAvailable = hasAccess;
    if (hasAccess && !previouslyHadAccess && mounted) {
      _refresh();
    }
  }

  void _onTabsChanged() {
    final isHomeVisible = _tabs.selectedIndex == 0;
    if (_isHomeVisible == isHomeVisible || !mounted) return;
    setState(() => _isHomeVisible = isHomeVisible);
  }

  void _refresh() {
    unawaited(ref.read(availableStorageDevicesProvider.notifier).refresh());
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
    if (forceRefresh) {
      getInstalledAppsRepository().clearAppSizeCache();
    }
    if (forceRefresh || _driveScans.isEmpty) {
      _startScanDisplayTimer();
    }
    final settings = ref.read(appSettingsProvider);
    _appsSizeError = null;
    final appsSizeFuture = _calculateAppsTotalBytes();
    try {
      await ref.read(fileTypeCategoriesProvider.notifier).ready;
      if (Platform.isAndroid) {
        final storagePermission = await Permission.storage.status;
        final managePermission = await Permission.manageExternalStorage.status;
        _storagePermissionAvailable =
            storagePermission.isGranted ||
            storagePermission.isLimited ||
            managePermission.isGranted;
        _lastStoragePermissionAvailable = _storagePermissionAvailable;
        if (!_storagePermissionAvailable) {
          if (mounted) {
            setState(() {
              _scanLoading = false;
              _scanError = null;
              _recentFiles = const [];
              _refreshExceededDelay = false;
            });
          }
          _cancelScanDisplayTimer();
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
            _refreshExceededDelay = false;
          });
        }
        _cancelScanDisplayTimer();
        return;
      }
      final recentDevices = devices
          .where(
            (device) =>
                device.id == 'internal' ||
                settings.includeOtherStorageDrivesInRecent,
          )
          .toList();
      final categoryDevices = devices
          .where(
            (device) =>
                device.id == 'internal' ||
                settings.includeOtherDrivesInCategoryPages,
          )
          .toList();
      final scanDevices = {
        for (final device in [...recentDevices, ...categoryDevices])
          device.id: device,
      }.values.toList();
      final needsScan = scanDevices.any(
        (device) => forceRefresh || !_driveScans.containsKey(device.id),
      );
      if (mounted && needsScan && !_scanLoading) {
        _startScanDisplayTimer();
      }
      final categories = ref.read(fileTypeCategoriesProvider);
      for (final device in scanDevices) {
        if (!forceRefresh && _driveScans.containsKey(device.id)) continue;
        _driveScans[device.id] = await _scanStorageDrive(
          device,
          categories,
          showHiddenFiles: settings.showHiddenFiles,
          showNomediaFiles: settings.showNomediaFiles,
          showHiddenFilesInRecent: settings.showHiddenFilesInRecent,
          showNomediaFilesInRecent: settings.showNomediaFilesInRecent,
          includeAndroidFolderFiles: settings.showAndroidFolderFilesInRecent,
          hideAndroidFoldersInCategoryPages:
              settings.hideAndroidFoldersInCategoryPages,
        );
      }
      if (!mounted) return;
      final internalScan = _driveScans['internal'];
      final appsSize = await appsSizeFuture;
      final scansForCards = categoryDevices
          .map((device) => _driveScans[device.id])
          .whereType<_DriveScanData>();
      final categorySizes = {
        for (final category in const [
          'Downloads',
          'Documents',
          'Images',
          'Videos',
          'Audio',
          'Archives',
        ])
          category: category == 'Downloads'
              ? internalScan?.categoryBytes[category] == null
                    ? null
                    : formatBytes(internalScan!.categoryBytes[category]!)
              : _sumCategoryBytes(scansForCards, category),
        'Apps': appsSize == null
            ? (_appsSizeError == null ? null : 'Unavailable')
            : formatBytes(appsSize),
      };
      final recentFiles = _mergeRecentFiles(
        recentDevices.map((device) => _driveScans[device.id]),
        includeAndroidFolderFiles: ref
            .read(appSettingsProvider)
            .showAndroidFolderFilesInRecent,
      );
      setState(() {
        if (!_sameCategorySizes(_categorySizes, categorySizes)) {
          _categorySizes = categorySizes;
        }
        if (!_sameRecentFiles(_recentFiles, recentFiles)) {
          _recentFiles = recentFiles;
        }
        _scanLoading = false;
        _scanError = null;
        _refreshExceededDelay = false;
      });
      _cancelScanDisplayTimer();
    } catch (error) {
      if (mounted) {
        setState(() {
          _scanLoading = false;
          _scanError = 'Could not scan storage: $error';
          _refreshExceededDelay = false;
        });
      }
      _cancelScanDisplayTimer();
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

  void _startScanDisplayTimer() {
    _refreshDisplayTimer?.cancel();
    setState(() {
      _scanLoading = true;
      _scanError = null;
      _refreshExceededDelay = false;
    });
    _refreshDisplayTimer = Timer(_homeRefreshStaleDelay, () {
      if (mounted && _scanLoading) {
        setState(() => _refreshExceededDelay = true);
      }
    });
  }

  void _cancelScanDisplayTimer() {
    _refreshDisplayTimer?.cancel();
    _refreshDisplayTimer = null;
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
    required bool showHiddenFilesInRecent,
    required bool showNomediaFilesInRecent,
    required bool includeAndroidFolderFiles,
    required bool hideAndroidFoldersInCategoryPages,
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
    final archiveExtensions =
        categories
            .where((category) => category.name == 'Archives')
            .firstOrNull
            ?.extensions
            .map(FileTypeCategory.normalizeExtension)
            .toSet() ??
        const <String>{};
    final videoExtensions =
        categories
            .where((category) => category.name == 'Video')
            .firstOrNull
            ?.extensions
            .map(FileTypeCategory.normalizeExtension)
            .toSet() ??
        const <String>{};
    final audioExtensions =
        categories
            .where((category) => category.name == 'Audio')
            .firstOrNull
            ?.extensions
            .map(FileTypeCategory.normalizeExtension)
            .toSet() ??
        const <String>{};
    final root = Directory(device.path);
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
      'Archives': 0,
    };
    final weeklyRecent = <_RecentFile>[];
    final overallRecent = <_RecentFile>[];
    final cutoff = DateTime.now().subtract(const Duration(days: 7));
    final pending = <
      ({
        Directory directory,
        String relative,
        bool categoryNoMedia,
        bool recentNoMedia,
        bool insideNomedia,
        bool categoryVisible,
        bool recentVisible,
      })
    >[
      (
        directory: root,
        relative: '',
        categoryNoMedia: false,
        recentNoMedia: false,
        insideNomedia: false,
        categoryVisible: true,
        recentVisible: true,
      ),
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
        final name = storageDisplayName(path: entry.path);
        final isHidden = name.startsWith('.');
        final categoryVisible =
            current.categoryVisible && (!isHidden || showHiddenFiles);
        final recentVisible =
            current.recentVisible &&
            (!isHidden || showHiddenFilesInRecent);
        final relative = current.relative.isEmpty
            ? name
            : '${current.relative}/$name';
        if (entry is Directory) {
          if (!categoryVisible && !recentVisible) continue;
          if (!SharedStorageScanScope.shouldDescendIntoRelativePath(relative)) {
            continue;
          }
          final hasNoMedia = await File(
            '${entry.path}${Platform.pathSeparator}.nomedia',
          ).exists();
          pending.add((
            directory: entry,
            relative: relative,
            categoryNoMedia:
                !showNomediaFiles &&
                (current.categoryNoMedia || hasNoMedia),
            recentNoMedia:
                !showNomediaFilesInRecent &&
                (current.recentNoMedia || hasNoMedia),
            insideNomedia: current.insideNomedia || hasNoMedia,
            categoryVisible: categoryVisible,
            recentVisible: recentVisible,
          ));
          continue;
        }
        if (entry is! File) continue;
        if (!SharedStorageScanScope.shouldIncludeRelativePath(relative)) {
          continue;
        }
        if ((!categoryVisible || current.categoryNoMedia) &&
            (!recentVisible || current.recentNoMedia)) {
          continue;
        }
        FileStat stat;
        try {
          stat = await entry.stat();
        } on FileSystemException {
          continue;
        }
        final extension = _extensionOf(name);
        final inAndroidFolder = _isAndroidFolderPath(relative);
        final includeCategoryFile =
            categoryVisible &&
            !current.categoryNoMedia &&
            (!hideAndroidFoldersInCategoryPages || !inAndroidFolder);
        if (includeCategoryFile && documentExtensions.contains(extension)) {
          categoryBytes['Documents'] = categoryBytes['Documents']! + stat.size;
        }
        if (includeCategoryFile && imageExtensions.contains(extension)) {
          categoryBytes['Images'] = categoryBytes['Images']! + stat.size;
        }
        if (includeCategoryFile && videoExtensions.contains(extension)) {
          categoryBytes['Videos'] = categoryBytes['Videos']! + stat.size;
        }
        if (includeCategoryFile && audioExtensions.contains(extension)) {
          categoryBytes['Audio'] = categoryBytes['Audio']! + stat.size;
        }
        if (includeCategoryFile && archiveExtensions.contains(extension)) {
          categoryBytes['Archives'] = categoryBytes['Archives']! + stat.size;
        }
        if (!recentVisible ||
            current.recentNoMedia ||
            (!includeAndroidFolderFiles && inAndroidFolder)) {
          continue;
        }
        final candidate = _RecentFile(
          path: entry.path,
          name: name,
          driveId: device.id,
          modified: stat.modified,
          relativePath: relative,
          video: videoExtensions.contains(extension)
              ? VideoFile(
                  driveId: device.id,
                  relativePath: relative,
                  name: name,
                  extension: extension,
                  size: stat.size,
                  modified: stat.modified,
                  isHidden: isHidden,
                  isInsideNomedia: current.insideNomedia,
                )
              : null,
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

  Set<String> _videoExtensions(List<FileTypeCategory> categories) =>
      categories
          .where((category) => category.name == 'Video')
          .firstOrNull
          ?.extensions
          .map(FileTypeCategory.normalizeExtension)
          .toSet() ??
      const <String>{};

  Set<String> _audioExtensions(List<FileTypeCategory> categories) =>
      categories
          .where((category) => category.name == 'Audio')
          .firstOrNull
          ?.extensions
          .map(FileTypeCategory.normalizeExtension)
          .toSet() ??
      const <String>{};

  Set<String> _archiveExtensions(List<FileTypeCategory> categories) =>
      categories
          .where((category) => category.name == 'Archives')
          .firstOrNull
          ?.extensions
          .map(FileTypeCategory.normalizeExtension)
          .toSet() ??
      const <String>{};

  String? _sumCategoryBytes(Iterable<_DriveScanData> scans, String category) {
    var total = 0;
    var found = false;
    for (final scan in scans) {
      found = true;
      final bytes = scan.categoryBytes[category];
      if (bytes == null) return null;
      total += bytes;
    }
    return found ? formatBytes(total) : null;
  }

  Future<int?> _calculateAppsTotalBytes() async {
    try {
      final repository = getInstalledAppsRepository();
      _lastAppUsageAccess = await repository.hasUsageAccess();
      final apps = await repository.listInstalledApps();
      final sizes = await Future.wait(
        apps.map((app) => repository.getAppSize(app.packageName)),
      );
      return sizes.fold<int>(
        0,
        (total, size) => total + (size.totalBytes ?? size.apkBytes),
      );
    } catch (error) {
      _appsSizeError = 'Could not calculate app sizes: $error';
      return null;
    }
  }

  String _extensionOf(String name) {
    final dot = name.lastIndexOf('.');
    return dot <= 0
        ? ''
        : FileTypeCategory.normalizeExtension(name.substring(dot));
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

  List<_RecentFile> _mergeRecentFiles(
    Iterable<_DriveScanData?> scans, {
    required bool includeAndroidFolderFiles,
  }) {
    final available = scans.whereType<_DriveScanData>().toList();
    final recent = available
        .expand((scan) => scan.weeklyRecent)
        .where(
          (file) =>
              includeAndroidFolderFiles ||
              (!_isAndroidFolderPath(file.relativePath) &&
                  !_isAndroidFolderPath(file.path)),
        )
        .toList();
    final weekly = recent..sort((a, b) => b.modified.compareTo(a.modified));
    if (weekly.isNotEmpty) return weekly.take(100).toList();
    final overall =
        available
            .expand((scan) => scan.overallRecent)
            .where(
              (file) =>
                  includeAndroidFolderFiles ||
                  (!_isAndroidFolderPath(file.relativePath) &&
                      !_isAndroidFolderPath(file.path)),
            )
            .toList()
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
      if (previous?.showAndroidFolderFilesInRecent == true &&
          !next.showAndroidFolderFilesInRecent &&
          mounted) {
        setState(() {
          _recentFiles = _recentFiles
              .where(
                (file) =>
                    !_isAndroidFolderPath(file.relativePath) &&
                    !_isAndroidFolderPath(file.path),
              )
              .toList();
        });
      }
      if (previous?.includeOtherStorageDrivesInRecent !=
              next.includeOtherStorageDrivesInRecent ||
          previous?.includeOtherDrivesInCategoryPages !=
              next.includeOtherDrivesInCategoryPages ||
          previous?.showAndroidFolderFilesInRecent !=
              next.showAndroidFolderFilesInRecent ||
          previous?.hideAndroidFoldersInCategoryPages !=
              next.hideAndroidFoldersInCategoryPages ||
          previous?.showHiddenFiles != next.showHiddenFiles ||
          previous?.showNomediaFiles != next.showNomediaFiles ||
          previous?.showHiddenFilesInRecent != next.showHiddenFilesInRecent ||
          previous?.showNomediaFilesInRecent != next.showNomediaFilesInRecent) {
        unawaited(_scanHomeStorage(forceRefresh: true));
      }
    });
    ref.listen<List<FileTypeCategory>>(fileTypeCategoriesProvider, (
      previous,
      next,
    ) {
      if (previous == null) return;
      final previousExtensions = _videoExtensions(previous);
      final nextExtensions = _videoExtensions(next);
      final previousAudioExtensions = _audioExtensions(previous);
      final nextAudioExtensions = _audioExtensions(next);
      final previousArchiveExtensions = _archiveExtensions(previous);
      final nextArchiveExtensions = _archiveExtensions(next);
      if (previousExtensions.length != nextExtensions.length ||
          !previousExtensions.containsAll(nextExtensions) ||
          previousAudioExtensions.length != nextAudioExtensions.length ||
          !previousAudioExtensions.containsAll(nextAudioExtensions) ||
          previousArchiveExtensions.length != nextArchiveExtensions.length ||
          !previousArchiveExtensions.containsAll(nextArchiveExtensions)) {
        unawaited(_scanHomeStorage(forceRefresh: true));
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
              IconButton(
                tooltip: 'Refresh',
                onPressed: _scanLoading ? null : _refresh,
                icon: const Icon(Icons.refresh),
              ),
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
          body: LayoutBuilder(
            builder: (context, constraints) {
              const separatorHeight = 2.0;
              final sectionSpace =
                  constraints.maxHeight - (separatorHeight * 2);
              final minimumSectionHeight =
                  constraints.maxHeight * _homeSectionMinimumHeightFactor;
              final preferredStorageHeight =
                  _availableDriveCount != null && _availableDriveCount! <= 2
                  ? _homeAvailableStorageHeight * 1.1
                  : _homeAvailableStorageHeight;
              final preferredCardsHeight = math
                  .max(_homeCategoryCardsHeight, minimumSectionHeight)
                  .toDouble();
              final preferredStorage = math
                  .max(preferredStorageHeight, minimumSectionHeight)
                  .toDouble();
              var cardsHeight = preferredCardsHeight;
              var storageHeight = preferredStorage;
              var quickAccessHeight =
                  sectionSpace - cardsHeight - storageHeight;
              if (quickAccessHeight < minimumSectionHeight) {
                final availableForCardsAndStorage =
                    sectionSpace - minimumSectionHeight;
                cardsHeight =
                    availableForCardsAndStorage *
                    preferredCardsHeight /
                    (preferredCardsHeight + preferredStorage);
                storageHeight = availableForCardsAndStorage - cardsHeight;
                if (cardsHeight < minimumSectionHeight) {
                  cardsHeight = minimumSectionHeight;
                  storageHeight = availableForCardsAndStorage - cardsHeight;
                } else if (storageHeight < minimumSectionHeight) {
                  storageHeight = minimumSectionHeight;
                  cardsHeight = availableForCardsAndStorage - storageHeight;
                }
                quickAccessHeight = minimumSectionHeight;
              }
              return Column(
                children: [
                  SizedBox(
                    height: cardsHeight,
                    child: _CategoryCards(
                      categorySizes: _categorySizes,
                      scanLoading: _scanLoading,
                      showStaleValues: _refreshExceededDelay,
                    ),
                  ),
                  _homeSectionDivider(),
                  SizedBox(
                    height: quickAccessHeight,
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
                  _homeSectionDivider(),
                  SizedBox(
                    height: storageHeight,
                    child: _AvailableStorageSection(
                      key: _storageKey,
                      isActive: _isHomeVisible,
                      onDriveCountChanged: (count) {
                        if (_availableDriveCount == count || !mounted) return;
                        setState(() => _availableDriveCount = count);
                      },
                    ),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }
}

Widget _homeSectionDivider() => Container(
  width: double.infinity,
  height: 2,
  color: const Color(0xFF29B6F6),
);

class _CategoryCards extends ConsumerStatefulWidget {
  const _CategoryCards({
    required this.categorySizes,
    required this.scanLoading,
    required this.showStaleValues,
  });

  final Map<String, String?> categorySizes;
  final bool scanLoading;
  final bool showStaleValues;

  @override
  ConsumerState<_CategoryCards> createState() => _CategoryCardsState();
}

class _CategoryCardsState extends ConsumerState<_CategoryCards> {
  final List<Map<String, dynamic>> categories = const [
    {
      'name': 'Downloads',
      'icon': Icons.download,
      'color': FileTypeColor.downloads,
    },
    {
      'name': 'Documents',
      'icon': Icons.description,
      'color': FileTypeColor.documents,
    },
    {'name': 'Images', 'icon': Icons.image, 'color': FileTypeColor.image},
    {'name': 'Videos', 'icon': Icons.movie, 'color': FileTypeColor.video},
    {'name': 'Audio', 'icon': Icons.audiotrack, 'color': FileTypeColor.audio},
    {
      'name': 'Archives',
      'icon': Icons.folder_zip_outlined,
      'color': FileTypeColor.archive,
    },
    {'name': 'Apps', 'icon': Icons.apps, 'color': FileTypeColor.apps},
  ];

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final cardHeight = math
            .max(
              0.0,
              constraints.maxHeight -
                  (fontScaledSpacing(context, _homeSectionSeparatorGap) * 2),
            )
            .toDouble();
        return Padding(
          padding: EdgeInsets.symmetric(
            vertical: fontScaledSpacing(context, _homeSectionSeparatorGap),
          ),
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            primary: false,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemBuilder: (context, index) {
              final c = categories[index];
              return SizedBox(
                width: MediaQuery.of(context).size.width * 0.4,
                height: cardHeight,
                child: InkWell(
                  onTap: () async {
                    if (c['name'] == 'Apps') {
                      TabsManager.instance.openAppsTab();
                      return;
                    }
                    if (c['name'] == 'Videos') {
                      TabsManager.instance.openVideoTab();
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
                    } else {
                      folder = '';
                    }

                    final downloadsDirectory = name.contains('download')
                        ? await _findDownloadsDirectory(base)
                        : null;
                    if (!context.mounted) return;
                    if (name.contains('download') &&
                        downloadsDirectory == null) {
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
                          : name.contains('audio')
                          ? 'Audio'
                          : name.contains('archive')
                          ? 'Archives'
                          : null,
                      imageOnly: name.contains('image'),
                      documentOnly: name.contains('document'),
                      audioOnly: name.contains('audio'),
                      archiveOnly: name.contains('archive'),
                    );
                  },
                  child: Card(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: SingleChildScrollView(
                        primary: false,
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            minHeight: math
                                .max(0.0, cardHeight - 24)
                                .toDouble(),
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: [
                              c['name'] == 'Apps'
                                  ? const _AppsCategoryIcon()
                                  : Icon(
                                      c['icon'] as IconData,
                                      size: 36,
                                      color: fileTypeColor(
                                        context,
                                        c['color'] as FileTypeColor,
                                      ),
                                    ),
                              Text(
                                c['name'] as String,
                                style: Theme.of(context).textTheme.titleMedium,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              _CategorySize(
                                category: c['name'] as String,
                                size: widget.categorySizes[c['name'] as String],
                                loading: widget.scanLoading,
                                showStaleValue: widget.showStaleValues,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
            separatorBuilder: (_, _) => const SizedBox(width: 12),
            itemCount: categories.length,
          ),
        );
      },
    );
  }
}

class _CategorySize extends StatelessWidget {
  final String category;
  final String? size;
  final bool loading;
  final bool showStaleValue;

  const _CategorySize({
    required this.category,
    required this.size,
    required this.loading,
    required this.showStaleValue,
  });

  @override
  Widget build(BuildContext context) {
    return Text(
      loading
          ? showStaleValue && size != null
                ? '$size ...'
                : 'Calculating...'
          : size ?? 'Unavailable',
      style: Theme.of(context).textTheme.bodySmall,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}

class _AppsCategoryIcon extends StatelessWidget {
  const _AppsCategoryIcon();

  static const _colors = [
    Color.fromARGB(255, 238, 248, 38),
    Color.fromARGB(255, 186, 241, 47),
    Color.fromARGB(255, 115, 245, 22),
    Color.fromARGB(255, 234, 132, 49),
    Color.fromARGB(255, 243, 37, 10),
    Color.fromARGB(255, 164, 46, 7),
    Color.fromARGB(255, 67, 204, 249),
    Color.fromARGB(255, 11, 95, 192),
    Color.fromARGB(255, 16, 40, 197),
  ];

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 36,
      height: 36,
      child: Center(
        child: Wrap(
          spacing: 2,
          runSpacing: 2,
          children: [
            for (final color in _colors)
              DecoratedBox(
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                child: const SizedBox(width: 8, height: 8),
              ),
          ],
        ),
      ),
    );
  }
}

String _displayRecentName(String name, AppSettings settings) => displayFileName(
  name,
  showExtension: settings.showFileExtension,
  isDirectory: false,
);

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
  final ScrollController _quickAccessScrollController = ScrollController();
  final ScrollController _recentScrollController = ScrollController();
  List<String> _orderedPaths = [];
  bool _showRecent = false;
  bool _recentListScrolling = false;
  late List<_RecentFile> _displayedRecentFiles;
  List<_RecentFile>? _pendingRecentFiles;

  @override
  void initState() {
    super.initState();
    _displayedRecentFiles = List<_RecentFile>.of(widget.recentFiles);
  }

  @override
  void dispose() {
    _quickAccessScrollController.dispose();
    _recentScrollController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _QuickAccessSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_sameRecentFiles(_displayedRecentFiles, widget.recentFiles)) return;
    final latest = List<_RecentFile>.of(widget.recentFiles);
    final androidFilesWereRemoved =
        _displayedRecentFiles.any(
          (file) =>
              _isAndroidFolderPath(file.relativePath) ||
              _isAndroidFolderPath(file.path),
        ) &&
        !latest.any(
          (file) =>
              _isAndroidFolderPath(file.relativePath) ||
              _isAndroidFolderPath(file.path),
        );
    if (androidFilesWereRemoved) {
      _displayedRecentFiles = latest;
      _pendingRecentFiles = null;
      return;
    }
    if (_recentListScrolling) {
      _pendingRecentFiles = latest;
    } else {
      _displayedRecentFiles = latest;
      _pendingRecentFiles = null;
    }
  }

  bool _sameRecentFiles(List<_RecentFile> left, List<_RecentFile> right) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      final a = left[index];
      final b = right[index];
      if (a.path != b.path || a.name != b.name || a.modified != b.modified) {
        return false;
      }
    }
    return true;
  }

  void _selectRecentSection(bool showRecent) {
    setState(() {
      _showRecent = showRecent;
      if (!showRecent) {
        _recentListScrolling = false;
        if (_pendingRecentFiles != null) {
          _displayedRecentFiles = _pendingRecentFiles!;
          _pendingRecentFiles = null;
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final ref = this.ref;
    final quickAccess = ref.watch(quickAccessProvider);
    final use24HourTime = ref.watch(appSettingsProvider).use24HourTime;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        fontScaledSpacing(context, _homeSectionSeparatorGap),
        16,
        fontScaledSpacing(context, _homeSectionSeparatorGap),
      ),
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
                        : Scrollbar(
                            controller: _quickAccessScrollController,
                            thumbVisibility: true,
                            interactive: true,
                            child: _buildReorderableList(
                              context,
                              ref,
                              items,
                            ),
                          ),
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
          onTap: () => _selectRecentSection(title == 'Recent'),
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
      scrollController: _quickAccessScrollController,
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
        final settings = ref.watch(appSettingsProvider);
        final displayName = displayFileName(
          item.name,
          showExtension: settings.showFileExtension,
          isDirectory: item.isDirectory,
        );
        final displayPath = displayFilePath(
          item.path,
          showExtension: settings.showFileExtension,
          isDirectory: item.isDirectory,
        );
        final titlePainter = TextPainter(
          text: TextSpan(
            text: displayName,
            style: Theme.of(context).textTheme.titleSmall,
          ),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
          maxLines: 1,
        )..layout();
        final pathPainter = TextPainter(
          text: TextSpan(
            text: displayPath,
            style: Theme.of(context).textTheme.labelSmall,
          ),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
          maxLines: 1,
        )..layout();
        return ReorderableDelayedDragStartListener(
          key: ValueKey(item.path),
          index: index,
          child: ListTile(
            dense: true,
            minTileHeight:
                titlePainter.height +
                pathPainter.height +
                fontScaledSpacing(context, 12),
            contentPadding: const EdgeInsets.only(left: 16, right: 0),
            leading: FileTypeIcon(
              extension: item.isDirectory
                  ? ''
                  : _fileExtensionForDisplay(item.name),
              isFolder: item.isDirectory,
              path: item.isDirectory ? null : item.path,
            ),
            title: MarqueeText(
              displayName,
              style: Theme.of(context).textTheme.titleSmall,
              styleMode: MarqueeStyle.pauseAndLoop,
              isActive: widget.isHomeVisible && !_showRecent,
            ),
            subtitle: MarqueeText(
              displayPath,
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
    final settings = ref.watch(appSettingsProvider);
    final displayedRecentFiles = settings.showAndroidFolderFilesInRecent
        ? _displayedRecentFiles
        : _displayedRecentFiles
              .where(
                (file) =>
                    !_isAndroidFolderPath(file.relativePath) &&
                    !_isAndroidFolderPath(file.path),
              )
              .toList();
    if (!widget.storagePermissionAvailable) {
      return const Center(child: Text('Storage permission required'));
    }
    if (widget.recentLoading && displayedRecentFiles.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (widget.recentError != null && displayedRecentFiles.isEmpty) {
      return Center(child: Text(widget.recentError!));
    }
    if (displayedRecentFiles.isEmpty) {
      return const Center(child: Text('No recent files'));
    }
    final recentList = NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is ScrollStartNotification) {
          _recentListScrolling = true;
        } else if (notification is ScrollEndNotification) {
          _recentListScrolling = false;
          final pending = _pendingRecentFiles;
          if (pending != null) {
            setState(() {
              _displayedRecentFiles = pending;
              _pendingRecentFiles = null;
            });
          }
        }
        return false;
      },
      child: ListView.builder(
        controller: _recentScrollController,
        primary: false,
        physics: const ClampingScrollPhysics(),
        itemCount: displayedRecentFiles.length,
        itemBuilder: (context, index) {
          final file = displayedRecentFiles[index];
          final displayName = _displayRecentName(file.name, settings);
          final displayPath = displayFilePath(
            file.path,
            showExtension: settings.showFileExtension,
            isDirectory: false,
          );
          final date = file.modified;
          const months = [
            'Jan',
            'Feb',
            'Mar',
            'Apr',
            'May',
            'Jun',
            'Jul',
            'Aug',
            'Sep',
            'Oct',
            'Nov',
            'Dec',
          ];
          final dateText = '${date.day} ${months[date.month - 1]} ${date.year}';
          final timeText = formatClockTime(date, use24HourTime: use24HourTime);
          final detailStyle = Theme.of(context).textTheme.labelSmall;
          final datePainter = TextPainter(
            text: TextSpan(text: dateText, style: detailStyle),
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context),
            maxLines: 1,
          )..layout();
          final titlePainter = TextPainter(
            text: TextSpan(
              text: displayName,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context),
            maxLines: 1,
          )..layout();
          final pathPainter = TextPainter(
            text: TextSpan(
              text: displayPath,
              style: Theme.of(context).textTheme.labelSmall,
            ),
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context),
            maxLines: 1,
          )..layout();
          return ListTile(
            dense: true,
            minTileHeight:
                titlePainter.height +
                pathPainter.height +
                fontScaledSpacing(context, 12),
            contentPadding: const EdgeInsets.only(left: 16, right: 0),
            leading: FileTypeIcon(
              extension: _fileExtensionForDisplay(file.name),
              path: file.path,
              video: file.video,
            ),
            title: MarqueeText(
              displayName,
              style: Theme.of(context).textTheme.titleSmall,
              styleMode: MarqueeStyle.pauseAndLoop,
              isActive: widget.isHomeVisible && _showRecent,
            ),
            subtitle: MarqueeText(
              displayPath,
              style: Theme.of(context).textTheme.labelSmall,
              styleMode: MarqueeStyle.pauseAndLoop,
              isActive: widget.isHomeVisible && _showRecent,
            ),
            trailing: SizedBox(
              width: datePainter.width.ceilToDouble(),
              height: (datePainter.height * 2 + fontScaledSpacing(context, 8))
                  .clamp(
                    fontScaledSpacing(context, 48),
                    fontScaledSpacing(context, 120),
                  )
                  .toDouble(),
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
      ),
    );
    final recentScrollable = Scrollbar(
      controller: _recentScrollController,
      thumbVisibility: displayedRecentFiles.length > 1,
      interactive: true,
      child: recentList,
    );
    if (widget.recentError == null) return recentScrollable;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Text(
            widget.recentError!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
        Expanded(child: recentScrollable),
      ],
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
    if (category == 'Video') {
      if (!context.mounted) return;
      await openVideoFile(
        context,
        ref,
        path: item.path,
        name: item.name,
        useSavedDefaultApps: fromSearch
            ? ref.read(appSettingsProvider).useSavedDefaultApps
            : ref.read(appSettingsProvider).useSavedDefaultAppsForQuickAccess,
      );
      return;
    }
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
        if (savedDefault.isVideoPlayer) {
          if (!context.mounted) return;
          await openVideoFile(context, ref, path: item.path, name: item.name);
          return;
        }
        if (savedDefault.isArchiveManager) {
          TabsManager.instance.openArchiveManagerTab(item.path);
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

    final isApk = extension.toLowerCase() == '.apk';
    final canUseTextEditor = !isApk && category == 'Text';
    final canUseImageViewer = !isApk && category == 'Image';
    final canUseArchiveManager = category == 'Archives';

    if (apps.isEmpty &&
        !canUseTextEditor &&
        !canUseImageViewer &&
        !canUseArchiveManager) {
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
          if (canUseArchiveManager)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(
                dialogContext,
                OpenWithApp(
                  name: 'Archive Manager (built-in)',
                  packageName: DefaultFileApp.archiveManagerHandlerId,
                  mimeType: 'application/x-archive',
                  iconBytes: builtInIcon,
                ),
              ),
              child: Row(
                children: [
                  _openWithAppIcon(
                    OpenWithApp(
                      name: 'Archive Manager (built-in)',
                      packageName: DefaultFileApp.archiveManagerHandlerId,
                      mimeType: 'application/x-archive',
                      iconBytes: builtInIcon,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Text('Archive Manager (built-in)'),
                ],
              ),
            ),
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
    if (selection.packageName == DefaultFileApp.archiveManagerHandlerId) {
      TabsManager.instance.openArchiveManagerTab(item.path);
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
  final ValueChanged<int> onDriveCountChanged;

  const _AvailableStorageSection({
    super.key,
    required this.isActive,
    required this.onDriveCountChanged,
  });

  @override
  State<_AvailableStorageSection> createState() =>
      _AvailableStorageSectionState();
}

class _AvailableStorageSectionState extends State<_AvailableStorageSection> {
  List<StorageDevice>? _devices;
  bool _loading = true;
  bool _showStaleValues = false;
  Object? _loadError;
  Timer? _refreshDisplayTimer;
  int _loadRequestId = 0;

  @override
  void initState() {
    super.initState();
    _loadDevices();
  }

  @override
  void dispose() {
    _refreshDisplayTimer?.cancel();
    super.dispose();
  }

  void refresh() {
    _loadDevices();
  }

  bool _sameStorageDevices(
    List<StorageDevice>? current,
    List<StorageDevice> next,
  ) {
    if (current == null || current.length != next.length) return false;
    for (var index = 0; index < current.length; index++) {
      final oldDevice = current[index];
      final newDevice = next[index];
      if (oldDevice.id != newDevice.id ||
          oldDevice.path != newDevice.path ||
          oldDevice.totalBytes != newDevice.totalBytes ||
          oldDevice.usedBytes != newDevice.usedBytes) {
        return false;
      }
    }
    return true;
  }

  Future<void> _loadDevices() async {
    final requestId = ++_loadRequestId;
    _refreshDisplayTimer?.cancel();
    setState(() {
      _loading = true;
      _showStaleValues = false;
      _loadError = null;
    });
    _refreshDisplayTimer = Timer(_homeRefreshStaleDelay, () {
      if (mounted && _loading && requestId == _loadRequestId) {
        setState(() => _showStaleValues = true);
      }
    });
    try {
      final devices = await getStorageRepository().listStorageDevices();
      if (!mounted || requestId != _loadRequestId) return;
      setState(() {
        if (!_sameStorageDevices(_devices, devices)) _devices = devices;
        _loading = false;
        _showStaleValues = false;
      });
      _refreshDisplayTimer?.cancel();
      widget.onDriveCountChanged(devices.length);
    } catch (error) {
      if (!mounted || requestId != _loadRequestId) return;
      setState(() {
        _loading = false;
        _showStaleValues = false;
        _loadError = error;
      });
      _refreshDisplayTimer?.cancel();
    } finally {
      if (requestId == _loadRequestId) _refreshDisplayTimer = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: 16,
        vertical: fontScaledSpacing(context, _homeSectionSeparatorGap),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Available Storage',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _loadError != null && _devices == null
                ? Center(child: Text('Could not load storage: $_loadError'))
                : _devices == null
                ? Center(
                    child: Text(
                      _loading ? 'Calculating...' : 'No storage devices found',
                    ),
                  )
                : _devices!.isEmpty
                ? Column(
                    children: [
                      if (_loadError != null)
                        Padding(
                          padding: const EdgeInsets.all(8),
                          child: Text(
                            'Could not refresh storage: $_loadError',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ),
                      const Expanded(
                        child: Center(child: Text('No storage devices found')),
                      ),
                    ],
                  )
                : Column(
                    children: [
                      if (_loadError != null)
                        Padding(
                          padding: const EdgeInsets.all(8),
                          child: Text(
                            'Could not refresh storage: $_loadError',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ),
                      Expanded(
                        child: GridView.count(
                          crossAxisCount: 2,
                          childAspectRatio: 1.7,
                          crossAxisSpacing: 8,
                          mainAxisSpacing: fontScaledSpacing(context, 8),
                          shrinkWrap: true,
                          children: _devices!
                              .map(
                                (device) => _StorageCard(
                                  device: device,
                                  isActive: widget.isActive,
                                  calculating: _loading && !_showStaleValues,
                                  showStaleValue: _loading && _showStaleValues,
                                ),
                              )
                              .toList(),
                        ),
                      ),
                    ],
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
  final bool calculating;
  final bool showStaleValue;

  const _StorageCard({
    required this.device,
    required this.isActive,
    required this.calculating,
    required this.showStaleValue,
  });

  @override
  Widget build(BuildContext context) {
    final occupied = formatBytes(device.usedBytes);
    final total = formatBytes(device.totalBytes);
    final totalBytes = device.totalBytes;
    final usedBytes = device.usedBytes ?? 0;
    final freePercent = totalBytes != null && totalBytes > 0
        ? (((totalBytes - usedBytes) / totalBytes) * 100).clamp(0, 100)
        : null;
    final usageText = calculating || (showStaleValue && freePercent == null)
        ? 'Calculating...'
        : freePercent == null
        ? 'Storage info unavailable'
        : '$occupied / $total used - ${freePercent.toStringAsFixed(1)}% free'
              '${showStaleValue ? ' ...' : ''}';

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

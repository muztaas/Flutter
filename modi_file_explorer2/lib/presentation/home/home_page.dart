import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../core/providers/default_file_apps_provider.dart';
import '../../core/providers/device_power_provider.dart';
import '../../core/filesystem/file_change_notifier.dart';
import '../../core/filesystem/filesystem_cache.dart';
import '../../core/filesystem/refresh_coordinator.dart';
import '../../core/providers/file_type_categories_provider.dart';
import '../../core/providers/installed_apps_providers.dart';
import '../../core/providers/open_with_providers.dart';
import '../../core/providers/settings_provider.dart';
import '../../core/providers/quick_access_provider.dart';
import '../../core/providers/storage_providers.dart';
import '../../core/providers/video_providers.dart';
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
import '../../domain/utils/file_visibility.dart';
import '../common/marquee_text.dart';
import '../common/file_type_icon.dart';
import '../image_viewer/image_file_preview.dart';
import '../common/open_with_label.dart';
import '../common/open_video_file.dart';
import '../common/open_pdf_file.dart';
import '../common/open_audio_file.dart';
import '../common/search_action_button.dart';
import 'home_storage_scan.dart';
import '../storage/storage_tab.dart';

const _homeRefreshStaleDelay = Duration(seconds: 5);
const _minimumBackgroundRefreshInterval = Duration(seconds: 10);
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
    required this.isHidden,
    required this.isInsideNomedia,
    required this.isInsideAndroidFolder,
  });

  final String path;
  final String name;
  final String driveId;
  final DateTime modified;
  final String relativePath;
  final VideoFile? video;
  final bool isHidden;
  final bool isInsideNomedia;
  final bool isInsideAndroidFolder;
}

Future<void> _prefetchStorageDriveRoots(
  List<StorageDevice> devices,
) async {
  for (final device in devices) {
    try {
      final cached = await FilesystemCache.instance.loadFolder(
        device.id,
        device.path,
      );
      if (cached?.isComplete == true && cached?.isStale == false) continue;
      await RefreshCoordinator.instance.run<void>(
        scope: 'folder:${device.id}:${device.path}',
        owner: FilesystemCache.instance,
        priority: RefreshPriority.prefetch,
        work: (token) async {
          token.throwIfCancelled();
          final root = Directory(device.path);
          final entries = await root.list(followLinks: false).toList();
          final modified = (await root.stat()).modified.millisecondsSinceEpoch;
          final cachedEntries = <CachedListingEntry>[];
          var complete = true;
          for (final entry in entries) {
            token.throwIfCancelled();
            try {
              final stat = await entry.stat();
              cachedEntries.add(
                CachedListingEntry(
                  path: entry.path,
                  isDirectory: entry is Directory,
                  size: stat.size,
                  modifiedMilliseconds: stat.modified.millisecondsSinceEpoch,
                ),
              );
            } on FileSystemException {
              complete = false;
            }
          }
          await FilesystemCache.instance.saveFolder(
            volumeId: device.id,
            path: device.path,
            directoryModifiedMilliseconds: modified,
            entries: cachedEntries,
            isComplete: complete,
          );
          return RefreshWorkResult<void>(null, changeCount: entries.length);
        },
      );
    } on RefreshCancelled {
      return;
    } catch (error) {
      debugPrint(
        '[HomePage] Could not prefetch storage root "${device.path}": $error',
      );
    }
  }
}

class _DriveScanData {
  const _DriveScanData({
    required this.weeklyRecent,
    required this.overallRecent,
    required this.categoryBytes,
    this.directoryModifiedMilliseconds = const {},
    this.directoryStampsComplete = true,
  });

  final List<_RecentFile> weeklyRecent;
  final List<_RecentFile> overallRecent;
  final Map<String, int?> categoryBytes;
  final Map<String, int> directoryModifiedMilliseconds;
  final bool directoryStampsComplete;
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
  final Object _refreshOwner = Object();
  final Map<String, _DriveScanData> _driveScans = {};
  final Map<String, Map<String, int?>> _cachedCategoryBytesByDrive = {};
  final Set<String> _staleDriveIds = {};
  Map<String, String?> _categorySizes = const {};
  List<_RecentFile> _recentFiles = const [];
  bool _scanLoading = true;
  bool _storagePermissionAvailable = true;
  String? _scanError;
  bool _scanInProgress = false;
  bool _scanRequestedAgain = false;
  bool _forceRescanRequested = false;
  bool _isHomeVisible = true;
  bool _cacheExpiryScheduled = false;
  bool _refreshExceededDelay = false;
  Timer? _refreshDisplayTimer;
  int? _availableDriveCount;
  bool? _lastStoragePermissionAvailable;
  bool? _lastAppUsageAccess;
  String? _appsSizeError;
  DateTime? _backgroundSince;
  bool _resumeRefreshInProgress = false;

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
      unawaited(_refreshPrefetchPowerConstraints());
      unawaited(_expireUnusedFilesystemCaches());
      _scanHomeStorage();
    });
  }

  Future<void> _expireUnusedFilesystemCaches() async {
    if (_cacheExpiryScheduled || !_tabs.restoreAttempted) return;
    _cacheExpiryScheduled = true;
    try {
      await RefreshCoordinator.instance.run<void>(
        scope: 'filesystem-cache-expiry',
        owner: FilesystemCache.instance,
        priority: RefreshPriority.maintenance,
        work: (token) async {
          token.throwIfCancelled();
          await FilesystemCache.instance.ready;
          final openFolderPaths = <String>{};
          final openCategoryCacheKeys = <String>{};
          for (final tab in _tabs.tabs) {
            final path = tab.storagePath;
            if (path != null) openFolderPaths.add(path);
            final categoryPrefix = tab.imageOnly
                ? 'imageStorage'
                : tab.documentOnly
                ? 'documentStorage'
                : tab.audioOnly
                ? 'audioStorage'
                : tab.archiveOnly
                ? 'archiveStorage'
                : null;
            if (categoryPrefix == null) continue;
            final rootPath = (tab.driveRoot ?? path)?.replaceAll('\\', '/');
            final driveId = tab.driveId;
            if (rootPath == null || driveId == null) continue;
            final normalizedRoot = rootPath.replaceFirst(RegExp(r'/+$'), '');
            openCategoryCacheKeys.add(
              'category:$driveId:$categoryPrefix::$normalizedRoot',
            );
          }
          await FilesystemCache.instance.expireUnused(
            openFolderPaths: openFolderPaths,
            openCategoryCacheKeys: openCategoryCacheKeys,
          );
          return const RefreshWorkResult(null);
        },
      );
    } on RefreshCancelled {
      // Low-priority cleanup can be retried at the next app start.
    } catch (error) {
      debugPrint('[HomePage] Could not expire unused caches: $error');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tabs.removeListener(_onTabsChanged);
    _refreshDisplayTimer?.cancel();
    RefreshCoordinator.instance.cancelOwner(_refreshOwner);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _backgroundSince ??= DateTime.now();
      return;
    }
    if (state != AppLifecycleState.resumed) return;
    if (state == AppLifecycleState.resumed && Platform.isAndroid) {
      unawaited(_refreshPrefetchPowerConstraints());
      unawaited(_refreshIfStorageAccessWasGranted());
      unawaited(_refreshAppsTotalIfUsageAccessChanged());
    }
    final backgroundSince = _backgroundSince;
    _backgroundSince = null;
    if (backgroundSince != null &&
        DateTime.now().difference(backgroundSince) >=
            _minimumBackgroundRefreshInterval) {
      unawaited(_refreshAfterResume());
    }
  }

  Future<void> _refreshAfterResume() async {
    if (_resumeRefreshInProgress || !mounted) return;
    _resumeRefreshInProgress = true;
    try {
      final settings = ref.read(appSettingsProvider);
      final devices = await getStorageRepository().listStorageDevices();
      final recentDevices = devices
          .where(
            (device) =>
                device.id == 'internal' ||
                settings.includeOtherStorageDrivesInRecent,
          )
          .toList(growable: false);
      final homeScanIsCurrent = await _refreshRecentDirectoryChanges(
        recentDevices,
        settings,
      );
      final selectedTab = _tabs.tabs[_tabs.selectedIndex];
      if (selectedTab.isVideoPage) {
        await _refreshVideoTab(selectedTab.sessionId);
      } else if (selectedTab.storagePath != null) {
        await StorageTabState.refreshMountedDirectories({
          selectedTab.storagePath!,
        });
      }
      if (!homeScanIsCurrent) {
        await _scanHomeStorage(forceRefresh: true);
        await StorageTabState.refreshMountedDirectories(
          _tabs.tabs.map((tab) => tab.storagePath).whereType<String>(),
        );
      }
    } catch (error) {
      debugPrint('[HomePage] Resume refresh failed: $error');
    } finally {
      _resumeRefreshInProgress = false;
    }
  }

  Future<bool> _refreshRecentDirectoryChanges(
    List<StorageDevice> devices,
    AppSettings settings,
  ) async {
    for (final device in devices) {
      final raw = await FilesystemCache.instance.loadValue(
        'homeDrive:${device.id}',
        markUsed: false,
      );
      if (raw == null) return false;
      final previous = _decodeDriveScan(raw);
      if (previous == null || !previous.directoryStampsComplete) return false;
      final validation = await RefreshCoordinator.instance.run<
        Map<String, Object?>
      >(
        scope: 'home-stamps:${device.id}',
        owner: _refreshOwner,
        priority: _isHomeVisible
            ? RefreshPriority.visiblePage
            : RefreshPriority.openPages,
        work: (token) async {
          token.throwIfCancelled();
          final result = await compute<
            Map<String, Object?>,
            Map<String, Object?>
          >(validateHomeDirectoryStamps, {
            'stamps': previous.directoryModifiedMilliseconds,
          });
          token.throwIfCancelled();
          return RefreshWorkResult(result);
        },
      );
      if ((validation['changed'] as List).isNotEmpty ||
          (validation['missing'] as List).isNotEmpty) {
        return false;
      }
      _driveScans[device.id] = previous;
    }

    if (mounted) {
      setState(() {
        _recentFiles = _mergeRecentFiles(
          devices.map((device) => _driveScans[device.id]),
          showHiddenFiles: settings.showHiddenFilesInRecent,
          showNomediaFiles: settings.showNomediaFilesInRecent,
          includeAndroidFolderFiles: settings.showAndroidFolderFilesInRecent,
          blacklistedPaths: settings.blacklistedPaths,
          whitelistedPaths: settings.whitelistedPaths,
        );
      });
    }
    return true;
  }

  Future<void> _refreshVideoTab(String sessionId) async {
    await ref.read(videoPageSettingsProvider.notifier).ready;
    final controller = ref.read(videoTabProvider(sessionId).notifier);
    final settings = ref.read(videoPageSettingsProvider);
    final permissionGranted =
        (await Permission.storage.status).isGranted ||
        (await Permission.manageExternalStorage.status).isGranted;
    try {
      await RefreshCoordinator.instance.run<bool>(
        scope: 'video:$sessionId:resume',
        owner: _refreshOwner,
        priority: RefreshPriority.visiblePage,
        work: (token) async {
          token.throwIfCancelled();
          final adjusted = await controller.refresh(
            permissionGranted: permissionGranted,
            settings: settings,
            showLoading: false,
          );
          return RefreshWorkResult(adjusted);
        },
      );
    } on RefreshCancelled {
      // Resume work can be retried at the next foreground transition.
    }
  }

  Future<void> _refreshPrefetchPowerConstraints() async {
    try {
      final powerState = await ref
          .read(devicePowerRepositoryProvider)
          .getPowerState();
      RefreshCoordinator.instance.updatePowerConstraints(
        lowBattery: powerState.isLowBattery,
        batterySaver: powerState.isBatterySaverEnabled,
      );
    } on PlatformException catch (error) {
      debugPrint('Could not read Android power state: $error');
      RefreshCoordinator.instance.updatePowerConstraints(
        lowBattery: true,
        batterySaver: true,
      );
    } on MissingPluginException catch (error) {
      debugPrint('Android power-state checker is unavailable: $error');
      RefreshCoordinator.instance.updatePowerConstraints(
        lowBattery: true,
        batterySaver: true,
      );
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
    if (_tabs.restoreAttempted) {
      unawaited(_expireUnusedFilesystemCaches());
    }
    final isHomeVisible = _tabs.selectedIndex == 0;
    if (_isHomeVisible == isHomeVisible || !mounted) return;
    setState(() => _isHomeVisible = isHomeVisible);
  }

  void _refresh() {
    unawaited(ref.read(availableStorageDevicesProvider.notifier).refresh());
    _scanHomeStorage(forceRefresh: true);
    _storageKey.currentState?.refresh();
  }

  Future<void> _scanHomeStorage({
    bool forceRefresh = false,
    bool refreshRecent = true,
  }) async {
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
          _driveScans.clear();
          _staleDriveIds.clear();
          await FilesystemCache.instance.clear();
          _cancelScanDisplayTimer();
          return;
        }
      }

      final devices = await getStorageRepository().listStorageDevices();
      await FilesystemCache.instance.removeVolumesNotPresent(
        devices.map((device) => device.id).toSet(),
      );
      unawaited(_prefetchStorageDriveRoots(devices));
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
      final cachedApps = await FilesystemCache.instance.loadValue(
        'homeAppsTotal',
      );
      final cachedAppsBytes = cachedApps?['bytes'] as int?;
      final cachedCategoryTotals = await FilesystemCache.instance.loadValue(
        'homeCategoryTotals',
      );
      _cachedCategoryBytesByDrive.clear();
      if (cachedCategoryTotals != null &&
          cachedCategoryTotals['settingsSignature'] ==
              _homeCategoryTotalsSignature()) {
        _cachedCategoryBytesByDrive
          ..clear()
          ..addAll(
            _decodeCategoryTotals(cachedCategoryTotals['totalsByVolume']),
          );
      }
      for (final device in scanDevices) {
        if (forceRefresh || _driveScans.containsKey(device.id)) continue;
        final cached = await FilesystemCache.instance.loadValue(
          'homeDrive:${device.id}',
          markUsed: true,
        );
        if (cached == null ||
            cached['stale'] == true ||
            cached['settingsSignature'] != _homeScanSettingsSignature()) {
          _staleDriveIds.add(device.id);
          continue;
        }
        final data = _decodeDriveScan(cached);
        if (data != null) {
          _driveScans[device.id] = _DriveScanData(
            weeklyRecent: data.weeklyRecent,
            overallRecent: data.overallRecent,
            categoryBytes: data.categoryBytes,
            directoryModifiedMilliseconds:
                data.directoryModifiedMilliseconds,
            directoryStampsComplete: data.directoryStampsComplete,
          );
          _staleDriveIds.remove(device.id);
        } else {
          _staleDriveIds.add(device.id);
        }
      }
      if (mounted &&
          (_driveScans.containsKey('internal') ||
              _cachedCategoryBytesByDrive.containsKey('internal'))) {
        final cachedRecentFiles = _mergeRecentFiles(
          recentDevices.map((device) => _driveScans[device.id]),
          showHiddenFiles: settings.showHiddenFilesInRecent,
          showNomediaFiles: settings.showNomediaFilesInRecent,
          includeAndroidFolderFiles: settings.showAndroidFolderFilesInRecent,
          blacklistedPaths: settings.blacklistedPaths,
          whitelistedPaths: settings.whitelistedPaths,
        );
        setState(() {
          _categorySizes = _homeCategorySizes(categoryDevices, cachedAppsBytes);
          _recentFiles = cachedRecentFiles;
          _scanError = null;
        });
      }
      final needsScan = scanDevices.any(
        (device) =>
            forceRefresh ||
            !_driveScans.containsKey(device.id) ||
            _staleDriveIds.contains(device.id),
      );
      if (mounted && needsScan && !_scanLoading) {
        _startScanDisplayTimer();
      }
      final categories = ref.read(fileTypeCategoriesProvider);
      for (final device in scanDevices) {
        if (!forceRefresh &&
            _driveScans.containsKey(device.id) &&
            !_staleDriveIds.contains(device.id)) {
          continue;
        }
        final scan = await RefreshCoordinator.instance.run<_DriveScanData>(
          scope: 'home:${device.id}',
          owner: _refreshOwner,
          priority: _isHomeVisible
              ? RefreshPriority.visiblePage
              : RefreshPriority.openPages,
          work: (token) async {
            token.throwIfCancelled();
            final result = await _scanStorageDrive(
              device,
              categories,
              refreshRecent: refreshRecent,
              showHiddenFiles: settings.showHiddenFiles,
              showNomediaFiles: settings.showNomediaFiles,
              hideAndroidFoldersInCategoryPages:
                  settings.hideAndroidFoldersInCategoryPages,
              blacklistedPaths: settings.blacklistedPaths,
              whitelistedPaths: settings.whitelistedPaths,
            );
            return RefreshWorkResult(result);
          },
        );
        final completedScan = refreshRecent
            ? scan
            : _DriveScanData(
                weeklyRecent:
                    _driveScans[device.id]?.weeklyRecent ?? const [],
                overallRecent:
                    _driveScans[device.id]?.overallRecent ?? const [],
                categoryBytes: scan.categoryBytes,
                directoryModifiedMilliseconds:
                    _driveScans[device.id]?.directoryModifiedMilliseconds ??
                    const {},
                directoryStampsComplete:
                    _driveScans[device.id]?.directoryStampsComplete ?? false,
              );
        _driveScans[device.id] = completedScan;
        _cachedCategoryBytesByDrive[device.id] = completedScan.categoryBytes;
        _staleDriveIds.remove(device.id);
        await FilesystemCache.instance.saveValue(
          'homeDrive:${device.id}',
          _encodeDriveScan(device, completedScan),
        );
        if (_isHomeVisible) {
          await FilesystemCache.instance.markValueUsed(
            'homeDrive:${device.id}',
          );
        }
      }
      if (!mounted) return;
      await _persistHomeCategoryTotals(scanDevices);
      final appsSize = await appsSizeFuture;
      if (appsSize != null) {
        await FilesystemCache.instance.saveValue('homeAppsTotal', {
          'bytes': appsSize,
        });
      }
      final categorySizes = _homeCategorySizes(categoryDevices, appsSize);
      final recentFiles = _mergeRecentFiles(
        recentDevices.map((device) => _driveScans[device.id]),
        showHiddenFiles: ref.read(appSettingsProvider).showHiddenFilesInRecent,
        showNomediaFiles: ref
            .read(appSettingsProvider)
            .showNomediaFilesInRecent,
        includeAndroidFolderFiles: ref
            .read(appSettingsProvider)
            .showAndroidFolderFilesInRecent,
        blacklistedPaths: ref.read(appSettingsProvider).blacklistedPaths,
        whitelistedPaths: ref.read(appSettingsProvider).whitelistedPaths,
      );
      await _removeMissingQuickAccessItems();
      if (!mounted) return;
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
    } on RefreshCancelled {
      _cancelScanDisplayTimer();
    } catch (error) {
      debugPrint('Home storage refresh failed: $error');
      if (mounted) {
        setState(() {
          _scanLoading = false;
          _scanError = _driveScans.isEmpty
              ? 'Could not scan storage: $error'
              : null;
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

  Map<String, String?> _homeCategorySizes(
    List<StorageDevice> categoryDevices,
    int? appsSize,
  ) {
    return {
      for (final category in const [
        'Downloads',
        'Documents',
        'Images',
        'Videos',
        'Audio',
        'Archives',
      ])
        category: category == 'Downloads'
            ? _categoryBytesForDrive('internal', category) == null
                  ? null
                  : formatBytes(_categoryBytesForDrive('internal', category)!)
            : _sumCategoryBytes(categoryDevices, category),
      'Apps': appsSize == null
          ? (_appsSizeError == null ? null : 'Unavailable')
          : formatBytes(appsSize),
    };
  }

  Future<void> _removeMissingQuickAccessItems() async {
    final quickAccessController = ref.read(quickAccessProvider.notifier);
    try {
      await quickAccessController.ready;
      final items = ref.read(quickAccessProvider).asData?.value ?? const [];
      final missingPaths = <String>[];
      for (final item in items) {
        if (await FileSystemEntity.type(item.path) ==
            FileSystemEntityType.notFound) {
          missingPaths.add(item.path);
          FileChangeNotifier.instance.reportMissing(item.path);
        }
      }
      if (missingPaths.isNotEmpty) {
        await quickAccessController.deleteAll(missingPaths);
      }
    } catch (error) {
      debugPrint('Could not remove missing Quick Access items: $error');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not validate Quick Access items: $error'),
          ),
        );
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
    required bool refreshRecent,
    required bool showHiddenFiles,
    required bool showNomediaFiles,
    required bool hideAndroidFoldersInCategoryPages,
    required List<String> blacklistedPaths,
    required List<String> whitelistedPaths,
  }) async {
    final result = await compute<Map<String, Object?>, Map<String, Object?>>(
      scanHomeStorageDrive,
      {
        'driveId': device.id,
        'rootPath': device.path,
        'refreshRecent': refreshRecent,
        'showHiddenFiles': showHiddenFiles,
        'showNomediaFiles': showNomediaFiles,
        'hideAndroidFolders': hideAndroidFoldersInCategoryPages,
        'blacklistedPaths': blacklistedPaths,
        'whitelistedPaths': whitelistedPaths,
        'extensions': {
          for (final category in categories)
            category.name: category.extensions
                .map(FileTypeCategory.normalizeExtension)
                .toList(growable: false),
        },
      },
    );
    final decoded = _decodeDriveScan(result);
    if (decoded == null) {
      throw const FormatException('Home storage scan returned invalid data.');
    }
    return decoded;
  }

  String _homeScanSettingsSignature() {
    final settings = ref.read(appSettingsProvider);
    return jsonEncode({
      'extensions': ref
          .read(fileTypeCategoriesProvider)
          .map(
            (category) => [
              category.name,
              category.extensions.toList()..sort(),
            ],
          )
          .toList(),
      'showHiddenFiles': settings.showHiddenFiles,
      'showNomediaFiles': settings.showNomediaFiles,
      'hideAndroidFolders': settings.hideAndroidFoldersInCategoryPages,
      'blacklistedPaths': settings.blacklistedPaths,
      'whitelistedPaths': settings.whitelistedPaths,
    });
  }

  String _homeCategoryTotalsSignature() => _homeScanSettingsSignature();

  Future<void> _persistHomeCategoryTotals(List<StorageDevice> devices) async {
    for (final device in devices) {
      final scan = _driveScans[device.id];
      if (scan != null) {
        _cachedCategoryBytesByDrive[device.id] = scan.categoryBytes;
      }
    }
    await FilesystemCache.instance.saveValue('homeCategoryTotals', {
      'volumeIds': _cachedCategoryBytesByDrive.keys.toList(growable: false),
      'settingsSignature': _homeCategoryTotalsSignature(),
      'totalsByVolume': _cachedCategoryBytesByDrive,
    });
  }

  Map<String, Object?> _encodeDriveScan(
    StorageDevice device,
    _DriveScanData data,
  ) => {
    'volumeId': device.id,
    'rootPath': device.path,
    'settingsSignature': _homeScanSettingsSignature(),
    'weeklyRecent': data.weeklyRecent.map(_encodeRecentFile).toList(),
    'overallRecent': data.overallRecent.map(_encodeRecentFile).toList(),
    'categoryBytes': data.categoryBytes,
    'directoryModifiedMilliseconds': data.directoryModifiedMilliseconds,
    'directoryStampsComplete': data.directoryStampsComplete,
  };

  Map<String, Object?> _encodeRecentFile(_RecentFile file) => {
    'path': file.path,
    'name': file.name,
    'driveId': file.driveId,
    'modified': file.modified.millisecondsSinceEpoch,
    'relativePath': file.relativePath,
    'isHidden': file.isHidden,
    'isInsideNomedia': file.isInsideNomedia,
    'isInsideAndroidFolder': file.isInsideAndroidFolder,
    'video': file.video == null
        ? null
        : {
            'driveId': file.video!.driveId,
            'relativePath': file.video!.relativePath,
            'name': file.video!.name,
            'extension': file.video!.extension,
            'size': file.video!.size,
            'modified': file.video!.modified.millisecondsSinceEpoch,
            'isHidden': file.video!.isHidden,
            'isInsideNomedia': file.video!.isInsideNomedia,
          },
  };

  _DriveScanData? _decodeDriveScan(Map<String, Object?> raw) {
    try {
      List<_RecentFile> decodeRecent(Object? value) => (value as List)
          .map((item) {
            final map = Map<String, Object?>.from(item as Map);
            final videoRaw = map['video'];
            final videoMap = videoRaw is Map
                ? Map<String, Object?>.from(videoRaw)
                : null;
            final video = videoMap == null
                ? null
                : VideoFile(
                    driveId: videoMap['driveId']! as String,
                    relativePath: videoMap['relativePath']! as String,
                    name: videoMap['name']! as String,
                    extension: videoMap['extension']! as String,
                    size: videoMap['size']! as int,
                    modified: DateTime.fromMillisecondsSinceEpoch(
                      videoMap['modified']! as int,
                    ),
                    isHidden: videoMap['isHidden']! as bool,
                    isInsideNomedia: videoMap['isInsideNomedia']! as bool,
                  );
            return _RecentFile(
              path: map['path']! as String,
              name: map['name']! as String,
              driveId: map['driveId']! as String,
              modified: DateTime.fromMillisecondsSinceEpoch(
                map['modified']! as int,
              ),
              relativePath: map['relativePath']! as String,
              video: video,
              isHidden: map['isHidden'] == true,
              isInsideNomedia: map['isInsideNomedia'] == true,
              isInsideAndroidFolder: map['isInsideAndroidFolder'] == true,
            );
          })
          .toList(growable: false);

      final rawBytes = Map<String, Object?>.from(raw['categoryBytes']! as Map);
      final rawDirectoryStamps = raw['directoryModifiedMilliseconds'];
      return _DriveScanData(
        weeklyRecent: decodeRecent(raw['weeklyRecent']),
        overallRecent: decodeRecent(raw['overallRecent']),
        categoryBytes: {
          for (final entry in rawBytes.entries) entry.key: entry.value as int?,
        },
        directoryModifiedMilliseconds: rawDirectoryStamps is Map
            ? {
                for (final entry in rawDirectoryStamps.entries)
                  if (entry.key is String && entry.value is int)
                    entry.key as String: entry.value as int,
              }
            : const {},
        directoryStampsComplete: raw['directoryStampsComplete'] == true,
      );
    } on Object catch (error) {
      debugPrint('[HomePage] Invalid cached drive scan: $error');
      return null;
    }
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

  String? _sumCategoryBytes(Iterable<StorageDevice> devices, String category) {
    var total = 0;
    var found = false;
    for (final device in devices) {
      found = true;
      final bytes = _categoryBytesForDrive(device.id, category);
      if (bytes == null) return null;
      total += bytes;
    }
    return found ? formatBytes(total) : null;
  }

  int? _categoryBytesForDrive(String driveId, String category) =>
      _driveScans[driveId]?.categoryBytes[category] ??
      _cachedCategoryBytesByDrive[driveId]?[category];

  Map<String, int?> _decodeCategoryByteMap(Object? raw) {
    if (raw is! Map) return const {};
    return {
      for (final entry in raw.entries)
        if (entry.key is String && (entry.value == null || entry.value is int))
          entry.key as String: entry.value as int?,
    };
  }

  Map<String, Map<String, int?>> _decodeCategoryTotals(Object? raw) {
    if (raw is! Map) return const {};
    return {
      for (final entry in raw.entries)
        if (entry.key is String && entry.value is Map)
          entry.key as String: _decodeCategoryByteMap(entry.value),
    };
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

  List<_RecentFile> _mergeRecentFiles(
    Iterable<_DriveScanData?> scans, {
    required bool showHiddenFiles,
    required bool showNomediaFiles,
    required bool includeAndroidFolderFiles,
    required List<String> blacklistedPaths,
    required List<String> whitelistedPaths,
  }) {
    final available = scans.whereType<_DriveScanData>().toList();
    final recent = available
        .expand((scan) => scan.weeklyRecent)
        .where(
          (file) =>
              (showHiddenFiles || !file.isHidden) &&
              (showNomediaFiles || !file.isInsideNomedia) &&
              (includeAndroidFolderFiles || !file.isInsideAndroidFolder) &&
              FileVisibility.shouldShow(
                path: file.path,
                isDirectory: false,
                showHiddenFiles: showHiddenFiles,
                blacklistedPaths: blacklistedPaths,
                whitelistedPaths: whitelistedPaths,
              ),
        )
        .toList();
    final weekly = recent..sort((a, b) => b.modified.compareTo(a.modified));
    if (weekly.isNotEmpty) return weekly.take(100).toList();
    final overall =
        available
            .expand((scan) => scan.overallRecent)
            .where(
              (file) =>
                  (showHiddenFiles || !file.isHidden) &&
                  (showNomediaFiles || !file.isInsideNomedia) &&
                  (includeAndroidFolderFiles || !file.isInsideAndroidFolder) &&
                  FileVisibility.shouldShow(
                    path: file.path,
                    isDirectory: false,
                    showHiddenFiles: showHiddenFiles,
                    blacklistedPaths: blacklistedPaths,
                    whitelistedPaths: whitelistedPaths,
                  ),
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
          directoryModifiedMilliseconds:
              driveScan.directoryModifiedMilliseconds,
          directoryStampsComplete: driveScan.directoryStampsComplete,
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
          previous?.showNomediaFilesInRecent != next.showNomediaFilesInRecent ||
          previous?.blacklistedPaths != next.blacklistedPaths ||
          previous?.whitelistedPaths != next.whitelistedPaths) {
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
    final fileTypeCategories = ref.watch(fileTypeCategoriesProvider);
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
                    data: (items) {
                      final settings = ref.watch(appSettingsProvider);
                      final visibleItems = items
                          .where(
                            (item) => FileVisibility.shouldShow(
                              path: item.path,
                              isDirectory: item.isDirectory,
                              showHiddenFiles: settings.showHiddenFiles,
                              blacklistedPaths: settings.blacklistedPaths,
                              whitelistedPaths: settings.whitelistedPaths,
                            ),
                          )
                          .toList(growable: false);
                      return visibleItems.isEmpty
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
                                visibleItems,
                                fileTypeCategories,
                              ),
                            );
                    },
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
    List<FileTypeCategory> fileTypeCategories,
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
            leading: _homeFileLeading(
              path: item.isDirectory ? null : item.path,
              extension: item.isDirectory
                  ? ''
                  : _fileExtensionForDisplay(item.name),
              fileTypeCategories: fileTypeCategories,
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
            onTap: () =>
                _openQuickAccess(context, ref, item, fromQuickAccess: true),
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
    final fileTypeCategories = ref.watch(fileTypeCategoriesProvider);
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
            leading: _homeFileLeading(
              path: file.path,
              extension: _fileExtensionForDisplay(file.name),
              video: file.video,
              fileTypeCategories: fileTypeCategories,
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

  Widget _homeFileLeading({
    required String? path,
    required String extension,
    required List<FileTypeCategory> fileTypeCategories,
    VideoFile? video,
  }) {
    final isImage =
        path != null &&
        FileTypeCategory.categoryForExtension(
              extension,
              categories: fileTypeCategories,
            ) ==
            'Image';
    if (!isImage) {
      return FileTypeIcon(
        extension: extension,
        path: path,
        video: video,
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: 36,
        height: 36,
        child: ImageFilePreview(
          path: path,
          fit: BoxFit.cover,
          loadingBuilder: (_) => FileTypeIcon(extension: extension, size: 24),
          errorBuilder: (_, _, _) => FileTypeIcon(extension: extension, size: 24),
        ),
      ),
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
      FileChangeNotifier.instance.reportMissing(file.path);
      setState(() {
        _displayedRecentFiles = _displayedRecentFiles
            .where((candidate) => candidate.path != file.path)
            .toList();
        _pendingRecentFiles = _pendingRecentFiles
            ?.where((candidate) => candidate.path != file.path)
            .toList();
      });
      widget.onRecentFileMissing(file);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '"${file.name}" is no longer available. Removed from Recent.',
          ),
        ),
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
    QuickAccessItem item, {
    String? successMessage,
  }) async {
    try {
      await ref.read(quickAccessProvider.notifier).delete(item.path);
      if (mounted) {
        setState(() => _orderedPaths.remove(item.path));
      }
      if (successMessage != null && context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(successMessage)));
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
    bool fromQuickAccess = false,
  }) async {
    if (fromQuickAccess) {
      try {
        final type = await FileSystemEntity.type(item.path);
        if (!context.mounted) return;
        if (type == FileSystemEntityType.notFound) {
          FileChangeNotifier.instance.reportMissing(item.path);
          await _removeQuickAccess(
            context,
            ref,
            item,
            successMessage:
                '"${item.name}" is no longer available. Removed from Quick Access.',
          );
          return;
        }
      } catch (error) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not verify "${item.name}": $error')),
          );
        }
        return;
      }
    }
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
    if (extension.toLowerCase() == '.pdf') {
      if (!context.mounted) return;
      await openPdfFile(
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
        if (savedDefault.isAudioPlayer) {
          openAudioFile(ref, path: item.path);
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
    final canUseAudioPlayer = category == 'Audio';

    if (apps.isEmpty &&
        !canUseTextEditor &&
        !canUseImageViewer &&
        !canUseArchiveManager &&
        !canUseAudioPlayer) {
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
          if (canUseAudioPlayer)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(
                dialogContext,
                OpenWithApp(
                  name: 'Audio Player (built-in)',
                  packageName: DefaultFileApp.audioPlayerHandlerId,
                  mimeType: 'audio/*',
                  iconBytes: builtInIcon,
                ),
              ),
              child: Row(
                children: [
                  _openWithAppIcon(
                    OpenWithApp(
                      name: 'Audio Player (built-in)',
                      packageName: DefaultFileApp.audioPlayerHandlerId,
                      mimeType: 'audio/*',
                      iconBytes: builtInIcon,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Text('Audio Player (built-in)'),
                ],
              ),
            ),
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

    if (selection.packageName == DefaultFileApp.audioPlayerHandlerId) {
      openAudioFile(ref, path: item.path);
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
  final Object _refreshOwner = Object();
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
    RefreshCoordinator.instance.cancelOwner(_refreshOwner);
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
    final persisted = await FilesystemCache.instance.loadValue(
      'availableStorage',
    );
    if (persisted != null && _devices == null) {
      final rawDevices = persisted['devices'];
      if (rawDevices is List) {
        _devices = rawDevices
            .whereType<Map>()
            .map(
              (raw) => StorageDevice(
                id: raw['id']! as String,
                name: raw['name']! as String,
                path: raw['path']! as String,
                usedBytes: raw['usedBytes'] as int?,
                totalBytes: raw['totalBytes'] as int?,
              ),
            )
            .toList(growable: false);
      }
    }
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
      final devices = await RefreshCoordinator.instance
          .run<List<StorageDevice>>(
            scope: 'storage-devices',
            owner: _refreshOwner,
            priority: widget.isActive
                ? RefreshPriority.visiblePage
                : RefreshPriority.openPages,
            work: (token) async {
              token.throwIfCancelled();
              final result = await getStorageRepository().listStorageDevices();
              return RefreshWorkResult(result);
            },
          );
      if (!mounted || requestId != _loadRequestId) return;
      setState(() {
        if (!_sameStorageDevices(_devices, devices)) _devices = devices;
        _loading = false;
        _showStaleValues = false;
      });
      await FilesystemCache.instance.saveValue('availableStorage', {
        'volumeIds': devices.map((device) => device.id).toList(),
        'devices': devices
            .map(
              (device) => {
                'id': device.id,
                'name': device.name,
                'path': device.path,
                'usedBytes': device.usedBytes,
                'totalBytes': device.totalBytes,
              },
            )
            .toList(),
      });
      _refreshDisplayTimer?.cancel();
      widget.onDriveCountChanged(devices.length);
    } on RefreshCancelled {
      return;
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

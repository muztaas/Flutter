import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../domain/entities/storage_device.dart';
import '../../domain/utils/storage_display_name.dart';
import '../../presentation/home/home_page.dart';
import '../../presentation/apps/apps_tab.dart';
import '../../presentation/storage/storage_tab.dart';
import '../../presentation/text_editor/text_editor_tab.dart';
import '../../presentation/image_viewer/image_viewer_tab.dart';
import '../../presentation/pdf_viewer/pdf_viewer_tab.dart';
import '../../presentation/spreadsheet_viewer/csv_viewer_tab.dart';
import '../../presentation/spreadsheet_viewer/xlsx_viewer_tab.dart';
import '../../presentation/document_viewer/docx_viewer_tab.dart';
import '../../presentation/presentation_viewer/pptx_viewer_tab.dart';
import '../../presentation/archive/archive_manager_page.dart';
import '../../presentation/video/video_tab.dart';
import '../../presentation/audio_player/audio_player_tab.dart';
import '../../domain/repositories/audio_player_repository.dart';

int _tabInstanceSequence = 0;

String _newTabInstanceId() =>
    'tab-${DateTime.now().microsecondsSinceEpoch}-${_tabInstanceSequence++}';

class TabEntry {
  final String id;
  final String sessionId;
  String title;
  final String? initialImagePath;
  final List<String>? initialImagePaths;
  String? currentImagePath;
  // builder used to create the page widget when requested by the UI
  final Widget Function() pageBuilder;
  final Widget? Function()? bottomPanelBuilder;
  final double Function()? bottomPanelHeightBuilder;
  // optional handler that should return true if it handled the back action (i.e., consumed it)
  final Future<bool> Function()? onWillPop;
  final bool Function()? hasUnsavedChanges;
  final Future<bool> Function(BuildContext context)? onCloseRequest;
  final Future<void> Function()? onTabClosing;
  final Future<bool> Function()? saveChanges;
  TabEntry? returnToTab;
  final bool isImageViewer;
  final bool isPdfViewer;
  final bool isCsvViewer;
  final bool isXlsxViewer;
  final bool isDocxViewer;
  final bool isPptxViewer;
  final bool isArchiveManager;
  String? archivePath;
  String archiveFolder;
  String? storagePath;
  String? storageAnchorPath;
  String? driveId;
  String? driveRoot;
  bool imageOnly;
  bool documentOnly;
  bool audioOnly;
  bool archiveOnly;
  bool isDeferred;
  bool isFullscreen = false;
  bool isPdfSystemFullscreen = false;
  bool isImageZoomed = false;
  bool isPdfZoomed = false;
  bool isCsvZoomed = false;
  bool isPptxZoomed = false;
  String? pdfPath;
  String? csvPath;
  String? xlsxPath;
  String? docxPath;
  String? pptxPath;
  String? pdfVolumeId;
  String? pdfRelativePath;
  bool pdfProgressEnabled = true;
  final VoidCallback? onPdfProgressDeleted;
  final bool isVideoPage;
  final bool isAudioPlayer;
  String? audioPath;
  Set<String> audioExtensions;
  List<String>? audioQueuePaths;
  String? videoDriveId;
  String videoRelativePath;
  TabEntry({
    required this.id,
    required this.title,
    required this.pageBuilder,
    String? sessionId,
    this.storagePath,
    this.storageAnchorPath,
    this.driveId,
    this.driveRoot,
    this.imageOnly = false,
    this.documentOnly = false,
    this.audioOnly = false,
    this.archiveOnly = false,
    this.isDeferred = false,
    this.bottomPanelBuilder,
    this.bottomPanelHeightBuilder,
    this.onWillPop,
    this.hasUnsavedChanges,
    this.onCloseRequest,
    this.onTabClosing,
    this.onPdfProgressDeleted,
    this.pdfPath,
    this.csvPath,
    this.xlsxPath,
    this.docxPath,
    this.pptxPath,
    this.pdfVolumeId,
    this.pdfRelativePath,
    this.pdfProgressEnabled = true,
    this.saveChanges,
    this.returnToTab,
    this.isImageViewer = false,
    this.isPdfViewer = false,
    this.isCsvViewer = false,
    this.isXlsxViewer = false,
    this.isDocxViewer = false,
    this.isPptxViewer = false,
    this.isArchiveManager = false,
    this.archivePath,
    this.archiveFolder = '',
    this.isVideoPage = false,
    this.isAudioPlayer = false,
    this.audioPath,
    this.audioExtensions = const {},
    this.audioQueuePaths,
    this.videoDriveId,
    this.videoRelativePath = '',
    this.initialImagePath,
    this.initialImagePaths,
    this.currentImagePath,
  }) : sessionId = sessionId ?? _newTabInstanceId();
}

class TabsManager extends ChangeNotifier {
  static const int maxOpenTabs = 22;
  final ChangeNotifier copyPanelNotifier = ChangeNotifier();
  late final StorageCopySession copySession = StorageCopySession(
    onChanged: copyPanelNotifier.notifyListeners,
  );

  TabsManager._internal() {
    _pageController = PageController(initialPage: 0);
    _tabs = [
      TabEntry(
        id: 'home',
        title: 'Home',
        sessionId: 'home',
        pageBuilder: () => const HomePage(),
      ),
    ];
    _selected = 0;
  }

  static final TabsManager _instance = TabsManager._internal();
  static TabsManager get instance => _instance;

  late PageController _pageController;
  late List<TabEntry> _tabs;
  late int _selected;
  int? _pendingProgrammaticPage;
  bool _restoreAttempted = false;
  bool _restoring = false;
  bool _sessionReady = false;
  Timer? _persistDebounce;
  Future<void> _persistQueue = Future<void>.value();
  String? _pendingNotice;
  List<StorageDevice> _availableDevices = const [];

  PageController get pageController => _pageController;
  List<TabEntry> get tabs => List.unmodifiable(_tabs);
  int get selectedIndex => _selected;
  bool get restoreAttempted => _restoreAttempted;
  String? takePendingNotice() {
    final notice = _pendingNotice;
    _pendingNotice = null;
    return notice;
  }

  void updateAvailableStorageDevices(List<StorageDevice> devices) {
    _availableDevices = List.unmodifiable(devices);
  }

  void focusTabById(String id) {
    final index = _tabs.indexWhere((tab) => tab.id == id);
    if (index >= 0) goTo(index);
  }

  Future<void> openStartupPage(String pageId) async {
    if (pageId == 'default' || pageId == 'home') {
      goTo(0);
      return;
    }
    if (pageId == 'video') {
      openVideoTab();
      return;
    }
    if (pageId == 'apps') {
      openAppsTab();
      return;
    }
    final devices = _availableDevices;
    if (pageId == 'images' ||
        pageId == 'documents' ||
        pageId == 'audio' ||
        pageId == 'archives' ||
        pageId == 'downloads' ||
        pageId == 'internal') {
      final internal = devices
          .where((device) => device.id == 'internal')
          .firstOrNull;
      if (internal == null) return;
      if (pageId == 'downloads') {
        final downloadsPath = await _downloadsPath(internal.path);
        if (downloadsPath != null)
          openStorageTab(downloadsPath, title: 'Downloads');
      } else if (pageId == 'images') {
        openStorageTab(internal.path, title: 'Images', imageOnly: true);
      } else if (pageId == 'documents') {
        openStorageTab(internal.path, title: 'Documents', documentOnly: true);
      } else if (pageId == 'audio') {
        openStorageTab(internal.path, title: 'Audio', audioOnly: true);
      } else if (pageId == 'archives') {
        openStorageTab(internal.path, title: 'Archives', archiveOnly: true);
      } else {
        openStorageTab(internal.path);
      }
      return;
    }
    if (pageId.startsWith('drive:')) {
      final driveId = pageId.substring('drive:'.length);
      final drive = devices.where((device) => device.id == driveId).firstOrNull;
      if (drive != null) openStorageTab(drive.path, title: drive.name);
    }
  }

  Future<String?> _downloadsPath(String rootPath) async {
    try {
      await for (final entry in Directory(rootPath).list(followLinks: false)) {
        if (entry is Directory &&
            entry.uri.pathSegments
                    .where((segment) => segment.isNotEmpty)
                    .last
                    .toLowerCase() ==
                'download') {
          return entry.path;
        }
      }
    } on FileSystemException catch (error) {
      debugPrint('Could not locate the Downloads folder: $error');
    }
    return null;
  }

  Future<List<String>> restorePersistedTabs({
    List<StorageDevice>? devices,
    bool closeAllTabsOnExit = false,
  }) async {
    if (_restoreAttempted) return const [];
    final availableDevices = devices ?? const <StorageDevice>[];
    _availableDevices = List.unmodifiable(availableDevices);
    final failures = <String>[];
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('tabs.open');
    if (closeAllTabsOnExit) {
      _restoreAttempted = true;
      _sessionReady = true;
      await flushPersistedTabs();
      return failures;
    }
    if (saved == null) {
      _restoreAttempted = true;
      _sessionReady = true;
      return failures;
    }

    _restoring = true;
    try {
      final decoded = jsonDecode(saved);
      if (decoded is! Map) {
        throw const FormatException('Saved tab session is not an object');
      }
      final data = Map<String, dynamic>.from(decoded);
      final rawItemsValue = data['items'];
      final rawItems = rawItemsValue is List ? rawItemsValue : const [];
      if (rawItemsValue != null && rawItemsValue is! List) {
        failures.add('Saved tab records were invalid and were skipped.');
      }
      final restoredTabs = <TabEntry>[_tabs.first];
      final savedIdToTab = <String, TabEntry>{'home': _tabs.first};
      final legacyIndexToTab = <int, TabEntry>{0: _tabs.first};
      final pendingOrigins = <TabEntry, String?>{};
      final pendingLegacyOrigins = <TabEntry, int?>{};
      var imageViewerCount = 0;
      for (var itemIndex = 0; itemIndex < rawItems.length; itemIndex++) {
        final raw = rawItems[itemIndex];
        if (raw is! Map) {
          failures.add('A tab record was invalid.');
          continue;
        }
        final Map<String, dynamic> item;
        try {
          item = Map<String, dynamic>.from(raw);
        } on TypeError {
          failures.add('A tab record had invalid fields and was skipped.');
          debugPrint('[TabsManager] Dropping saved tab with non-string keys.');
          continue;
        }
        final type = item['type'];
        final validationError = _validateSavedTabRecord(item);
        if (validationError != null) {
          failures.add('${_savedTabLabel(item)}: $validationError');
          debugPrint(
            '[TabsManager] Dropping malformed saved tab record: $validationError',
          );
          continue;
        }
        if (type == 'audioPlayer') continue;
        final titleValue = item['title'];
        final title = titleValue is String ? titleValue : null;
        if (titleValue != null && title == null) {
          debugPrint(
            '[TabsManager] Repairing a saved tab with a non-string title.',
          );
        }
        final savedTabId = item['tabId'];
        var tabId = savedTabId is String && savedTabId.trim().isNotEmpty
            ? savedTabId
            : _newTabInstanceId();
        if (savedTabId != null && tabId != savedTabId) {
          debugPrint(
            '[TabsManager] Replacing an invalid saved tab identifier.',
          );
        }
        if (savedIdToTab.containsKey(tabId)) {
          debugPrint(
            '[TabsManager] Replacing duplicate saved tab identifier "$tabId".',
          );
          tabId = _newTabInstanceId();
        }
        TabEntry? tab;
        if (type == 'storage' ||
            type == 'imageStorage' ||
            type == 'documentStorage' ||
            type == 'audioStorage' ||
            type == 'archiveStorage') {
          final location = _resolveStorageRecord(
            item,
            availableDevices,
            allowUnresolvedLegacyPath: devices == null,
          );
          if (location == null) {
            failures.add(
              '${title ?? _savedTabLabel(item)}: drive unavailable.',
            );
          } else {
            tab = _createStorageEntry(
              path: location.path,
              title: title,
              imageOnly: type == 'imageStorage',
              documentOnly: type == 'documentStorage',
              audioOnly: type == 'audioStorage',
              archiveOnly: type == 'archiveStorage',
              sessionId: tabId,
              driveId: location.driveId,
              driveRoot: location.driveRoot,
              anchorPath: _resolveStorageAnchor(item, location),
              isDeferred: true,
              restoreRootPath: location.driveRoot,
            );
          }
        } else if (type == 'textEditor' ||
            type == 'imageViewer' ||
            type == 'pdfViewer' ||
            type == 'csvViewer' ||
            type == 'xlsxViewer' ||
            type == 'docxViewer' ||
            type == 'pptxViewer' ||
            type == 'archiveManager') {
          if (type == 'imageViewer' && imageViewerCount >= maxImageViewerTabs) {
            failures.add(
              '${title ?? _savedTabLabel(item)}: image viewer limit reached.',
            );
            continue;
          }
          final filePath = _resolveFileRecord(item, availableDevices);
          if (filePath == null) {
            failures.add(
              '${title ?? _savedTabLabel(item)}: storage drive unavailable.',
            );
            continue;
          }
          var exists = false;
          try {
            exists = await File(filePath).exists();
          } on FileSystemException {
            exists = false;
          }
          if (!exists) {
            failures.add('${title ?? _savedTabLabel(item)}: file not found.');
            continue;
          }
          if (type == 'textEditor') {
            tab = _createTextEditorEntry(
              filePath,
              sessionId: tabId,
              isDeferred: true,
            );
          } else if (type == 'imageViewer') {
            imageViewerCount++;
            tab = _createImageViewerEntry(
              filePath,
              sessionId: tabId,
              isDeferred: true,
            );
            pendingOrigins[tab] = item['originTabId'] as String?;
            pendingLegacyOrigins[tab] = item['originTabIndex'] as int?;
          } else if (type == 'pdfViewer') {
            tab = _createPdfViewerEntry(
              filePath,
              title: _validSavedTitle(title),
              sessionId: tabId,
              isDeferred: true,
            );
            pendingOrigins[tab] = item['originTabId'] as String?;
            pendingLegacyOrigins[tab] = item['originTabIndex'] as int?;
          } else if (type == 'csvViewer') {
            tab = _createCsvViewerEntry(
              filePath,
              title: _validSavedTitle(title),
              sessionId: tabId,
              isDeferred: true,
            );
            pendingOrigins[tab] = item['originTabId'] as String?;
            pendingLegacyOrigins[tab] = item['originTabIndex'] as int?;
          } else if (type == 'xlsxViewer') {
            tab = _createXlsxViewerEntry(
              filePath,
              title: _validSavedTitle(title),
              sessionId: tabId,
              isDeferred: true,
            );
            pendingOrigins[tab] = item['originTabId'] as String?;
            pendingLegacyOrigins[tab] = item['originTabIndex'] as int?;
          } else if (type == 'docxViewer') {
            tab = _createDocxViewerEntry(
              filePath,
              title: _validSavedTitle(title),
              sessionId: tabId,
              isDeferred: true,
            );
            pendingOrigins[tab] = item['originTabId'] as String?;
            pendingLegacyOrigins[tab] = item['originTabIndex'] as int?;
          } else if (type == 'pptxViewer') {
            tab = _createPptxViewerEntry(
              filePath,
              title: _validSavedTitle(title),
              sessionId: tabId,
              isDeferred: true,
            );
            pendingOrigins[tab] = item['originTabId'] as String?;
            pendingLegacyOrigins[tab] = item['originTabIndex'] as int?;
          } else {
            tab = _createArchiveManagerEntry(
              filePath,
              title: _validSavedTitle(title),
              initialFolder: item['archiveFolder'] as String? ?? '',
              sessionId: tabId,
              isDeferred: true,
            );
            pendingOrigins[tab] = item['originTabId'] as String?;
          }
        } else if (type == 'apps') {
          late final TabEntry appsTab;
          appsTab = TabEntry(
            id: 'apps',
            title: 'Apps',
            sessionId: tabId,
            isDeferred: true,
            pageBuilder: () => appsTab.isDeferred
                ? const _DeferredRestoredTab()
                : const AppsTab(),
          );
          tab = appsTab;
        } else if (type == 'video') {
          final driveId = item['driveId'] as String? ?? 'internal';
          final drive = _deviceById(driveId, availableDevices);
          if (drive == null) {
            failures.add('${title ?? 'Videos'}: drive unavailable.');
          } else {
            final relativePath = item['relativePath'] as String? ?? '';
            if (relativePath
                .replaceAll('\\', '/')
                .split('/')
                .any((segment) => segment == '.' || segment == '..')) {
              failures.add(
                '${title ?? 'Videos'}: saved folder path is invalid.',
              );
            } else {
              tab = _createVideoEntry(
                sessionId: tabId,
                driveId: drive.id,
                relativePath: relativePath,
                isDeferred: true,
              );
            }
          }
        } else {
          failures.add(
            '${title ?? _savedTabLabel(item)}: unsupported tab type.',
          );
        }

        if (tab == null) continue;
        if (restoredTabs.length >= maxOpenTabs) {
          failures.add('${tab.title}: open-tab limit reached.');
          continue;
        }
        restoredTabs.add(tab);
        savedIdToTab[tab.sessionId] = tab;
        legacyIndexToTab[itemIndex + 1] = tab;
      }

      for (final entry in pendingOrigins.entries) {
        final origin = entry.value == null ? null : savedIdToTab[entry.value];
        final legacyIndex = pendingLegacyOrigins[entry.key];
        entry.key.returnToTab =
            origin ??
            (legacyIndex == null ? null : legacyIndexToTab[legacyIndex]) ??
            restoredTabs.first;
      }

      final savedActiveId = data['selectedTabId'] is String
          ? data['selectedTabId'] as String
          : null;
      final legacySelectedIndex = data['selectedIndex'] is int
          ? data['selectedIndex'] as int
          : null;
      if (data['selectedTabId'] != null && savedActiveId == null ||
          data['selectedIndex'] != null && legacySelectedIndex == null) {
        debugPrint(
          '[TabsManager] Ignoring malformed saved tab selection metadata.',
        );
      }
      final activeTab = savedActiveId != null
          ? savedIdToTab[savedActiveId]
          : legacySelectedIndex == null
          ? restoredTabs.first
          : legacyIndexToTab[legacySelectedIndex] ?? restoredTabs.first;
      final selectedTab = activeTab ?? restoredTabs.first;
      for (final tab in restoredTabs.skip(1)) {
        tab.isDeferred = !identical(tab, selectedTab);
      }

      _tabs = restoredTabs;
      _selected = _tabs.indexOf(selectedTab);
      _pendingProgrammaticPage = null;
      _pageController.dispose();
      _pageController = PageController(initialPage: _selected);
      _restoreAttempted = true;
      _sessionReady = true;
      _restoring = false;
      notifyListeners();
      _schedulePersistTabs();
    } catch (error) {
      _restoring = false;
      _restoreAttempted = true;
      _sessionReady = true;
      failures.add('Saved session could not be read: $error');
      _schedulePersistTabs();
    }
    return failures;
  }

  static const int maxImageViewerTabs = 5;

  String? _validateSavedTabRecord(Map<String, dynamic> item) {
    final type = item['type'];
    const supportedTypes = {
      'storage',
      'imageStorage',
      'documentStorage',
      'audioStorage',
      'archiveStorage',
      'textEditor',
      'imageViewer',
      'pdfViewer',
      'csvViewer',
      'xlsxViewer',
      'docxViewer',
      'pptxViewer',
      'archiveManager',
      'apps',
      'video',
      'audioPlayer',
    };
    if (type is! String || !supportedTypes.contains(type)) {
      return 'unsupported tab type';
    }

    for (final key in const ['driveId', 'relativePath', 'path']) {
      final value = item[key];
      if (value != null && value is! String) {
        return 'invalid $key';
      }
    }
    if (type == 'storage' ||
        type == 'imageStorage' ||
        type == 'documentStorage' ||
        type == 'audioStorage' ||
        type == 'archiveStorage') {
      final driveId = item['driveId'];
      final path = item['path'];
      if ((driveId == null || (driveId as String).trim().isEmpty) &&
          (path == null || (path as String).trim().isEmpty)) {
        return 'missing storage location';
      }
    } else if (type == 'textEditor' ||
        type == 'imageViewer' ||
        type == 'pdfViewer' ||
        type == 'csvViewer' ||
        type == 'xlsxViewer' ||
        type == 'docxViewer' ||
        type == 'pptxViewer' ||
        type == 'archiveManager') {
      final driveId = item['driveId'];
      final path = item['path'];
      if ((driveId == null || (driveId as String).trim().isEmpty) &&
          (path == null || (path as String).trim().isEmpty)) {
        return 'missing file location';
      }
      if (driveId != null) {
        final relativePath = item['relativePath'] as String?;
        if (relativePath == null || relativePath.trim().isEmpty) {
          return 'missing file path';
        }
      }
      if (type == 'archiveManager') {
        final folder = item['archiveFolder'];
        if (folder != null && folder is! String) {
          return 'invalid folder inside archive';
        }
        if (folder is String &&
            folder
                .replaceAll('\\', '/')
                .split('/')
                .any((segment) => segment == '.' || segment == '..')) {
          return 'invalid folder inside archive';
        }
      }
    } else if (type == 'video') {
      final driveId = item['driveId'];
      if (driveId != null && (driveId as String).trim().isEmpty) {
        return 'invalid drive identifier';
      }
    }

    final originTabId = item['originTabId'];
    if (originTabId != null && originTabId is! String) {
      return 'invalid origin tab identifier';
    }
    final originTabIndex = item['originTabIndex'];
    if (originTabIndex != null && originTabIndex is! int) {
      return 'invalid origin tab index';
    }
    return null;
  }

  String _savedTabLabel(Map<String, dynamic> item) {
    final pathValue = item['path'];
    if (pathValue is! String) return 'Tab';
    final path = pathValue;
    final isNumericRoot = RegExp(
      r'^\d+$',
    ).hasMatch(_lastPathSegment(path, fallback: ''));
    return storageDisplayName(
      path: path,
      isDriveRoot: isNumericRoot,
      fallback: 'Tab',
    );
  }

  String _normalizePath(String path) =>
      path.replaceAll('\\', '/').replaceFirst(RegExp(r'/+$'), '');

  StorageTabLocation? _resolveStorageRecord(
    Map<String, dynamic> item,
    List<StorageDevice> devices, {
    bool allowUnresolvedLegacyPath = false,
  }) {
    final driveId = item['driveId'] as String?;
    final root = driveId == null ? null : _deviceById(driveId, devices);
    if (root != null) {
      final relativePath = item['relativePath'] as String? ?? '';
      final path = _joinDrivePath(root.path, relativePath);
      if (path == null) return null;
      return StorageTabLocation(
        path: path,
        driveId: root.id,
        driveRoot: root.path,
      );
    }
    if (driveId != null) return null;

    final legacyPath = item['path'] as String?;
    if (legacyPath == null) return null;
    final legacyDevice = _deviceForAbsolutePath(legacyPath, devices);
    if (legacyDevice == null) {
      if (!allowUnresolvedLegacyPath || devices.isNotEmpty) return null;
      return StorageTabLocation(
        path: legacyPath,
        driveId: 'path:${_normalizePath(legacyPath)}',
        driveRoot: legacyPath,
      );
    }
    return StorageTabLocation(
      path: legacyPath,
      driveId: legacyDevice.id,
      driveRoot: legacyDevice.path,
    );
  }

  String _resolveStorageAnchor(
    Map<String, dynamic> item,
    StorageTabLocation location,
  ) {
    final relativeAnchor = item['anchorRelativePath'];
    if (relativeAnchor is String) {
      final anchor = _joinDrivePath(location.driveRoot, relativeAnchor);
      if (anchor != null) return anchor;
    }
    if (item['title'] == 'Downloads') {
      var current = Directory(location.path);
      final root = _normalizePath(location.driveRoot);
      while (_normalizePath(current.path) != root) {
        final name = current.uri.pathSegments
            .where((segment) => segment.isNotEmpty)
            .lastOrNull;
        if (name?.toLowerCase() == 'download') return current.path;
        final parent = current.parent;
        if (parent.path == current.path) break;
        current = parent;
      }
    }
    return location.driveRoot;
  }

  String? _resolveFileRecord(
    Map<String, dynamic> item,
    List<StorageDevice> devices,
  ) {
    final driveId = item['driveId'] as String?;
    if (driveId != null) {
      final root = _deviceById(driveId, devices);
      if (root == null) return null;
      final relativePath = item['relativePath'] as String? ?? '';
      return _joinDrivePath(root.path, relativePath);
    }
    return item['path'] as String?;
  }

  StorageDevice? _deviceForAbsolutePath(
    String path,
    List<StorageDevice> devices,
  ) {
    final normalizedPath = _normalizePath(path);
    final matches =
        devices.where((device) {
          final root = _normalizePath(device.path);
          return normalizedPath == root || normalizedPath.startsWith('$root/');
        }).toList()..sort(
          (left, right) => _normalizePath(
            right.path,
          ).length.compareTo(_normalizePath(left.path).length),
        );
    return matches.isEmpty ? null : matches.first;
  }

  StorageDevice? _deviceById(String id, List<StorageDevice> devices) {
    for (final device in devices) {
      if (device.id == id) return device;
    }
    return null;
  }

  String? _joinDrivePath(String rootPath, String relativePath) {
    final relative = relativePath.replaceAll('\\', '/');
    if (relative.startsWith('/') ||
        relative.split('/').any((segment) => segment == '..')) {
      return null;
    }
    if (relative.isEmpty) return rootPath;
    return '$rootPath${rootPath.endsWith(Platform.pathSeparator) ? '' : Platform.pathSeparator}${relative.replaceAll('/', Platform.pathSeparator)}';
  }

  TabEntry _createStorageEntry({
    required String path,
    required String? title,
    required bool imageOnly,
    required bool documentOnly,
    required bool audioOnly,
    required bool archiveOnly,
    required String sessionId,
    required bool isDeferred,
    String? driveId,
    String? driveRoot,
    String? anchorPath,
    String? restoreRootPath,
  }) {
    final key = GlobalKey<StorageTabState>();
    final copySessionOwner = Object();
    final titleDrive =
        (driveId == null ? null : _deviceById(driveId, _availableDevices)) ??
        _deviceForAbsolutePath(path, _availableDevices);
    final isDriveRoot =
        (driveRoot != null &&
            _normalizePath(path) == _normalizePath(driveRoot)) ||
        (titleDrive != null &&
            _normalizePath(path) == _normalizePath(titleDrive.path)) ||
        (titleDrive == null &&
            title == null &&
            RegExp(r'^\d+$').hasMatch(_lastPathSegment(path, fallback: '')));
    final categoryTitle = imageOnly
        ? 'Images'
        : documentOnly
        ? 'Documents'
        : audioOnly
        ? 'Audio'
        : archiveOnly
        ? 'Archives'
        : null;
    final savedTitle = _validSavedTitle(title);
    final resolvedTitle = categoryTitle != null
        ? savedTitle ?? categoryTitle
        : savedTitle ??
              storageDisplayName(
                path: path,
                drive: titleDrive,
                isDriveRoot: isDriveRoot,
                fallback: title,
              );
    late final TabEntry entry;
    entry = TabEntry(
      id: imageOnly
          ? 'imageStorage:$path'
          : documentOnly
          ? 'documentStorage:$path'
          : audioOnly
          ? 'audioStorage:$path'
          : archiveOnly
          ? 'archiveStorage:$path'
          : path,
      title: resolvedTitle,
      sessionId: sessionId,
      storagePath: path,
      storageAnchorPath: anchorPath ?? path,
      driveId: driveId,
      driveRoot: driveRoot,
      imageOnly: imageOnly,
      documentOnly: documentOnly,
      audioOnly: audioOnly,
      archiveOnly: archiveOnly,
      isDeferred: isDeferred,
      pageBuilder: () => entry.isDeferred
          ? const _DeferredRestoredTab()
          : StorageTab(
              key: key,
              searchSessionId: entry.sessionId,
              initialPath: entry.storagePath,
              displayName: entry.title,
              imageOnly: entry.imageOnly,
              documentOnly: entry.documentOnly,
              audioOnly: entry.audioOnly,
              archiveOnly: entry.archiveOnly,
              copySession: copySession,
              copySessionOwner: copySessionOwner,
              initialAnchorPath: entry.storageAnchorPath,
              restoreRootPath: restoreRootPath,
              onPathChanged: (location) =>
                  updateStorageLocation(entry, location),
            ),
      bottomPanelBuilder: () => key.currentState?.buildCopyPanel(),
      bottomPanelHeightBuilder: () => copySession.panelHeight,
      onWillPop: () async {
        final state = key.currentState;
        return state == null ? false : state.handleWillPop();
      },
    );
    return entry;
  }

  TabEntry _createTextEditorEntry(
    String path, {
    required String sessionId,
    required bool isDeferred,
    bool allowNonText = false,
  }) {
    final key = GlobalKey<TextEditorTabState>();
    late final TabEntry entry;
    entry = TabEntry(
      id: 'textEditor:$path',
      title: _lastPathSegment(path, fallback: 'Text Editor'),
      sessionId: sessionId,
      isDeferred: isDeferred,
      pageBuilder: () => entry.isDeferred
          ? const _DeferredRestoredTab()
          : TextEditorTab(key: key, path: path, allowNonText: allowNonText),
      onWillPop: () async {
        final state = key.currentState;
        if (state == null) {
          closeTab(entry);
          return true;
        }
        return state.handleWillPop(onClose: () => closeTab(entry));
      },
      hasUnsavedChanges: () => key.currentState?.hasUnsavedChanges ?? false,
      onCloseRequest: (context) =>
          key.currentState?.confirmClose(context) ?? Future.value(true),
      saveChanges: () =>
          key.currentState?.saveFromClosePrompt() ?? Future.value(false),
    );
    return entry;
  }

  TabEntry _createImageViewerEntry(
    String path, {
    required String sessionId,
    required bool isDeferred,
    List<String>? imagePaths,
    TabEntry? originTab,
  }) {
    late final TabEntry entry;
    entry = TabEntry(
      id: 'imageViewer:$path',
      title: _lastPathSegment(path, fallback: 'Image'),
      sessionId: sessionId,
      isImageViewer: true,
      initialImagePath: path,
      initialImagePaths: imagePaths == null
          ? null
          : List<String>.unmodifiable(imagePaths),
      currentImagePath: path,
      isDeferred: isDeferred,
      returnToTab: originTab,
      pageBuilder: () => entry.isDeferred
          ? const _DeferredRestoredTab()
          : ImageViewerTab(
              initialPath: entry.initialImagePath ?? path,
              initialImagePaths: entry.initialImagePaths,
              currentPath: entry.currentImagePath ?? path,
              isFullscreen: entry.isFullscreen,
              onFullscreenChanged: (isFullscreen) =>
                  setImageViewerFullscreen(entry, isFullscreen),
              onZoomChanged: (isZoomed) =>
                  setImageViewerZoomed(entry, isZoomed),
              onCurrentPathChanged: (currentPath) =>
                  updateImageViewerPath(entry, currentPath),
              onBoundaryHandoff: (direction) =>
                  handOffImageViewerSwipe(entry, direction),
            ),
      onWillPop: () async {
        final index = _tabs.indexOf(entry);
        if (index <= 0) return false;
        closeTabAt(index);
        return true;
      },
    );
    return entry;
  }

  TabEntry _createPdfViewerEntry(
    String path, {
    required String sessionId,
    required bool isDeferred,
    String? title,
    TabEntry? originTab,
  }) {
    final readingLocation = pdfReadingLocationForPath(path);
    final key = GlobalKey<PdfViewerTabState>();
    late final TabEntry entry;
    entry = TabEntry(
      id: 'pdfViewer:$path',
      title: title ?? _lastPathSegment(path, fallback: 'PDF'),
      sessionId: sessionId,
      isPdfViewer: true,
      isDeferred: isDeferred,
      returnToTab: originTab,
      pdfPath: path,
      pdfVolumeId: readingLocation.volumeId,
      pdfRelativePath: readingLocation.relativePath,
      pageBuilder: () => entry.isDeferred
          ? const _DeferredRestoredTab()
          : PdfViewerTab(
              key: key,
              path: entry.pdfPath!,
              volumeId: entry.pdfVolumeId!,
              relativePath: entry.pdfRelativePath!,
              persistReadingProgress: entry.pdfProgressEnabled,
              isChromeHidden: entry.isFullscreen,
              isSystemFullscreen: entry.isPdfSystemFullscreen,
              onChromeHiddenChanged: (hidden) =>
                  setPdfViewerChromeHidden(entry, hidden),
              onSystemFullscreenChanged: (fullscreen) =>
                  setPdfViewerSystemFullscreen(entry, fullscreen),
              onZoomChanged: (zoomed) => setPdfViewerZoomed(entry, zoomed),
            ),
      onWillPop: () async {
        if (entry.isFullscreen || entry.isPdfSystemFullscreen) {
          setPdfViewerSystemFullscreen(entry, false);
          return true;
        }
        final index = _tabs.indexOf(entry);
        if (index <= 0) return false;
        closeTabAt(index);
        return true;
      },
      onTabClosing: () =>
          key.currentState?.saveProgressNow() ?? Future<void>.value(),
      onPdfProgressDeleted: () => key.currentState?.stopProgressTracking(),
    );
    return entry;
  }

  ({String volumeId, String relativePath}) pdfReadingLocationForPath(
    String path,
  ) {
    final device = _deviceForAbsolutePath(path, _availableDevices);
    if (device == null) {
      return (volumeId: 'path:${_normalizePath(path)}', relativePath: '');
    }
    final normalizedPath = _normalizePath(path);
    final normalizedRoot = _normalizePath(device.path);
    final relativePath = normalizedPath == normalizedRoot
        ? ''
        : normalizedPath.substring(normalizedRoot.length + 1);
    return (volumeId: device.id, relativePath: relativePath);
  }

  bool _isPathWithin(String candidate, String root) {
    final normalizedCandidate = _normalizePath(candidate);
    final normalizedRoot = _normalizePath(root);
    return normalizedCandidate == normalizedRoot ||
        normalizedCandidate.startsWith('$normalizedRoot/');
  }

  Future<void> savePdfTabsBeforeMove(String oldPath) async {
    final affected = _tabs.where(
      (tab) =>
          tab.isPdfViewer &&
          tab.pdfPath != null &&
          _isPathWithin(tab.pdfPath!, oldPath),
    );
    for (final tab in affected) {
      await tab.onTabClosing?.call();
    }
  }

  void relocatePdfTabs(String oldPath, String newPath) {
    var changed = false;
    for (final tab in _tabs.where((item) => item.isPdfViewer)) {
      final path = tab.pdfPath;
      if (path == null || !_isPathWithin(path, oldPath)) continue;
      final normalizedOldPath = _normalizePath(oldPath);
      final normalizedPath = _normalizePath(path);
      final suffix = normalizedPath == normalizedOldPath
          ? ''
          : normalizedPath.substring(normalizedOldPath.length);
      final relocatedPath = '${_normalizePath(newPath)}$suffix';
      final location = pdfReadingLocationForPath(relocatedPath);
      tab
        ..pdfPath = relocatedPath
        ..pdfVolumeId = location.volumeId
        ..pdfRelativePath = location.relativePath
        ..title = _lastPathSegment(relocatedPath, fallback: 'PDF');
      changed = true;
    }
    if (changed) {
      notifyListeners();
      _schedulePersistTabs();
    }
  }

  void markPdfTabsDeleted(String path) {
    var changed = false;
    for (final tab in _tabs.where((item) => item.isPdfViewer)) {
      if (tab.pdfPath == null || !_isPathWithin(tab.pdfPath!, path)) continue;
      tab
        ..pdfProgressEnabled = false
        ..onPdfProgressDeleted?.call();
      changed = true;
    }
    if (changed) notifyListeners();
  }

  TabEntry _createVideoEntry({
    required String sessionId,
    required String driveId,
    required String relativePath,
    required bool isDeferred,
  }) {
    final key = GlobalKey<VideoTabState>();
    late final TabEntry entry;
    entry = TabEntry(
      id: 'video',
      title: 'Videos',
      sessionId: sessionId,
      isDeferred: isDeferred,
      isVideoPage: true,
      videoDriveId: driveId,
      videoRelativePath: relativePath,
      pageBuilder: () => entry.isDeferred
          ? const _DeferredRestoredTab()
          : VideoTab(
              key: key,
              sessionId: entry.sessionId,
              initialDriveId: entry.videoDriveId,
              initialRelativePath: entry.videoRelativePath,
              onLocationChanged: (location) =>
                  updateVideoLocation(entry, location),
            ),
      onWillPop: () async => key.currentState?.handleWillPop() ?? false,
    );
    return entry;
  }

  String _lastPathSegment(String path, {required String fallback}) =>
      storageDisplayName(path: path, fallback: fallback);

  String? _validSavedTitle(String? title) {
    final normalized = title?.trim();
    if (normalized == null ||
        normalized.isEmpty ||
        RegExp(r'^\d+$').hasMatch(normalized)) {
      debugPrint(
        '[TabsManager] Ignoring missing or index-like saved tab title "$title".',
      );
      return null;
    }
    return normalized;
  }

  void updateImageViewerPath(TabEntry entry, String path) {
    if (!_tabs.contains(entry) ||
        !entry.isImageViewer ||
        entry.currentImagePath == path) {
      return;
    }
    entry
      ..currentImagePath = path
      ..title = _lastPathSegment(path, fallback: 'Image');
    notifyListeners();
    _schedulePersistTabs();
  }

  void handOffImageViewerSwipe(TabEntry entry, int direction) {
    final selectedIndex = _selected;
    if (!_tabs.contains(entry) ||
        (!entry.isImageViewer && !entry.isPptxViewer) ||
        !identical(_tabs[selectedIndex], entry) ||
        entry.isImageZoomed ||
        entry.isPptxZoomed) {
      return;
    }
    final targetIndex = selectedIndex + direction;
    if (targetIndex < 0 || targetIndex >= _tabs.length) return;
    if (!_pageController.hasClients) {
      goTo(targetIndex);
      return;
    }

    _leaveFullscreenViewer();
    _pendingProgrammaticPage = targetIndex;
    unawaited(
      _pageController
          .animateToPage(
            targetIndex,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOutCubic,
          )
          .then((_) {
            if (_pendingProgrammaticPage != targetIndex) return;
            _pendingProgrammaticPage = null;
            if (_selected == targetIndex) return;
            _selected = targetIndex;
            _activateTab(_tabs[targetIndex]);
            notifyListeners();
            _schedulePersistTabs();
          }),
    );
  }

  void updateStorageLocation(TabEntry entry, StorageTabLocation location) {
    if (!_tabs.contains(entry)) return;
    entry
      ..storagePath = location.path
      ..driveId = location.driveId
      ..driveRoot = location.driveRoot;
    _schedulePersistTabs();
  }

  void updateVideoLocation(
    TabEntry entry,
    ({String driveId, String relativePath}) location,
  ) {
    if (!_tabs.contains(entry) || !entry.isVideoPage) return;
    entry
      ..videoDriveId = location.driveId
      ..videoRelativePath = location.relativePath;
    _schedulePersistTabs();
  }

  Map<String, Object?> _fileLocationRecord(String path) {
    final device = _deviceForAbsolutePath(path, _availableDevices);
    if (device == null) return {'path': path};
    final normalizedPath = _normalizePath(path);
    final normalizedRoot = _normalizePath(device.path);
    final relativePath = normalizedPath == normalizedRoot
        ? ''
        : normalizedPath.substring(normalizedRoot.length + 1);
    return {'driveId': device.id, 'relativePath': relativePath};
  }

  Map<String, Object?> _storageLocationRecord(TabEntry tab) {
    final path = tab.storagePath ?? tab.id;
    final root = tab.driveRoot;
    final driveId = tab.driveId;
    if (root == null || driveId == null) return {'path': path};
    final normalizedPath = _normalizePath(path);
    final normalizedRoot = _normalizePath(root);
    if (normalizedPath != normalizedRoot &&
        !normalizedPath.startsWith('$normalizedRoot/')) {
      return {'path': path};
    }
    final relativePath = normalizedPath == normalizedRoot
        ? ''
        : normalizedPath.startsWith('$normalizedRoot/')
        ? normalizedPath.substring(normalizedRoot.length + 1)
        : '';
    final normalizedAnchor = _normalizePath(tab.storageAnchorPath ?? root);
    final anchorRelativePath = normalizedAnchor == normalizedRoot
        ? ''
        : normalizedAnchor.startsWith('$normalizedRoot/')
        ? normalizedAnchor.substring(normalizedRoot.length + 1)
        : '';
    return {
      'driveId': driveId,
      'relativePath': relativePath,
      'anchorRelativePath': anchorRelativePath,
    };
  }

  void _schedulePersistTabs() {
    if (!_sessionReady || _restoring) return;
    _persistDebounce?.cancel();
    _persistDebounce = Timer(
      const Duration(milliseconds: 300),
      _flushPersistedTabs,
    );
  }

  Future<void> flushPersistedTabs() {
    _persistDebounce?.cancel();
    _persistDebounce = null;
    if (!_sessionReady || _restoring) return Future<void>.value();
    final selectedTab = _tabs[_selected];
    final persistedSelectedTab = selectedTab.isAudioPlayer
        ? selectedTab.returnToTab ?? _tabs.first
        : selectedTab;
    final snapshot = <String, Object?>{
      'version': 2,
      'selectedTabId': persistedSelectedTab.sessionId,
      'items': _tabs.skip(1).where((tab) => !tab.isAudioPlayer).map((tab) {
        final common = <String, Object?>{
          'tabId': tab.sessionId,
          'title': tab.title,
        };
        if (tab.id == 'apps') return {'type': 'apps', ...common};
        if (tab.isVideoPage) {
          return {
            'type': 'video',
            ...common,
            'driveId': tab.videoDriveId,
            'relativePath': tab.videoRelativePath,
          };
        }
        if (tab.isImageViewer) {
          return {
            'type': 'imageViewer',
            ...common,
            ..._fileLocationRecord(
              tab.currentImagePath ?? tab.id.substring('imageViewer:'.length),
            ),
            'originTabId': tab.returnToTab?.sessionId,
          };
        }
        if (tab.isPdfViewer) {
          return {
            'type': 'pdfViewer',
            ...common,
            ..._fileLocationRecord(tab.pdfPath!),
            'originTabId': tab.returnToTab?.sessionId,
          };
        }
        if (tab.isCsvViewer) {
          return {
            'type': 'csvViewer',
            ...common,
            ..._fileLocationRecord(tab.csvPath!),
            'originTabId': tab.returnToTab?.sessionId,
          };
        }
        if (tab.isXlsxViewer) {
          return {
            'type': 'xlsxViewer',
            ...common,
            ..._fileLocationRecord(tab.xlsxPath!),
            'originTabId': tab.returnToTab?.sessionId,
          };
        }
        if (tab.isDocxViewer) {
          return {
            'type': 'docxViewer',
            ...common,
            ..._fileLocationRecord(tab.docxPath!),
            'originTabId': tab.returnToTab?.sessionId,
          };
        }
        if (tab.isPptxViewer) {
          return {
            'type': 'pptxViewer',
            ...common,
            ..._fileLocationRecord(tab.pptxPath!),
            'originTabId': tab.returnToTab?.sessionId,
          };
        }
        if (tab.isArchiveManager) {
          return {
            'type': 'archiveManager',
            ...common,
            ..._fileLocationRecord(tab.archivePath!),
            'archiveFolder': tab.archiveFolder,
            'originTabId': tab.returnToTab?.sessionId,
          };
        }
        if (tab.id.startsWith('textEditor:')) {
          return {
            'type': 'textEditor',
            ...common,
            ..._fileLocationRecord(tab.id.substring(11)),
          };
        }
        return {
          'type': tab.imageOnly
              ? 'imageStorage'
              : tab.documentOnly
              ? 'documentStorage'
              : tab.audioOnly
              ? 'audioStorage'
              : tab.archiveOnly
              ? 'archiveStorage'
              : 'storage',
          ...common,
          ..._storageLocationRecord(tab),
        };
      }).toList(),
    };
    _persistQueue = _persistQueue
        .then((_) async {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('tabs.open', jsonEncode(snapshot));
        })
        .catchError((Object error) {
          _pendingNotice = 'Could not save the open-tab session: $error';
          notifyListeners();
        });
    return _persistQueue;
  }

  Future<void> _flushPersistedTabs() => flushPersistedTabs();

  void openStorageTab(
    String path, {
    String? title,
    bool imageOnly = false,
    bool documentOnly = false,
    bool audioOnly = false,
    bool archiveOnly = false,
    bool allowDuplicate = false,
  }) {
    if (!allowDuplicate &&
        (imageOnly || documentOnly || audioOnly || archiveOnly)) {
      final existing = _tabs.indexWhere(
        (tab) =>
            tab.imageOnly == imageOnly &&
            tab.documentOnly == documentOnly &&
            tab.audioOnly == audioOnly &&
            tab.archiveOnly == archiveOnly,
      );
      if (existing != -1) {
        goTo(existing);
        return;
      }
    }
    final id = imageOnly
        ? 'imageStorage:$path'
        : documentOnly
        ? 'documentStorage:$path'
        : audioOnly
        ? 'audioStorage:$path'
        : archiveOnly
        ? 'archiveStorage:$path'
        : path;
    // Existing callers retain focus-existing-tab behavior. Only an explicit
    // duplicate request, such as an Available Storage card tap, skips this.
    if (!allowDuplicate) {
      final exist = _tabs.indexWhere((t) => t.id == id);
      if (exist != -1) {
        goTo(exist);
        return;
      }
    }

    if (_tabs.length >= maxOpenTabs) return;
    final device = _deviceForAbsolutePath(path, _availableDevices);
    final entry = _createStorageEntry(
      path: path,
      title: title,
      imageOnly: imageOnly,
      documentOnly: documentOnly,
      audioOnly: audioOnly,
      archiveOnly: archiveOnly,
      sessionId: _newTabInstanceId(),
      isDeferred: false,
      driveId: device?.id,
      driveRoot: device?.path,
      anchorPath: path,
    );
    _tabs.add(entry);
    final target = _tabs.length - 1;
    // set selection first so listeners rebuild for the new selected index
    _leaveFullscreenViewer();
    _selected = target;
    debugPrint(
      '[TabsManager] openStorageTab -> added tab "$path" target=$target selected=$_selected',
    );
    notifyListeners();
    _schedulePersistTabs();

    _schedulePageJump(target);
  }

  void openAppsTab() {
    const id = 'apps';
    final existing = _tabs.indexWhere((tab) => tab.id == id);
    if (existing != -1) {
      goTo(existing);
      return;
    }

    if (_tabs.length >= maxOpenTabs) return;

    _tabs.add(
      TabEntry(id: id, title: 'Apps', pageBuilder: () => const AppsTab()),
    );
    final target = _tabs.length - 1;
    _leaveFullscreenViewer();
    _selected = target;
    notifyListeners();
    _schedulePersistTabs();
    _schedulePageJump(target);
  }

  void openVideoTab() {
    const id = 'video';
    final existing = _tabs.indexWhere((tab) => tab.id == id);
    if (existing != -1) {
      goTo(existing);
      return;
    }
    if (_tabs.length >= maxOpenTabs) {
      _pendingNotice = 'You can open up to $maxOpenTabs tabs.';
      notifyListeners();
      return;
    }
    _tabs.add(
      _createVideoEntry(
        sessionId: _newTabInstanceId(),
        driveId: 'internal',
        relativePath: '',
        isDeferred: false,
      ),
    );
    final target = _tabs.length - 1;
    _leaveFullscreenViewer();
    _selected = target;
    notifyListeners();
    _schedulePersistTabs();
    _schedulePageJump(target);
  }

  TabEntry? get audioPlayerTab =>
      _tabs.where((tab) => tab.isAudioPlayer).firstOrNull;

  TabEntry? openAudioPlayerTab(
    String path, {
    required Set<String> extensions,
    List<String>? queuePaths,
    required AudioPlayerRepository repository,
  }) {
    final existing = audioPlayerTab;
    if (existing != null) {
      existing
        ..audioPath = path
        ..audioExtensions = Set.unmodifiable(extensions)
        ..audioQueuePaths = queuePaths == null
            ? null
            : List.unmodifiable(queuePaths)
        ..title = _lastPathSegment(path, fallback: 'Audio');
      goTo(_tabs.indexOf(existing));
      notifyListeners();
      return existing;
    }
    if (_tabs.length >= maxOpenTabs) {
      _pendingNotice = 'You can open up to $maxOpenTabs tabs.';
      notifyListeners();
      return null;
    }
    final originTab = _tabs[_selected];
    final entry = _createAudioPlayerEntry(
      path,
      extensions: extensions,
      queuePaths: queuePaths,
      repository: repository,
      originTab: originTab,
    );
    _tabs.add(entry);
    final target = _tabs.length - 1;
    _leaveFullscreenViewer();
    _selected = target;
    notifyListeners();
    _schedulePageJump(target);
    return entry;
  }

  TabEntry _createAudioPlayerEntry(
    String path, {
    required Set<String> extensions,
    List<String>? queuePaths,
    required AudioPlayerRepository repository,
    required TabEntry originTab,
  }) {
    late final TabEntry entry;
    entry = TabEntry(
      id: 'audioPlayer',
      title: _lastPathSegment(path, fallback: 'Audio'),
      isAudioPlayer: true,
      audioPath: path,
      audioExtensions: Set.unmodifiable(extensions),
      audioQueuePaths: queuePaths == null
          ? null
          : List.unmodifiable(queuePaths),
      returnToTab: originTab,
      onTabClosing: repository.stop,
      onWillPop: () async {
        final index = _tabs.indexOf(entry);
        if (index <= 0) return false;
        closeTabAt(index);
        return true;
      },
      pageBuilder: () => AudioPlayerTab(
        path: entry.audioPath!,
        extensions: entry.audioExtensions,
        queuePaths: entry.audioQueuePaths,
        onTitleChanged: (title) => updateAudioPlayerTitle(entry, title),
        onBack: () => closeTab(entry),
      ),
    );
    return entry;
  }

  void updateAudioPlayerTitle(TabEntry entry, String title) {
    if (!_tabs.contains(entry) || !entry.isAudioPlayer || title.isEmpty) return;
    if (entry.title == title) return;
    entry.title = title;
    notifyListeners();
  }

  void openTextEditor(
    String path, {
    bool allowDuplicate = false,
    bool allowNonText = false,
  }) {
    final id = 'textEditor:$path';
    if (!allowDuplicate) {
      final existing = _tabs.indexWhere((tab) => tab.id == id);
      if (existing != -1) {
        goTo(existing);
        return;
      }
    }
    if (_tabs.length >= maxOpenTabs) return;

    _tabs.add(
      _createTextEditorEntry(
        path,
        sessionId: _newTabInstanceId(),
        isDeferred: false,
        allowNonText: allowNonText,
      ),
    );
    final target = _tabs.length - 1;
    _leaveFullscreenViewer();
    _selected = target;
    notifyListeners();
    _schedulePersistTabs();
    _schedulePageJump(target);
  }

  TabEntry? openImageViewer(
    String path, {
    bool allowDuplicate = false,
    List<String>? imagePaths,
  }) {
    final id = 'imageViewer:$path';
    if (!allowDuplicate) {
      final existing = _tabs.indexWhere((tab) => tab.id == id);
      if (existing != -1) {
        goTo(existing);
        return _tabs[existing];
      }
    }
    if (_tabs.where((tab) => tab.isImageViewer).length >= maxImageViewerTabs) {
      _pendingNotice = 'You can open up to $maxImageViewerTabs image viewers.';
      notifyListeners();
      return null;
    }
    if (_tabs.length >= maxOpenTabs) return null;

    final originTab = _tabs[_selected];
    final entry = _createImageViewerEntry(
      path,
      sessionId: _newTabInstanceId(),
      isDeferred: false,
      imagePaths: imagePaths,
      originTab: originTab,
    );
    _tabs.add(entry);
    final target = _tabs.length - 1;
    _leaveFullscreenViewer();
    _selected = target;
    notifyListeners();
    _schedulePersistTabs();
    _schedulePageJump(target);
    return entry;
  }

  TabEntry? openPdfViewerTab(String path, {bool allowDuplicate = false}) {
    final id = 'pdfViewer:$path';
    if (!allowDuplicate) {
      final existing = _tabs.indexWhere(
        (tab) => tab.id == id || (tab.isPdfViewer && tab.pdfPath == path),
      );
      if (existing >= 0) {
        goTo(existing);
        return _tabs[existing];
      }
    }
    if (_tabs.length >= maxOpenTabs) {
      _pendingNotice = 'You can open up to $maxOpenTabs tabs.';
      notifyListeners();
      return null;
    }
    final originTab = _tabs[_selected];
    final entry = _createPdfViewerEntry(
      path,
      sessionId: _newTabInstanceId(),
      isDeferred: false,
      originTab: originTab,
    );
    _tabs.add(entry);
    final target = _tabs.length - 1;
    _leaveFullscreenViewer();
    _selected = target;
    notifyListeners();
    _schedulePersistTabs();
    _schedulePageJump(target);
    return entry;
  }

  TabEntry? openCsvViewerTab(String path, {bool allowDuplicate = false}) {
    final id = 'csvViewer:$path';
    if (!allowDuplicate) {
      final existing = _tabs.indexWhere(
        (tab) => tab.id == id || (tab.isCsvViewer && tab.csvPath == path),
      );
      if (existing >= 0) {
        goTo(existing);
        return _tabs[existing];
      }
    }
    if (_tabs.length >= maxOpenTabs) {
      _pendingNotice = 'You can open up to $maxOpenTabs tabs.';
      notifyListeners();
      return null;
    }
    final originTab = _tabs[_selected];
    final entry = _createCsvViewerEntry(
      path,
      sessionId: _newTabInstanceId(),
      isDeferred: false,
      originTab: originTab,
    );
    _tabs.add(entry);
    final target = _tabs.length - 1;
    _leaveFullscreenViewer();
    _selected = target;
    notifyListeners();
    _schedulePersistTabs();
    _schedulePageJump(target);
    return entry;
  }

  TabEntry? openXlsxViewerTab(String path, {bool allowDuplicate = false}) {
    final id = 'xlsxViewer:$path';
    if (!allowDuplicate) {
      final existing = _tabs.indexWhere(
        (tab) => tab.id == id || (tab.isXlsxViewer && tab.xlsxPath == path),
      );
      if (existing >= 0) {
        goTo(existing);
        return _tabs[existing];
      }
    }
    if (_tabs.length >= maxOpenTabs) {
      _pendingNotice = 'You can open up to $maxOpenTabs tabs.';
      notifyListeners();
      return null;
    }
    final originTab = _tabs[_selected];
    final entry = _createXlsxViewerEntry(
      path,
      sessionId: _newTabInstanceId(),
      isDeferred: false,
      originTab: originTab,
    );
    _tabs.add(entry);
    final target = _tabs.length - 1;
    _leaveFullscreenViewer();
    _selected = target;
    notifyListeners();
    _schedulePersistTabs();
    _schedulePageJump(target);
    return entry;
  }

  TabEntry? openDocxViewerTab(String path, {bool allowDuplicate = false}) {
    final id = 'docxViewer:$path';
    if (!allowDuplicate) {
      final existing = _tabs.indexWhere(
        (tab) => tab.id == id || (tab.isDocxViewer && tab.docxPath == path),
      );
      if (existing >= 0) {
        goTo(existing);
        return _tabs[existing];
      }
    }
    if (_tabs.length >= maxOpenTabs) {
      _pendingNotice = 'You can open up to $maxOpenTabs tabs.';
      notifyListeners();
      return null;
    }
    final originTab = _tabs[_selected];
    final entry = _createDocxViewerEntry(
      path,
      sessionId: _newTabInstanceId(),
      isDeferred: false,
      originTab: originTab,
    );
    _tabs.add(entry);
    final target = _tabs.length - 1;
    _leaveFullscreenViewer();
    _selected = target;
    notifyListeners();
    _schedulePersistTabs();
    _schedulePageJump(target);
    return entry;
  }

  TabEntry? openPptxViewerTab(String path, {bool allowDuplicate = false}) {
    final id = 'pptxViewer:$path';
    if (!allowDuplicate) {
      final existing = _tabs.indexWhere(
        (tab) => tab.id == id || (tab.isPptxViewer && tab.pptxPath == path),
      );
      if (existing >= 0) {
        goTo(existing);
        return _tabs[existing];
      }
    }
    if (_tabs.length >= maxOpenTabs) {
      _pendingNotice = 'You can open up to $maxOpenTabs tabs.';
      notifyListeners();
      return null;
    }
    final originTab = _tabs[_selected];
    final entry = _createPptxViewerEntry(
      path,
      sessionId: _newTabInstanceId(),
      isDeferred: false,
      originTab: originTab,
    );
    _tabs.add(entry);
    final target = _tabs.length - 1;
    _leaveFullscreenViewer();
    _selected = target;
    notifyListeners();
    _schedulePersistTabs();
    _schedulePageJump(target);
    return entry;
  }

  TabEntry _createCsvViewerEntry(
    String path, {
    required String sessionId,
    required bool isDeferred,
    String? title,
    TabEntry? originTab,
  }) {
    late final TabEntry entry;
    entry = TabEntry(
      id: 'csvViewer:$path',
      title: title ?? _lastPathSegment(path, fallback: 'Spreadsheet'),
      sessionId: sessionId,
      isCsvViewer: true,
      isDeferred: isDeferred,
      returnToTab: originTab,
      csvPath: path,
      pageBuilder: () => entry.isDeferred
          ? const _DeferredRestoredTab()
          : CsvViewerTab(
              path: entry.csvPath!,
              isChromeHidden: entry.isFullscreen,
              onChromeHiddenChanged: (hidden) =>
                  setOfficeViewerChromeHidden(entry, hidden),
              onZoomChanged: (zoomed) => setCsvViewerZoomed(entry, zoomed),
            ),
      onWillPop: () async {
        if (entry.isFullscreen) {
          setOfficeViewerChromeHidden(entry, false);
          return true;
        }
        final index = _tabs.indexOf(entry);
        if (index <= 0) return false;
        closeTabAt(index);
        return true;
      },
    );
    return entry;
  }

  TabEntry _createXlsxViewerEntry(
    String path, {
    required String sessionId,
    required bool isDeferred,
    String? title,
    TabEntry? originTab,
  }) {
    late final TabEntry entry;
    entry = TabEntry(
      id: 'xlsxViewer:$path',
      title: title ?? _lastPathSegment(path, fallback: 'Spreadsheet'),
      sessionId: sessionId,
      isXlsxViewer: true,
      isDeferred: isDeferred,
      returnToTab: originTab,
      xlsxPath: path,
      pageBuilder: () => entry.isDeferred
          ? const _DeferredRestoredTab()
          : XlsxViewerTab(
              path: entry.xlsxPath!,
              isChromeHidden: entry.isFullscreen,
              onChromeHiddenChanged: (hidden) =>
                  setOfficeViewerChromeHidden(entry, hidden),
              onZoomChanged: (zoomed) => setCsvViewerZoomed(entry, zoomed),
            ),
      onWillPop: () async {
        if (entry.isFullscreen) {
          setOfficeViewerChromeHidden(entry, false);
          return true;
        }
        final index = _tabs.indexOf(entry);
        if (index <= 0) return false;
        closeTabAt(index);
        return true;
      },
    );
    return entry;
  }

  TabEntry _createDocxViewerEntry(
    String path, {
    required String sessionId,
    required bool isDeferred,
    String? title,
    TabEntry? originTab,
  }) {
    late final TabEntry entry;
    entry = TabEntry(
      id: 'docxViewer:$path',
      title: title ?? _lastPathSegment(path, fallback: 'Document'),
      sessionId: sessionId,
      isDocxViewer: true,
      isDeferred: isDeferred,
      returnToTab: originTab,
      docxPath: path,
      pageBuilder: () => entry.isDeferred
          ? const _DeferredRestoredTab()
          : DocxViewerTab(
              path: entry.docxPath!,
              isChromeHidden: entry.isFullscreen,
              onChromeHiddenChanged: (hidden) =>
                  setOfficeViewerChromeHidden(entry, hidden),
              onZoomChanged: (zoomed) => setCsvViewerZoomed(entry, zoomed),
            ),
      onWillPop: () async {
        if (entry.isFullscreen) {
          setOfficeViewerChromeHidden(entry, false);
          return true;
        }
        final index = _tabs.indexOf(entry);
        if (index <= 0) return false;
        closeTabAt(index);
        return true;
      },
    );
    return entry;
  }

  TabEntry _createPptxViewerEntry(
    String path, {
    required String sessionId,
    required bool isDeferred,
    String? title,
    TabEntry? originTab,
  }) {
    final readingLocation = pdfReadingLocationForPath(path);
    late final TabEntry entry;
    entry = TabEntry(
      id: 'pptxViewer:$path',
      title: title ?? _lastPathSegment(path, fallback: 'Presentation'),
      sessionId: sessionId,
      isPptxViewer: true,
      isDeferred: isDeferred,
      returnToTab: originTab,
      pptxPath: path,
      pageBuilder: () => entry.isDeferred
          ? const _DeferredRestoredTab()
          : PptxViewerTab(
              path: entry.pptxPath!,
              volumeId: readingLocation.volumeId,
              relativePath: readingLocation.relativePath,
              isChromeHidden: entry.isFullscreen,
              onChromeHiddenChanged: (hidden) =>
                  setOfficeViewerChromeHidden(entry, hidden),
              onZoomChanged: (zoomed) => setPptxViewerZoomed(entry, zoomed),
              onBoundaryHandoff: (direction) =>
                  handOffImageViewerSwipe(entry, direction),
            ),
      onWillPop: () async {
        if (entry.isFullscreen) {
          setOfficeViewerChromeHidden(entry, false);
          return true;
        }
        final index = _tabs.indexOf(entry);
        if (index <= 0) return false;
        closeTabAt(index);
        return true;
      },
    );
    return entry;
  }

  TabEntry? openArchiveManagerTab(
    String path, {
    bool allowDuplicate = false,
    String? autoExtractTo,
    bool closeAfterAutoExtraction = false,
    Future<void> Function()? onAutoExtractionComplete,
  }) {
    final id = 'archiveManager:$path';
    if (!allowDuplicate) {
      final existing = _tabs.indexWhere((tab) => tab.id == id);
      if (existing >= 0) {
        goTo(existing);
        return _tabs[existing];
      }
    }
    if (_tabs.length >= maxOpenTabs) {
      _pendingNotice = 'You can open up to $maxOpenTabs tabs.';
      notifyListeners();
      return null;
    }
    final originTab = _tabs[_selected];
    final entry = _createArchiveManagerEntry(
      path,
      sessionId: _newTabInstanceId(),
      isDeferred: false,
      originTab: originTab,
      autoExtractTo: autoExtractTo,
      closeAfterAutoExtraction: closeAfterAutoExtraction,
      onAutoExtractionComplete: onAutoExtractionComplete,
    );
    _tabs.add(entry);
    final target = _tabs.length - 1;
    _leaveFullscreenViewer();
    _selected = target;
    notifyListeners();
    _schedulePersistTabs();
    _schedulePageJump(target);
    return entry;
  }

  TabEntry _createArchiveManagerEntry(
    String path, {
    required String sessionId,
    required bool isDeferred,
    String? title,
    String initialFolder = '',
    TabEntry? originTab,
    String? autoExtractTo,
    bool closeAfterAutoExtraction = false,
    Future<void> Function()? onAutoExtractionComplete,
  }) {
    final key = GlobalKey<ArchiveManagerPageState>();
    late final TabEntry entry;
    entry = TabEntry(
      id: 'archiveManager:$path',
      title: title ?? _lastPathSegment(path, fallback: 'Archive'),
      sessionId: sessionId,
      isDeferred: isDeferred,
      isArchiveManager: true,
      archivePath: path,
      archiveFolder: initialFolder,
      returnToTab: originTab,
      pageBuilder: () => entry.isDeferred
          ? const _DeferredRestoredTab()
          : ArchiveManagerPage(
              key: key,
              archivePath: entry.archivePath!,
              initialFolder: entry.archiveFolder,
              autoExtractTo: autoExtractTo,
              closeAfterAutoExtraction: closeAfterAutoExtraction,
              onFolderChanged: (folder) =>
                  updateArchiveManagerFolder(entry, folder),
              onClose: () => closeTab(entry),
              onAutoExtractionComplete: onAutoExtractionComplete,
            ),
      onWillPop: () async => key.currentState?.handleWillPop() ?? false,
    );
    return entry;
  }

  void updateArchiveManagerFolder(TabEntry entry, String folder) {
    if (!_tabs.contains(entry) ||
        !entry.isArchiveManager ||
        entry.archiveFolder == folder) {
      return;
    }
    entry.archiveFolder = folder;
    _schedulePersistTabs();
  }

  void closeTab(TabEntry entry) {
    final index = _tabs.indexOf(entry);
    if (index > 0) closeTabAt(index);
  }

  void setImageViewerFullscreen(TabEntry entry, bool isFullscreen) {
    if (!_tabs.contains(entry) ||
        !entry.isImageViewer ||
        entry.isFullscreen == isFullscreen) {
      return;
    }
    entry.isFullscreen = isFullscreen;
    notifyListeners();
  }

  void setPdfViewerChromeHidden(TabEntry entry, bool hidden) {
    if (!_tabs.contains(entry) ||
        !entry.isPdfViewer ||
        entry.isFullscreen == hidden) {
      return;
    }
    entry.isFullscreen = hidden;
    notifyListeners();
  }

  void setOfficeViewerChromeHidden(TabEntry entry, bool hidden) {
    if (!_tabs.contains(entry) ||
        (!entry.isCsvViewer &&
            !entry.isXlsxViewer &&
            !entry.isDocxViewer &&
            !entry.isPptxViewer) ||
        entry.isFullscreen == hidden) {
      return;
    }
    entry.isFullscreen = hidden;
    notifyListeners();
  }

  void setCsvViewerZoomed(TabEntry entry, bool zoomed) {
    if (!_tabs.contains(entry) ||
        (!entry.isCsvViewer && !entry.isXlsxViewer && !entry.isDocxViewer) ||
        entry.isCsvZoomed == zoomed) {
      return;
    }
    entry.isCsvZoomed = zoomed;
    notifyListeners();
  }

  void setPptxViewerZoomed(TabEntry entry, bool zoomed) {
    if (!_tabs.contains(entry) ||
        !entry.isPptxViewer ||
        entry.isPptxZoomed == zoomed) {
      return;
    }
    entry.isPptxZoomed = zoomed;
    notifyListeners();
  }

  void setPdfViewerSystemFullscreen(TabEntry entry, bool fullscreen) {
    if (!_tabs.contains(entry) ||
        !entry.isPdfViewer ||
        (entry.isPdfSystemFullscreen == fullscreen &&
            entry.isFullscreen == fullscreen)) {
      return;
    }
    entry
      ..isPdfSystemFullscreen = fullscreen
      ..isFullscreen = fullscreen;
    notifyListeners();
  }

  void setPdfViewerZoomed(TabEntry entry, bool zoomed) {
    if (!_tabs.contains(entry) ||
        !entry.isPdfViewer ||
        entry.isPdfZoomed == zoomed) {
      return;
    }
    entry.isPdfZoomed = zoomed;
    notifyListeners();
  }

  void setImageViewerZoomed(TabEntry entry, bool isZoomed) {
    if (!_tabs.contains(entry) ||
        !entry.isImageViewer ||
        entry.isImageZoomed == isZoomed) {
      return;
    }
    entry.isImageZoomed = isZoomed;
    notifyListeners();
  }

  void _leaveFullscreenViewer() {
    if (_selected < 0 || _selected >= _tabs.length) return;
    final selectedTab = _tabs[_selected];
    if (selectedTab.isImageViewer && selectedTab.isFullscreen) {
      selectedTab.isFullscreen = false;
    } else if (selectedTab.isPdfViewer &&
        (selectedTab.isFullscreen || selectedTab.isPdfSystemFullscreen)) {
      selectedTab
        ..isFullscreen = false
        ..isPdfSystemFullscreen = false;
    } else if ((selectedTab.isCsvViewer ||
            selectedTab.isXlsxViewer ||
            selectedTab.isDocxViewer ||
            selectedTab.isPptxViewer) &&
        selectedTab.isFullscreen) {
      selectedTab.isFullscreen = false;
    }
  }

  /// Ask the selected tab to handle a back press. Returns true if the tab
  /// handled (consumed) the back action.
  Future<bool> handleSelectedTabWillPop() async {
    if (_selected < 0 || _selected >= _tabs.length) return false;
    final handler = _tabs[_selected].onWillPop;
    if (handler == null) return false;
    try {
      return await handler();
    } catch (_) {
      return false;
    }
  }

  Future<bool> requestCloseTab(BuildContext context, int idx) async {
    if (idx <= 0 || idx >= _tabs.length) return false;
    final closeRequest = _tabs[idx].onCloseRequest;
    final shouldClose = closeRequest == null || await closeRequest(context);
    if (!shouldClose || idx >= _tabs.length) return false;
    closeTabAt(idx);
    return true;
  }

  void closeTabAt(int idx) {
    if (idx <= 0 || idx >= _tabs.length) return; // never close home
    final closingSelectedTab = idx == _selected;
    final closingTab = _tabs[idx];
    final onTabClosing = closingTab.onTabClosing;
    if (onTabClosing != null) {
      unawaited(
        onTabClosing().catchError((Object error, StackTrace stackTrace) {
          debugPrint('[TabsManager] Could not stop audio playback: $error');
        }),
      );
    }
    final returnToTab =
        closingTab.isImageViewer ||
            closingTab.isPdfViewer ||
            closingTab.isCsvViewer ||
            closingTab.isXlsxViewer ||
            closingTab.isDocxViewer ||
            closingTab.isPptxViewer ||
            closingTab.isArchiveManager ||
            closingTab.isAudioPlayer
        ? closingTab.returnToTab
        : null;
    _tabs.removeAt(idx);
    if (closingSelectedTab) {
      final originIndex = returnToTab == null ? -1 : _tabs.indexOf(returnToTab);
      _selected = originIndex >= 0
          ? originIndex
          : (returnToTab != null ? 0 : idx - 1);
    } else if (idx < _selected) {
      _selected--;
    }
    debugPrint(
      '[TabsManager] closeTabAt -> removed idx=$idx newSelected=$_selected',
    );
    _activateTab(_tabs[_selected]);
    notifyListeners();
    _schedulePersistTabs();
    _schedulePageJump(_selected);
  }

  void goTo(int idx) {
    if (idx < 0 || idx >= _tabs.length) return;
    if (idx != _selected) _leaveFullscreenViewer();
    _selected = idx;
    _activateTab(_tabs[idx]);
    debugPrint('[TabsManager] goTo -> idx=$idx selected=$_selected');
    notifyListeners();
    _schedulePersistTabs();
    _schedulePageJump(idx);
  }

  void _activateTab(TabEntry tab) {
    if (tab.isDeferred) tab.isDeferred = false;
  }

  void reorderTab(int oldIndex, int newIndex) {
    if (oldIndex <= 0 ||
        newIndex <= 0 ||
        oldIndex >= _tabs.length ||
        newIndex >= _tabs.length ||
        oldIndex == newIndex) {
      return;
    }

    final selectedTab = _tabs[_selected];
    final movedTab = _tabs.removeAt(oldIndex);
    _tabs.insert(newIndex, movedTab);
    _selected = _tabs.indexOf(selectedTab);
    notifyListeners();
    _schedulePersistTabs();
    _schedulePageJump(_selected);
  }

  void _schedulePageJump(int target) {
    _pendingProgrammaticPage = target;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_pendingProgrammaticPage != target) return;
      if (target >= 0 && target < _tabs.length && _pageController.hasClients) {
        debugPrint('[TabsManager] jumping to page $target');
        _pageController.jumpToPage(target);
      }
      // jumpToPage may not emit onPageChanged when already at this page or
      // when the PageView is not attached. Do not leave a stale guard that
      // suppresses later user-driven page changes.
      if (_pendingProgrammaticPage == target) {
        _pendingProgrammaticPage = null;
      }
    });
  }

  /// Called by the PageView when the visible page changes. This updates the
  /// internal selected index without attempting to move the PageController
  /// (avoids feedback loops where PageView->goTo->PageView causes reversion).
  void setSelectedFromPage(int idx) {
    if (idx < 0 || idx >= _tabs.length) return;
    // Ignore intermediate callbacks until the scheduled programmatic jump
    // reaches its target. The pending guard is cleared immediately after the
    // jump too, since jumping to the current page may not emit a callback.
    if (_pendingProgrammaticPage != null) {
      debugPrint(
        '[TabsManager] setSelectedFromPage -> pending=$_pendingProgrammaticPage idx=$idx',
      );
      if (_pendingProgrammaticPage == idx) {
        _pendingProgrammaticPage = null;
        if (_selected == idx) return;
        _leaveFullscreenViewer();
        _selected = idx;
        _activateTab(_tabs[idx]);
        notifyListeners();
        _schedulePersistTabs();
      }
      return;
    }
    if (_selected == idx) return;
    _leaveFullscreenViewer();
    debugPrint(
      '[TabsManager] setSelectedFromPage -> idx=$idx previousSelected=$_selected',
    );
    _selected = idx;
    _activateTab(_tabs[idx]);
    notifyListeners();
    _schedulePersistTabs();
  }

  void disposeManager() {
    _persistDebounce?.cancel();
    _pageController.dispose();
  }
}

class _DeferredRestoredTab extends StatelessWidget {
  const _DeferredRestoredTab();

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

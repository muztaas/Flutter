import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../core/providers/settings_provider.dart';
import '../../core/providers/storage_providers.dart';
import '../../core/providers/open_with_providers.dart';
import '../../core/providers/default_file_apps_provider.dart';
import '../../core/providers/sort_rules_provider.dart';
import '../../core/tabs/tabs_manager.dart';
import '../../domain/entities/default_file_app.dart';
import '../../domain/entities/sort_rule.dart';
import '../../domain/entities/open_with_app.dart';
import '../../domain/usecases/resolve_effective_sort_rule.dart';
import '../common/marquee_text.dart';

enum _CopyPanelStep {
  standard,
  chooseConflictScope,
  resolveConflict,
  chooseRename,
  chooseApplyAllRenameTarget,
  chooseApplyAllRenameMethod,
  chooseApplyAllSeriesStyle,
  cancelChoice,
}

enum _CopyConflictMode { single, applyAll, separate }

enum _CopyCancelMode { initial, uniform, separate }

enum _CopyConflictAction { replace, renameExisting, renameNew }

enum _ApplyAllSeriesStyle { keepItemNames, useNewBaseName }

enum _BatchRenameOrder { selection, currentSort }

enum _BatchRenameScope { nameOnly, nameAndExtension }

enum _BatchCollisionChoice { overwrite, rename, skip, cancel, resolveOneByOne }

class _OpenWithSelection {
  const _OpenWithSelection({
    required this.saveAsDefault,
    this.app,
    this.isTextEditor = false,
  });

  final OpenWithApp? app;
  final bool isTextEditor;
  final bool saveAsDefault;
}

class _BatchRenameEntry {
  _BatchRenameEntry({
    required this.source,
    required this.oldName,
    required this.targetName,
  });

  final FileSystemEntity source;
  final String oldName;
  String targetName;
  bool overwrite = false;
  bool skipped = false;
}

class _BatchRenameCollision {
  const _BatchRenameCollision({
    required this.entry,
    required this.occupantName,
    this.isDuplicatePlan = false,
  });

  final _BatchRenameEntry entry;
  final String occupantName;
  final bool isDuplicatePlan;
}

class _BatchRenameResult {
  const _BatchRenameResult({
    required this.entry,
    required this.status,
    this.error,
  });

  final _BatchRenameEntry entry;
  final String status;
  final String? error;
}

class _CopyConflict {
  const _CopyConflict({required this.source, required this.targetPath});

  final FileSystemEntity source;
  final String targetPath;
}

class _CopyPanelSnapshot {
  const _CopyPanelSnapshot({
    required this.step,
    required this.conflictIndex,
    required this.mode,
  });

  final _CopyPanelStep step;
  final int conflictIndex;
  final _CopyConflictMode mode;
}

class StorageCopySession {
  StorageCopySession({this.onChanged});

  final VoidCallback? onChanged;
  List<FileSystemEntity> _sources = const [];
  bool _isPasting = false;
  Directory? _destination;
  List<FileSystemEntity> _nonConflicting = const [];
  List<_CopyConflict> _conflicts = [];
  int _conflictIndex = 0;
  int _pastedCount = 0;
  final List<FileSystemEntity> _failedSources = [];
  _CopyPanelStep _step = _CopyPanelStep.standard;
  final List<_CopyPanelSnapshot> _panelHistory = [];
  _CopyConflictMode _mode = _CopyConflictMode.single;
  _CopyConflictAction? _applyAllRenameAction;
  bool _applyAllRenameSeries = false;
  _ApplyAllSeriesStyle? _applyAllSeriesStyle;
  bool _startedWithMultipleConflicts = false;
  _CopyCancelMode _cancelMode = _CopyCancelMode.initial;

  List<FileSystemEntity> get sources => _sources;
  bool get isPasting => _isPasting;
  Directory? get destination => _destination;
  List<FileSystemEntity> get nonConflicting => _nonConflicting;
  List<_CopyConflict> get conflicts => _conflicts;
  int get conflictIndex => _conflictIndex;
  int get pastedCount => _pastedCount;
  List<FileSystemEntity> get failedSources => _failedSources;
  _CopyPanelStep get step => _step;
  _CopyConflictMode get mode => _mode;
  _CopyConflictAction? get applyAllRenameAction => _applyAllRenameAction;
  bool get startedWithMultipleConflicts => _startedWithMultipleConflicts;
  _CopyCancelMode get cancelMode => _cancelMode;
  _CopyConflict? get currentConflict =>
      _conflictIndex < _conflicts.length ? _conflicts[_conflictIndex] : null;
  double get panelHeight => switch (_step) {
    _CopyPanelStep.standard => 72,
    _CopyPanelStep.chooseConflictScope => 128,
    _CopyPanelStep.resolveConflict ||
    _CopyPanelStep.chooseRename ||
    _CopyPanelStep.chooseApplyAllRenameTarget ||
    _CopyPanelStep.chooseApplyAllRenameMethod ||
    _CopyPanelStep.chooseApplyAllSeriesStyle ||
    _CopyPanelStep.cancelChoice => 108,
  };

  void notifyChanged() => onChanged?.call();

  void setSources(List<FileSystemEntity> sources) {
    _sources = List.unmodifiable(sources);
    _destination = null;
    _nonConflicting = const [];
    _conflicts = const [];
    _conflictIndex = 0;
    _pastedCount = 0;
    _failedSources.clear();
    _panelHistory.clear();
    _step = _CopyPanelStep.standard;
    _isPasting = false;
    _mode = _CopyConflictMode.single;
    _applyAllRenameAction = null;
    _applyAllRenameSeries = false;
    _applyAllSeriesStyle = null;
    _startedWithMultipleConflicts = false;
    onChanged?.call();
  }

  void setStep(_CopyPanelStep step) {
    _step = step;
    onChanged?.call();
  }

  void setPastedCount(int count) {
    _pastedCount = count;
  }

  void setConflicts({
    required Directory destination,
    required List<FileSystemEntity> nonConflicting,
    required List<_CopyConflict> conflicts,
  }) {
    _destination = destination;
    _nonConflicting = List.unmodifiable(nonConflicting);
    _conflicts = List.of(conflicts);
    _conflictIndex = 0;
    _pastedCount = 0;
    _failedSources.clear();
    _isPasting = false;
    _panelHistory.clear();
    _startedWithMultipleConflicts = conflicts.length > 1;
    _applyAllRenameAction = null;
    _applyAllRenameSeries = false;
    _applyAllSeriesStyle = null;
    _mode = conflicts.length <= 1
        ? _CopyConflictMode.single
        : _CopyConflictMode.separate;
    _step = conflicts.length > 1
        ? _CopyPanelStep.chooseConflictScope
        : conflicts.isEmpty
        ? _CopyPanelStep.standard
        : _CopyPanelStep.resolveConflict;
    onChanged?.call();
  }

  void advanceConflict() {
    if (_conflictIndex < _conflicts.length) {
      final resolvedConflict = _conflicts.removeAt(_conflictIndex);
      final failed = _failedSources.any(
        (source) => source.path == resolvedConflict.source.path,
      );
      if (!failed) {
        _sources = List.unmodifiable(
          _sources
              .where((source) => source.path != resolvedConflict.source.path)
              .toList(),
        );
      }
    }
    _conflictIndex = 0;
    _panelHistory.clear();
    _step = _conflicts.isNotEmpty
        ? _CopyPanelStep.resolveConflict
        : _CopyPanelStep.standard;
    onChanged?.call();
  }

  void showScopeForRemainingConflicts() {
    _panelHistory.clear();
    _conflictIndex = 0;
    _step = _CopyPanelStep.chooseConflictScope;
    onChanged?.call();
  }

  void addFailedSource(FileSystemEntity source) {
    _failedSources.add(source);
  }

  void setCancelMode(_CopyCancelMode mode) {
    _cancelMode = mode;
    navigateTo(_CopyPanelStep.cancelChoice);
  }

  void navigateTo(_CopyPanelStep step) {
    _panelHistory.add(
      _CopyPanelSnapshot(
        step: _step,
        conflictIndex: _conflictIndex,
        mode: _mode,
      ),
    );
    _step = step;
    onChanged?.call();
  }

  bool goBack() {
    if (_panelHistory.isNotEmpty) {
      final previous = _panelHistory.removeLast();
      _step = previous.step;
      _conflictIndex = previous.conflictIndex;
      _mode = previous.mode;
    } else if (_step != _CopyPanelStep.standard) {
      _step = _CopyPanelStep.standard;
    } else {
      return false;
    }
    onChanged?.call();
    return true;
  }

  void finishPaste({bool retainFailures = true}) {
    final failures = retainFailures
        ? List<FileSystemEntity>.of(_failedSources)
        : <FileSystemEntity>[];
    _destination = null;
    _nonConflicting = const [];
    _conflicts = const [];
    _conflictIndex = 0;
    _pastedCount = 0;
    _failedSources.clear();
    _panelHistory.clear();
    _step = _CopyPanelStep.standard;
    _isPasting = false;
    _startedWithMultipleConflicts = false;
    _applyAllRenameAction = null;
    _applyAllRenameSeries = false;
    _applyAllSeriesStyle = null;
    _sources = List.unmodifiable(failures);
    onChanged?.call();
  }

  void clear() => finishPaste(retainFailures: false);

  void setPasting(bool isPasting) {
    _isPasting = isPasting;
    onChanged?.call();
  }
}

class StorageTab extends ConsumerStatefulWidget {
  final String? initialPath;
  final String? displayName;
  final StorageCopySession? copySession;
  const StorageTab({
    super.key,
    this.initialPath,
    this.displayName,
    this.copySession,
  });

  @override
  StorageTabState createState() => StorageTabState();
}

class StorageTabState extends ConsumerState<StorageTab>
    with AutomaticKeepAliveClientMixin {
  // Cache listings for this app session.  Keeping the cache by path means a
  // tab can be revisited without causing another filesystem read.
  static final Map<String, List<FileSystemEntity>> _directoryCache = {};
  static final Map<String, bool> _subfolderCache = {};
  Directory? _dir;
  String? _anchorPath;
  List<String> _storageRootPaths = const [];
  List<FileSystemEntity> _items = [];
  bool _selectionMode = false;
  final Set<String> _selected = {};
  late final StorageCopySession _copySession;
  // The Settings section should control this value and refresh the current
  // directory with _loadRoot(_dir?.path, forceRefresh: true) when it changes.
  bool _showHidden = false;
  String _sortBy = 'Name';
  bool _sortAscending = true;
  final GlobalKey _menuKey = GlobalKey();

  Timer? _pressTimer;
  bool _longPressTriggered = false;

  @override
  void initState() {
    super.initState();
    _copySession = widget.copySession ?? StorageCopySession();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _copySession.notifyChanged();
    });
    _prepareAndLoadRoot(widget.initialPath);
  }

  Future<void> _prepareAndLoadRoot(String? path) async {
    if (Platform.isAndroid) {
      final storagePermission = await Permission.storage.request();
      if (!storagePermission.isGranted && !storagePermission.isLimited) {
        await Permission.manageExternalStorage.request();
      }
    }
    try {
      await ref.read(sortRulesProvider.notifier).ready;
    } catch (_) {}
    try {
      final devices = await ref
          .read(storageRepositoryProvider)
          .listStorageDevices();
      _storageRootPaths = devices.map((device) => device.path).toList();
    } catch (_) {}
    if (!mounted) return;
    _loadRoot(path);
  }

  @override
  void dispose() {
    _pressTimer?.cancel();
    _pressTimer = null;
    super.dispose();
  }

  Future<void> _loadRoot(String? path, {bool forceRefresh = false}) async {
    Directory dir;
    try {
      final sharedStorage = <Directory>[
        Directory('/storage/emulated/0'),
        Directory('/storage/self/primary'),
        Directory('/sdcard'),
      ];
      if (path != null && path.isNotEmpty) {
        dir = Directory(path);
      } else if (Platform.isAndroid) {
        // Directory.current is the app's sandbox on Android. Use the primary
        // shared volume only when no explicit storage path was provided.
        dir = sharedStorage.firstWhere(
          (candidate) => candidate.existsSync(),
          orElse: () => sharedStorage.first,
        );
      } else {
        dir = Directory.current;
      }
    } catch (_) {
      dir = Directory.current;
    }

    // set anchor path on first load so this tab won't navigate above it
    _anchorPath ??= dir.path;
    _syncSortChoice(_currentRules(), dir.path);

    final cachedItems = _directoryCache[dir.path];
    if (!forceRefresh && cachedItems != null) {
      _sortList(cachedItems, _sortBy, _sortAscending);
      if (!mounted) return;
      setState(() {
        _dir = dir;
        _items = cachedItems;
      });
      _copySession.notifyChanged();
      return;
    }

    List<FileSystemEntity> items;
    try {
      // Use the asynchronous API for shared storage. On Android, listSync()
      // can fail for an accessible directory and leave the folder empty.
      items = await dir.list(followLinks: false).toList();
      _subfolderCache[dir.path] = items.any((item) => item is Directory);
      if (!_showHidden) {
        items.removeWhere((item) => _displayName(item.path).startsWith('.'));
      }
      _sortList(items, _sortBy, _sortAscending);
    } catch (_) {
      items = [];
    }

    _directoryCache[dir.path] = items;

    if (!mounted) return;
    setState(() {
      _dir = dir;
      _items = items;
    });
    _copySession.notifyChanged();
  }

  /// Called by the shell to let this tab handle a back press.
  /// Returns true if the back was handled (e.g. navigated up), false to indicate
  /// the tab is at its root and did not handle the back.
  Future<bool> handleWillPop() async {
    if (_copySession.sources.isNotEmpty) {
      if (_copySession.goBack()) return true;
      _cancelCopyMode();
      return true;
    }
    if (_selectionMode) {
      setState(() {
        _selectionMode = false;
        _selected.clear();
      });
      return true;
    }
    if (_dir == null) return false;
    // If we're at or above the tab's anchor/root, do not handle back here.
    if (_anchorPath != null && _dir!.path == _anchorPath) return false;
    final parent = _dir!.parent;
    if (parent.path == _dir!.path) return false; // filesystem root
    // Do not navigate above the anchor path
    if (_anchorPath != null &&
        parent.path != _anchorPath &&
        !parent.path.startsWith('${_anchorPath!}${Platform.pathSeparator}')) {
      return false;
    }
    // Navigate up one folder
    _loadRoot(parent.path);
    return true;
  }

  void _openEntity(FileSystemEntity e) {
    if (_selectionMode) {
      // toggle selection
      final path = e.path;
      setState(() {
        if (_selected.contains(path)) {
          _selected.remove(path);
        } else {
          _selected.add(path);
        }
        if (_selected.isEmpty) {
          _selectionMode = false;
        }
      });
      return;
    }

    if (e is Directory) {
      _loadRoot(e.path);
      return;
    }

    if (e is File) {
      _showOpenWithApplications(e, _categoryForFile(e));
    }
  }

  List<SortRule> _currentRules() =>
      ref.read(sortRulesProvider).asData?.value ?? const <SortRule>[];

  SortRule? _resolveRule(Iterable<SortRule> rules, String folderPath) {
    final drivePath = _drivePathFor(folderPath);
    final result = resolveEffectiveSortRule(
      rules: rules,
      drivePath: drivePath,
      folderPath: folderPath,
    );
    return result;
  }

  String _drivePathFor(String folderPath) {
    final normalizedFolder = normalizeSortPath(folderPath);
    final matchingRoots =
        _storageRootPaths
            .map(normalizeSortPath)
            .where(
              (root) =>
                  normalizedFolder == root ||
                  normalizedFolder.startsWith('$root/'),
            )
            .toList()
          ..sort((left, right) => right.length.compareTo(left.length));
    return matchingRoots.isNotEmpty
        ? matchingRoots.first
        : _anchorPath ?? folderPath;
  }

  void _syncSortChoice(Iterable<SortRule> rules, String folderPath) {
    final rule = _resolveRule(rules, folderPath);
    _sortBy = switch (rule?.field) {
      SortField.dateModified => 'Date modified',
      SortField.size => 'Size',
      _ => 'Name',
    };
    _sortAscending = rule?.order != SortOrder.descending;
  }

  void _applyEffectiveSort(Iterable<SortRule> rules) {
    if (_dir == null) return;
    _syncSortChoice(rules, _dir!.path);
    setState(() {
      _sortList(_items, _sortBy, _sortAscending);
    });
    _directoryCache[_dir!.path] = _items;
  }

  Future<void> _saveSortRule({
    required SortScope scope,
    required String field,
    required bool ascending,
    bool recursive = false,
  }) async {
    final targetPath = switch (scope) {
      SortScope.all => null,
      SortScope.drive => _dir == null ? null : _drivePathFor(_dir!.path),
      SortScope.folder => _dir?.path,
    };
    if (scope != SortScope.all && targetPath == null) return;

    final rule = SortRule.create(
      scope: scope,
      targetPath: targetPath,
      recursive: recursive,
      field: switch (field) {
        'Date modified' => SortField.dateModified,
        'Size' => SortField.size,
        _ => SortField.name,
      },
      order: ascending ? SortOrder.ascending : SortOrder.descending,
    );
    if (scope != SortScope.folder && _dir != null) {
      final currentFolderPath = normalizeSortPath(_dir!.path);
      final currentFolderRule = _currentRules().where(
        (savedRule) =>
            savedRule.scope == SortScope.folder &&
            savedRule.targetPath != null &&
            normalizeSortPath(savedRule.targetPath!) == currentFolderPath,
      );
      for (final savedRule in currentFolderRule) {
        await ref.read(sortRulesProvider.notifier).delete(savedRule.id);
      }
    }
    await ref.read(sortRulesProvider.notifier).save(rule);
    // The rule may target a broader scope than the current folder. Resolve it
    // against the current path after persistence so the displayed choice and
    // ordering reflect the newly selected rule immediately.
    final rules = _currentRules();
    final effectiveRule = _dir == null ? null : _resolveRule(rules, _dir!.path);
    if (_dir != null && mounted) {
      _applyEffectiveSort(rules);
      _directoryCache[_dir!.path] = _items;
    }
    final order = ascending ? 'Ascending' : 'Descending';
    final scopeDescription = switch (scope) {
      SortScope.all => 'for all storage',
      SortScope.drive => 'for this drive',
      SortScope.folder =>
        recursive ? 'for this folder and subfolders' : 'for this folder',
    };
    if (effectiveRule != null &&
        (effectiveRule.scope != scope ||
            effectiveRule.field != rule.field ||
            effectiveRule.order != rule.order)) {
      final effectiveField = switch (effectiveRule.field) {
        SortField.dateModified => 'Date modified',
        SortField.size => 'Size',
        SortField.name => 'Name',
      };
      final effectiveOrder = effectiveRule.order == SortOrder.ascending
          ? 'Ascending'
          : 'Descending';
      final effectiveScope = switch (effectiveRule.scope) {
        SortScope.all => 'global',
        SortScope.drive => 'drive-specific',
        SortScope.folder => 'folder-specific',
      };
      _message(
        'Saved $field - $order $scopeDescription; this folder still uses its $effectiveScope rule: $effectiveField - $effectiveOrder',
      );
    } else {
      _message('Sorted by $field - $order $scopeDescription');
    }
  }

  Future<void> _saveSortForStorageDrives({
    required String field,
    required bool ascending,
    required bool includeDrivesWithRules,
  }) async {
    if (_dir == null) return;

    final currentPath = normalizeSortPath(_dir!.path);
    final currentDrivePath = normalizeSortPath(_drivePathFor(_dir!.path));
    final drivePaths = <String>{
      ..._storageRootPaths.map(normalizeSortPath),
      currentDrivePath,
    };
    final savedRules = _currentRules();
    final targetDrivePaths = drivePaths.where((drivePath) {
      if (includeDrivesWithRules || drivePath == currentDrivePath) return true;
      return !savedRules.any((savedRule) {
        if (savedRule.targetPath == null ||
            normalizeSortPath(savedRule.targetPath!) != drivePath) {
          return false;
        }
        final isApplicableScope =
            savedRule.scope == SortScope.drive ||
            savedRule.scope == SortScope.folder;
        return isApplicableScope;
      });
    }).toSet();

    final folderRulePathsToDelete = <String>{
      ...targetDrivePaths,
      if (targetDrivePaths.contains(currentDrivePath)) currentPath,
    };
    for (final savedRule in savedRules) {
      if (savedRule.scope == SortScope.all ||
          (savedRule.scope == SortScope.folder &&
              savedRule.targetPath != null &&
              folderRulePathsToDelete.contains(
                normalizeSortPath(savedRule.targetPath!),
              ))) {
        await ref.read(sortRulesProvider.notifier).delete(savedRule.id);
      }
    }

    final sortField = switch (field) {
      'Date modified' => SortField.dateModified,
      'Size' => SortField.size,
      _ => SortField.name,
    };
    for (final drivePath in targetDrivePaths) {
      await ref
          .read(sortRulesProvider.notifier)
          .save(
            SortRule.create(
              scope: SortScope.drive,
              targetPath: drivePath,
              field: sortField,
              order: ascending ? SortOrder.ascending : SortOrder.descending,
            ),
          );
    }

    final rules = _currentRules();
    final effectiveRule = _resolveRule(rules, currentPath);
    if (mounted) _applyEffectiveSort(rules);

    final order = ascending ? 'Ascending' : 'Descending';
    final scopeDescription = includeDrivesWithRules
        ? 'for all storage drives'
        : 'for storage drives without a sorting rule';
    if (effectiveRule != null &&
        (effectiveRule.field != sortField ||
            effectiveRule.order !=
                (ascending ? SortOrder.ascending : SortOrder.descending))) {
      final effectiveField = switch (effectiveRule.field) {
        SortField.dateModified => 'Date modified',
        SortField.size => 'Size',
        SortField.name => 'Name',
      };
      final effectiveOrder = effectiveRule.order == SortOrder.ascending
          ? 'Ascending'
          : 'Descending';
      _message(
        'Saved $field - $order $scopeDescription; this folder still uses its more specific rule: $effectiveField - $effectiveOrder',
      );
    } else {
      _message('Sorted by $field - $order $scopeDescription');
    }
  }

  void _sortList(List<FileSystemEntity> items, String field, bool ascending) {
    final foldersFirst = ref.read(foldersFirstProvider);
    items.sort((a, b) {
      final aIsDirectory = a is Directory;
      final bIsDirectory = b is Directory;
      if (foldersFirst && aIsDirectory != bIsDirectory) {
        return aIsDirectory ? -1 : 1;
      }

      int result;
      switch (field) {
        case 'Date modified':
          result = _modified(a).compareTo(_modified(b));
          break;
        case 'Size':
          result = _size(a).compareTo(_size(b));
          break;
        case 'Type':
          result = a.path
              .split('.')
              .last
              .toLowerCase()
              .compareTo(b.path.split('.').last.toLowerCase());
          break;
        default:
          result = _displayName(
            a.path,
          ).toLowerCase().compareTo(_displayName(b.path).toLowerCase());
      }
      return ascending ? result : -result;
    });
  }

  DateTime _modified(FileSystemEntity entity) {
    try {
      return entity.statSync().modified;
    } on FileSystemException {
      return DateTime.fromMillisecondsSinceEpoch(0);
    }
  }

  int _size(FileSystemEntity entity) {
    if (entity is! File) return 0;
    try {
      return entity.lengthSync();
    } on FileSystemException {
      return 0;
    }
  }

  void _message(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  Future<void> _showSortMenu() async {
    final box = _menuKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) {
      _message('Sort menu is unavailable');
      return;
    }
    final origin = box.localToGlobal(Offset.zero);
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final rect = Rect.fromLTWH(
      origin.dx,
      origin.dy,
      box.size.width,
      box.size.height,
    );
    final position = RelativeRect.fromRect(rect, Offset.zero & overlay.size);
    final options = <MapEntry<String, bool>>[
      MapEntry('Name', true),
      MapEntry('Name', false),
      MapEntry('Date modified', true),
      MapEntry('Date modified', false),
      MapEntry('Size', true),
      MapEntry('Size', false),
    ];
    final rules = _currentRules();
    final activeRule = _dir == null ? null : _resolveRule(rules, _dir!.path);
    final choice = await showMenu<int>(
      context: context,
      position: position,
      items: [
        for (var i = 0; i < options.length; i++)
          PopupMenuItem(
            value: i,
            child: Text(
              '${options[i].key} - ${options[i].value ? 'Ascending' : 'Descending'}',
              style:
                  options[i].key == _sortBy &&
                      options[i].value == _sortAscending
                  ? const TextStyle(fontWeight: FontWeight.bold)
                  : null,
            ),
          ),
      ],
    );
    if (choice == null) return;
    if (!mounted) return;
    final option = options[choice];

    final scopes = [SortScope.drive, SortScope.folder];
    final scopeChoice = await showMenu<int>(
      context: context,
      position: position,
      items: [
        const PopupMenuItem(
          value: 0,
          child: Text('Apply to all storage drives'),
        ),
        for (var i = 0; i < scopes.length; i++)
          PopupMenuItem(
            value: i + 1,
            child: Text(
              scopes[i] == SortScope.drive
                  ? 'Apply to the current storage drive'
                  : 'Apply to the current folder',
              style: activeRule?.scope == scopes[i]
                  ? const TextStyle(fontWeight: FontWeight.bold)
                  : null,
            ),
          ),
      ],
    );
    if (scopeChoice == null) return;
    if (!mounted) return;

    try {
      if (scopeChoice == 0) {
        final allDriveChoice = await showMenu<int>(
          context: context,
          position: position,
          items: const [
            PopupMenuItem(value: 0, child: Text('Apply to all storage drives')),
            PopupMenuItem(
              value: 1,
              child: Text('Apply to all storage drives without a sorting rule'),
            ),
          ],
        );
        if (allDriveChoice == null) return;
        await _saveSortForStorageDrives(
          field: option.key,
          ascending: option.value,
          includeDrivesWithRules: allDriveChoice == 0,
        );
        return;
      }

      final scope = scopes[scopeChoice - 1];
      if (scope == SortScope.folder && _hasSubfolders()) {
        final currentFolderRule = rules.where(
          (rule) =>
              rule.scope == SortScope.folder &&
              rule.targetPath == normalizeSortPath(_dir!.path),
        );
        final existingExactRule = currentFolderRule.isEmpty
            ? null
            : currentFolderRule.first;
        final recursiveChoice = await showMenu<int>(
          context: context,
          position: position,
          items: [
            PopupMenuItem(
              value: 0,
              child: Text(
                'Apply to this folder only',
                style: existingExactRule?.recursive == false
                    ? const TextStyle(fontWeight: FontWeight.bold)
                    : null,
              ),
            ),
            PopupMenuItem(
              value: 1,
              child: Text(
                'Apply to all folders inside the current folder',
                style: existingExactRule?.recursive == true
                    ? const TextStyle(fontWeight: FontWeight.bold)
                    : null,
              ),
            ),
          ],
        );
        if (recursiveChoice == null) return;
        await _saveSortRule(
          scope: scope,
          field: option.key,
          ascending: option.value,
          recursive: recursiveChoice == 1,
        );
      } else {
        await _saveSortRule(
          scope: scope,
          field: option.key,
          ascending: option.value,
        );
      }
    } catch (_) {
      _message('Cannot sort: file details are unavailable');
    }
  }

  bool _hasSubfolders() =>
      _dir != null &&
      (_subfolderCache[_dir!.path] ??
          _items.any((entity) => entity is Directory));

  Future<void> _showFolderProperties(List<FileSystemEntity> entities) async {
    if (entities.isEmpty) {
      _message('No item is available for properties');
      return;
    }
    var bytes = 0;
    DateTime? modified;
    try {
      for (final entity in entities) {
        if (entity is File) bytes += await entity.length();
        final date = (await entity.stat()).modified;
        if (modified == null || date.isAfter(modified)) modified = date;
      }
      if (entities.length == 1 && entities.first is Directory) {
        await for (final entity in (entities.first as Directory).list(
          recursive: true,
          followLinks: false,
        )) {
          if (entity is File) bytes += await entity.length();
        }
      }
      if (!mounted) return;
      if (entities.length == 1) {
        final item = entities.first;
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Properties'),
            content: Text(
              'Name: ${_displayName(item.path)}\nPath: ${item.path}\nItem count: ${item is Directory ? _items.length : 1}\nTotal size: $bytes bytes\nLast modified: ${modified ?? 'Unavailable'}',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      } else {
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Properties'),
            content: Text('${entities.length} items\nTotal size: $bytes bytes'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
      if (mounted) _message('Properties shown');
    } catch (_) {
      if (mounted) {
        _message(
          'Cannot read properties: permission denied or item unavailable',
        );
      }
    }
  }

  Future<void> _renameSelected() async {
    if (_selected.length > 1) {
      await _batchRenameSelected();
      return;
    }
    if (_selected.length != 1) {
      _message('Rename requires exactly one selected item');
      return;
    }
    final item = _items.where((e) => _selected.contains(e.path)).firstOrNull;
    if (item == null) {
      _message('Cannot rename: selected item is unavailable');
      return;
    }
    final name = await _promptForAvailableName(
      title: 'Rename',
      parentPath: item.parent.path,
      initialName: _displayName(item.path),
      allowedExistingPath: item.path,
    );
    if (name == null || !mounted) return;
    final target =
        '${item.parent.path}${item.parent.path.endsWith(Platform.pathSeparator) ? '' : Platform.pathSeparator}$name';
    if (target == item.path) return;
    try {
      if (item is File) {
        await item.rename(target);
      } else if (item is Directory) {
        await item.rename(target);
      } else {
        if (mounted) _message('Cannot rename: this item type is unsupported');
        return;
      }
      setState(() {
        _selected.clear();
        _selectionMode = false;
      });
      await _loadRoot(_dir?.path, forceRefresh: true);
      if (mounted) _message('Renamed to $name');
    } on FileSystemException catch (e) {
      if (mounted) {
        _message(
          e.osError?.errorCode == 13
              ? 'Permission denied'
              : 'Cannot rename: ${e.message}',
        );
      }
    }
  }

  Future<void> _batchRenameSelected() async {
    final selectedByPath = {for (final item in _items) item.path: item};
    final selectionOrder = _selected
        .map((path) => selectedByPath[path])
        .whereType<FileSystemEntity>()
        .toList();
    if (selectionOrder.length != _selected.length || _dir == null) {
      _message(
        'Cannot batch rename: one or more selected items are unavailable',
      );
      return;
    }

    final order = await _chooseBatchRenameOrder();
    if (!mounted || order == null) return;
    final scope = await _chooseBatchRenameScope();
    if (!mounted || scope == null) return;

    final baseName = await _promptBatchText(
      title: 'Batch rename',
      label: 'Base name',
      help: 'The item number is appended to this name in the chosen order.',
    );
    if (!mounted || baseName == null) return;
    if (baseName.trim().isEmpty || !_isValidNewName(baseName)) {
      _message('Cannot batch rename: enter a valid base name');
      return;
    }

    String? extension;
    if (scope == _BatchRenameScope.nameAndExtension) {
      extension = await _promptBatchText(
        title: 'New extension',
        label: 'Extension',
        help: 'Enter an extension such as jpg. Do not include the leading dot.',
      );
      if (!mounted || extension == null) return;
      extension = extension.trim().replaceFirst(RegExp(r'^\.'), '');
      if (extension.isEmpty ||
          extension.contains('/') ||
          extension.contains('\\')) {
        _message('Cannot batch rename: enter a valid extension');
        return;
      }
    }

    final orderedItems = order == _BatchRenameOrder.selection
        ? selectionOrder
        : _items.where((item) => _selected.contains(item.path)).toList();
    final entries = <_BatchRenameEntry>[];
    for (var index = 0; index < orderedItems.length; index++) {
      final item = orderedItems[index];
      final oldName = _displayName(item.path);
      final fileExtension = item is File
          ? scope == _BatchRenameScope.nameOnly
                ? _fileExtension(oldName)
                : '.$extension'
          : '';
      entries.add(
        _BatchRenameEntry(
          source: item,
          oldName: oldName,
          targetName: '$baseName${index + 1}$fileExtension',
        ),
      );
    }

    while (mounted) {
      final collisions = await _findBatchRenameCollisions(entries);
      final decision = await _showBatchRenamePreview(entries, collisions);
      if (!mounted || decision == null) return;
      if (collisions.isNotEmpty) {
        if (decision != true) return;
        final resolved = await _resolveBatchRenameCollisions(
          entries,
          collisions,
        );
        if (!mounted || !resolved) return;
        continue;
      }
      if (decision != true) return;
      await _applyBatchRename(entries);
      return;
    }
  }

  Future<_BatchRenameOrder?> _chooseBatchRenameOrder() =>
      showDialog<_BatchRenameOrder>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Number items in'),
          content: const Text(
            'Choose the order used to assign numbers across files and folders.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () =>
                  Navigator.pop(dialogContext, _BatchRenameOrder.selection),
              child: const Text('Selection order'),
            ),
            TextButton(
              onPressed: () =>
                  Navigator.pop(dialogContext, _BatchRenameOrder.currentSort),
              child: const Text('Current sort order'),
            ),
          ],
        ),
      );

  Future<_BatchRenameScope?>
  _chooseBatchRenameScope() => showDialog<_BatchRenameScope>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Rename scope'),
      content: const Text(
        'Choose whether files keep their extensions or receive a new extension.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () =>
              Navigator.pop(dialogContext, _BatchRenameScope.nameOnly),
          child: const Text('Name only'),
        ),
        TextButton(
          onPressed: () =>
              Navigator.pop(dialogContext, _BatchRenameScope.nameAndExtension),
          child: const Text('Name and extension'),
        ),
      ],
    ),
  );

  Future<String?> _promptBatchText({
    required String title,
    required String label,
    required String help,
  }) => showDialog<String>(
    context: context,
    builder: (_) => _BatchTextDialog(title: title, label: label, help: help),
  );

  Future<List<_BatchRenameCollision>> _findBatchRenameCollisions(
    List<_BatchRenameEntry> entries,
  ) async {
    final activeEntries = entries.where((entry) => !entry.skipped).toList();
    final selectedPaths = activeEntries
        .map((entry) => entry.source.path)
        .toSet();
    final collisions = <_BatchRenameCollision>[];
    final plannedNames = <String, _BatchRenameEntry>{};

    for (final entry in activeEntries) {
      final prior = plannedNames.entries.where(
        (planned) => _sameFileName(planned.key, entry.targetName),
      );
      if (prior.isNotEmpty) {
        collisions.add(
          _BatchRenameCollision(
            entry: entry,
            occupantName: prior.first.value.oldName,
            isDuplicatePlan: true,
          ),
        );
        continue;
      }
      plannedNames[entry.targetName] = entry;

      final targetPath = _targetPath(_dir!.path, entry.targetName);
      final existing = await _entityAtPath(targetPath);
      if (existing == null || selectedPaths.contains(existing.path)) continue;
      if (entry.overwrite) continue;
      collisions.add(
        _BatchRenameCollision(
          entry: entry,
          occupantName: _displayName(existing.path),
        ),
      );
    }
    return collisions;
  }

  Future<bool?> _showBatchRenamePreview(
    List<_BatchRenameEntry> entries,
    List<_BatchRenameCollision> collisions,
  ) => showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(
        collisions.isEmpty
            ? 'Review batch rename'
            : '${collisions.length} name collision${collisions.length == 1 ? '' : 's'} found',
      ),
      content: SizedBox(
        width: 460,
        height: 360,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (collisions.isNotEmpty)
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text(
                  'Nothing has been renamed. Resolve collisions or cancel the whole batch.',
                ),
              ),
            Expanded(
              child: ListView.builder(
                itemCount: entries.length,
                itemBuilder: (context, index) {
                  final entry = entries[index];
                  final collision = collisions
                      .where((item) => identical(item.entry, entry))
                      .firstOrNull;
                  final detail = entry.skipped
                      ? 'Skipped'
                      : collision != null
                      ? collision.isDuplicatePlan
                            ? 'Also assigned to ${collision.occupantName}'
                            : 'Conflicts with ${collision.occupantName}'
                      : entry.overwrite
                      ? 'Will overwrite existing item'
                      : null;
                  return ListTile(
                    dense: true,
                    title: Text(
                      '${entry.oldName}  →  ${entry.skipped ? 'Skip' : entry.targetName}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: detail == null ? null : Text(detail),
                    textColor: collision == null
                        ? null
                        : Theme.of(context).colorScheme.error,
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: Text(collisions.isEmpty ? 'Cancel' : 'Cancel whole rename'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: Text(
            collisions.isEmpty ? 'Rename items' : 'Resolve collisions',
          ),
        ),
      ],
    ),
  );

  Future<bool> _resolveBatchRenameCollisions(
    List<_BatchRenameEntry> entries,
    List<_BatchRenameCollision> collisions,
  ) async {
    final allCanOverwrite = collisions.every(
      (collision) => !collision.isDuplicatePlan,
    );
    final choice = await showDialog<_BatchCollisionChoice>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('${collisions.length} collisions need a decision'),
        content: SizedBox(
          width: 420,
          height: 280,
          child: ListView(
            children: collisions
                .map(
                  (collision) => ListTile(
                    dense: true,
                    title: Text(
                      '${collision.entry.oldName}  →  ${collision.entry.targetName}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      collision.isDuplicatePlan
                          ? 'Duplicates another generated name'
                          : 'Already exists: ${collision.occupantName}',
                    ),
                  ),
                )
                .toList(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () =>
                Navigator.pop(dialogContext, _BatchCollisionChoice.cancel),
            child: const Text('Cancel whole rename'),
          ),
          if (collisions.length > 1) ...[
            if (allCanOverwrite)
              TextButton(
                onPressed: () => Navigator.pop(
                  dialogContext,
                  _BatchCollisionChoice.overwrite,
                ),
                child: const Text('Overwrite all'),
              ),
            TextButton(
              onPressed: () =>
                  Navigator.pop(dialogContext, _BatchCollisionChoice.rename),
              child: const Text('Choose names for all'),
            ),
            TextButton(
              onPressed: () =>
                  Navigator.pop(dialogContext, _BatchCollisionChoice.skip),
              child: const Text('Skip all'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(
                dialogContext,
                _BatchCollisionChoice.resolveOneByOne,
              ),
              child: const Text('Resolve individually'),
            ),
          ] else ...[
            if (!collisions.single.isDuplicatePlan)
              TextButton(
                onPressed: () => Navigator.pop(
                  dialogContext,
                  _BatchCollisionChoice.overwrite,
                ),
                child: const Text('Overwrite'),
              ),
            TextButton(
              onPressed: () =>
                  Navigator.pop(dialogContext, _BatchCollisionChoice.rename),
              child: const Text('Choose a different name'),
            ),
            TextButton(
              onPressed: () =>
                  Navigator.pop(dialogContext, _BatchCollisionChoice.skip),
              child: const Text('Skip item'),
            ),
          ],
        ],
      ),
    );
    if (!mounted || choice == null || choice == _BatchCollisionChoice.cancel) {
      return false;
    }

    switch (choice) {
      case _BatchCollisionChoice.cancel:
        return false;
      case _BatchCollisionChoice.overwrite:
        for (final collision in collisions) {
          if (collision.isDuplicatePlan) return false;
          collision.entry.overwrite = true;
        }
      case _BatchCollisionChoice.skip:
        for (final collision in collisions) {
          collision.entry.skipped = true;
        }
      case _BatchCollisionChoice.rename:
        for (final collision in collisions) {
          final accepted = await _chooseDifferentBatchName(
            collision.entry,
            entries,
          );
          if (!accepted) return false;
        }
      case _BatchCollisionChoice.resolveOneByOne:
        for (final collision in collisions) {
          if (collision.entry.skipped) continue;
          final itemChoice = await _chooseSingleBatchCollision(collision);
          if (!mounted ||
              itemChoice == null ||
              itemChoice == _BatchCollisionChoice.cancel) {
            return false;
          }
          switch (itemChoice) {
            case _BatchCollisionChoice.overwrite:
              if (collision.isDuplicatePlan) return false;
              collision.entry.overwrite = true;
            case _BatchCollisionChoice.rename:
              if (!await _chooseDifferentBatchName(collision.entry, entries)) {
                return false;
              }
            case _BatchCollisionChoice.skip:
              collision.entry.skipped = true;
            case _BatchCollisionChoice.cancel:
            case _BatchCollisionChoice.resolveOneByOne:
              return false;
          }
        }
    }
    return true;
  }

  Future<_BatchCollisionChoice?> _chooseSingleBatchCollision(
    _BatchRenameCollision collision,
  ) => showDialog<_BatchCollisionChoice>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('Name already exists: ${collision.entry.targetName}'),
      content: Text(
        collision.isDuplicatePlan
            ? 'Another selected item has the same generated name.'
            : 'This name is used by ${collision.occupantName}.',
      ),
      actions: [
        TextButton(
          onPressed: () =>
              Navigator.pop(dialogContext, _BatchCollisionChoice.cancel),
          child: const Text('Cancel whole rename'),
        ),
        if (!collision.isDuplicatePlan)
          TextButton(
            onPressed: () =>
                Navigator.pop(dialogContext, _BatchCollisionChoice.overwrite),
            child: const Text('Overwrite'),
          ),
        TextButton(
          onPressed: () =>
              Navigator.pop(dialogContext, _BatchCollisionChoice.rename),
          child: const Text('Choose a different name'),
        ),
        TextButton(
          onPressed: () =>
              Navigator.pop(dialogContext, _BatchCollisionChoice.skip),
          child: const Text('Skip item'),
        ),
      ],
    ),
  );

  Future<bool> _chooseDifferentBatchName(
    _BatchRenameEntry entry,
    List<_BatchRenameEntry> entries,
  ) async {
    while (mounted) {
      final name = await _promptBatchText(
        title: 'Choose a different name',
        label: 'New name for ${entry.oldName}',
        help: 'Enter the complete new name, including its extension if needed.',
      );
      if (!mounted || name == null) return false;
      if (!_isValidNewName(name) || name.trim().isEmpty) {
        _message('Cannot rename: enter a valid name');
        continue;
      }
      final targetPath = _targetPath(_dir!.path, name);
      final collidesWithPlan = entries.any(
        (other) =>
            !identical(other, entry) &&
            !other.skipped &&
            _sameFileName(other.targetName, name),
      );
      final existing = await _entityAtPath(targetPath);
      final selectedSourcePaths = entries
          .map((item) => item.source.path)
          .toSet();
      final collidesWithOutside =
          existing != null && !selectedSourcePaths.contains(existing.path);
      if (collidesWithPlan || collidesWithOutside) {
        _message(
          collidesWithPlan
              ? 'Cannot use "$name": another item is assigned that name.'
              : 'Cannot use "$name": it already exists in this folder.',
        );
        continue;
      }
      entry.targetName = name;
      entry.overwrite = false;
      return true;
    }
    return false;
  }

  Future<void> _applyBatchRename(List<_BatchRenameEntry> entries) async {
    final active = entries.where((entry) => !entry.skipped).toList();
    final stagedPaths = <_BatchRenameEntry, String>{};
    final results = <_BatchRenameResult>[];
    final selectedPaths = entries.map((entry) => entry.source.path).toSet();

    for (final entry in active) {
      try {
        final temporaryPath = await _uniqueSiblingPath(
          _dir!.path,
          'batch-rename',
        );
        await entry.source.rename(temporaryPath);
        stagedPaths[entry] = temporaryPath;
      } on FileSystemException catch (error) {
        results.add(
          _BatchRenameResult(
            entry: entry,
            status: 'Failed',
            error: error.message,
          ),
        );
      } catch (error) {
        results.add(
          _BatchRenameResult(entry: entry, status: 'Failed', error: '$error'),
        );
      }
    }

    for (final entry in active) {
      final temporaryPath = stagedPaths[entry];
      if (temporaryPath == null) continue;
      final targetPath = _targetPath(_dir!.path, entry.targetName);
      String? backupPath;
      try {
        final existing = await _entityAtPath(targetPath);
        if (existing != null) {
          if (!entry.overwrite || selectedPaths.contains(existing.path)) {
            throw FileSystemException(
              'The destination became occupied during batch rename',
              targetPath,
            );
          }
          backupPath = await _uniqueSiblingPath(_dir!.path, 'batch-overwrite');
          await existing.rename(backupPath);
        }
        await _renamePath(temporaryPath, targetPath);
        stagedPaths.remove(entry);
        if (backupPath != null) {
          try {
            await _deletePath(backupPath);
          } catch (error) {
            results.add(
              _BatchRenameResult(
                entry: entry,
                status: 'Renamed; cleanup warning',
                error: 'Could not remove overwritten item backup: $error',
              ),
            );
            continue;
          }
        }
        results.add(_BatchRenameResult(entry: entry, status: 'Renamed'));
      } on FileSystemException catch (error) {
        if (backupPath != null) {
          try {
            await _renamePath(backupPath, targetPath);
          } catch (restoreError) {
            results.add(
              _BatchRenameResult(
                entry: entry,
                status: 'Failed; restore failed',
                error:
                    '${error.message}; could not restore overwritten item: $restoreError',
              ),
            );
            continue;
          }
        }
        results.add(
          _BatchRenameResult(
            entry: entry,
            status: 'Failed',
            error: error.message,
          ),
        );
      } catch (error) {
        if (backupPath != null) {
          try {
            await _renamePath(backupPath, targetPath);
          } catch (restoreError) {
            results.add(
              _BatchRenameResult(
                entry: entry,
                status: 'Failed; restore failed',
                error:
                    '$error; could not restore overwritten item: $restoreError',
              ),
            );
            continue;
          }
        }
        results.add(
          _BatchRenameResult(entry: entry, status: 'Failed', error: '$error'),
        );
      }
    }

    for (final entry in entries.where((item) => item.skipped)) {
      results.add(_BatchRenameResult(entry: entry, status: 'Skipped'));
    }
    for (final entry in stagedPaths.keys.toList()) {
      try {
        final originalPath = entry.source.path;
        if (await FileSystemEntity.type(originalPath, followLinks: false) ==
            FileSystemEntityType.notFound) {
          await _renamePath(stagedPaths[entry]!, originalPath);
        }
      } catch (_) {}
    }

    if (_dir != null && mounted) {
      final successfulSources = results
          .where((result) => result.status.startsWith('Renamed'))
          .map((result) => result.entry.source.path)
          .toSet();
      setState(() {
        _selected.removeWhere(successfulSources.contains);
        if (_selected.isEmpty) _selectionMode = false;
      });
      await _loadRoot(_dir!.path, forceRefresh: true);
    }
    if (mounted) await _showBatchRenameResults(results);
  }

  Future<void> _showBatchRenameResults(
    List<_BatchRenameResult> results,
  ) => showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Batch rename results'),
      content: SizedBox(
        width: 460,
        height: 360,
        child: ListView.builder(
          itemCount: results.length,
          itemBuilder: (context, index) {
            final result = results[index];
            return ListTile(
              dense: true,
              title: Text(
                '${result.entry.oldName}  →  ${result.status == 'Skipped' ? 'Skipped' : result.entry.targetName}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: result.error == null ? null : Text(result.error!),
              leading: Icon(
                result.status.startsWith('Renamed')
                    ? Icons.check_circle_outline
                    : result.status == 'Skipped'
                    ? Icons.skip_next
                    : Icons.error_outline,
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('Close'),
        ),
      ],
    ),
  );

  Future<void> _showCreateMenu() async {
    final box = _menuKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) {
      _message('Create menu is unavailable');
      return;
    }
    final origin = box.localToGlobal(Offset.zero);
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final position = RelativeRect.fromRect(
      Rect.fromLTWH(origin.dx, origin.dy, box.size.width, box.size.height),
      Offset.zero & overlay.size,
    );
    final choice = await showMenu<String>(
      context: context,
      position: position,
      items: const [
        PopupMenuItem(value: 'file', child: Text('File')),
        PopupMenuItem(value: 'folder', child: Text('Folder')),
      ],
    );
    if (!mounted || choice == null) return;
    if (_dir == null) {
      _message('Cannot create: current folder is unavailable');
      return;
    }
    if (choice == 'file') {
      await _createFile();
    } else {
      await _createFolder();
    }
  }

  Future<String?> _promptForNewName({
    required String title,
    required String extensionNote,
    String initialName = '',
  }) async {
    return showDialog<String>(
      context: context,
      builder: (_) => _NewNameDialog(
        title: title,
        extensionNote: extensionNote,
        initialName: initialName,
      ),
    );
  }

  Future<String?> _promptForAvailableName({
    required String title,
    required String parentPath,
    required String initialName,
    String? allowedExistingPath,
  }) async {
    final name = await _promptForNewName(
      title: title,
      extensionNote: '',
      initialName: initialName,
    );
    if (!mounted || name == null) return null;
    if (!_isValidNewName(name)) {
      _message('Cannot rename: enter a valid name');
      return null;
    }
    final target =
        '$parentPath${parentPath.endsWith(Platform.pathSeparator) ? '' : Platform.pathSeparator}$name';
    if (target != allowedExistingPath &&
        await FileSystemEntity.type(target, followLinks: false) !=
            FileSystemEntityType.notFound) {
      _message('Cannot rename: a file with this name already exists');
      return null;
    }
    return name;
  }

  bool _isValidNewName(String name) =>
      name.isNotEmpty &&
      name != '.' &&
      name != '..' &&
      !name.contains('/') &&
      !name.contains('\\');

  Future<void> _createFile() async {
    final name = await _promptForNewName(
      title: 'Create File',
      extensionNote:
          'If you do not specify an extension, the file will be created as a .txt file.',
    );
    if (!mounted || name == null) return;
    if (!_isValidNewName(name)) {
      _message('Cannot create file: enter a valid file name');
      return;
    }

    final hasExtension =
        name.lastIndexOf('.') > 0 && name.lastIndexOf('.') < name.length - 1;
    final fileName = hasExtension ? name : '$name.txt';
    final file = File('${_dir!.path}${Platform.pathSeparator}$fileName');
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      if (mounted) {
        _message(
          'A file named "$fileName" already exists in this folder. Choose a different name.',
        );
      }
      return;
    }
    try {
      await file.create(exclusive: true);
      await _loadRoot(_dir!.path, forceRefresh: true);
      if (mounted) _message('Created file $fileName');
    } on FileSystemException catch (error) {
      if (mounted) {
        _message(
          error.osError?.errorCode == 13
              ? 'Permission denied'
              : 'Cannot create file: ${error.message}',
        );
      }
    }
  }

  Future<void> _createFolder() async {
    final name = await _promptForNewName(
      title: 'Create Folder',
      extensionNote: '',
    );
    if (!mounted || name == null) return;
    if (!_isValidNewName(name)) {
      _message('Cannot create folder: enter a valid folder name');
      return;
    }

    final directory = Directory('${_dir!.path}${Platform.pathSeparator}$name');
    if (await FileSystemEntity.type(directory.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      if (mounted) {
        _message(
          'A folder named "$name" already exists in this folder. Choose a different name.',
        );
      }
      return;
    }
    try {
      await directory.create();
      await _loadRoot(_dir!.path, forceRefresh: true);
      if (mounted) _message('Created folder $name');
    } on FileSystemException catch (error) {
      if (mounted) {
        _message(
          error.osError?.errorCode == 13
              ? 'Permission denied'
              : 'Cannot create folder: ${error.message}',
        );
      }
    }
  }

  List<PopupMenuEntry<String>> _menuItems() {
    if (_selectionMode && _selected.isNotEmpty) {
      final entries = <PopupMenuEntry<String>>[
        const PopupMenuItem(value: 'rename', child: Text('Rename')),
        const PopupMenuItem(value: 'delete', child: Text('Delete')),
        const PopupMenuItem(value: 'copy', child: Text('Copy')),
        const PopupMenuItem(value: 'select_all', child: Text('Select All')),
        const PopupMenuItem(value: 'properties', child: Text('Properties')),
      ];
      if (_selected.length == 1) {
        final selectedPath = _selected.first;
        final selectedItem = _items
            .where((item) => item.path == selectedPath)
            .firstOrNull;
        if (selectedItem is File) {
          entries.insert(
            1,
            const PopupMenuItem(value: 'open_as', child: Text('Open as')),
          );
        }
      }
      return entries;
    }
    return [
      const PopupMenuItem(value: 'select', child: Text('Select')),
      const PopupMenuItem(value: 'select_all', child: Text('Select All')),
      const PopupMenuItem(value: 'sort', child: Text('Sort by')),
      const PopupMenuItem(value: 'create', child: Text('Create')),
    ];
  }

  void _handleMenu(String value) {
    switch (value) {
      case 'select':
        setState(() => _selectionMode = true);
        _message('Selection mode enabled');
        break;
      case 'select_all':
        setState(() {
          _selectionMode = true;
          _selected.addAll(_items.map((e) => e.path));
        });
        _message('${_items.length} items selected');
        break;
      case 'hidden':
        setState(() => _showHidden = !_showHidden);
        _loadRoot(_dir?.path, forceRefresh: true).then(
          (_) => _message(
            _showHidden
                ? 'Show hidden files enabled'
                : 'Show hidden files disabled',
          ),
        );
        break;
      case 'sort':
        _showSortMenu();
        break;
      case 'create':
        _showCreateMenu();
        break;
      case 'properties':
        _showFolderProperties(
          _selectionMode
              ? _items.where((e) => _selected.contains(e.path)).toList()
              : (_dir == null ? [] : [_dir!]),
        );
        break;
      case 'delete':
        _deleteSelected();
        break;
      case 'rename':
        _renameSelected();
        break;
      case 'open_as':
        _showOpenAsCategories();
        break;
      case 'copy':
        final itemsByPath = {for (final item in _items) item.path: item};
        final sources = _selected
            .map((path) => itemsByPath[path])
            .whereType<FileSystemEntity>()
            .toList();
        if (sources.isEmpty) {
          _message('Copy is not available: no items are selected');
          break;
        }
        setState(() {
          _selected.clear();
          _selectionMode = false;
        });
        _copySession.setSources(sources);
        break;
    }
  }

  Future<void> _showOpenAsCategories() async {
    if (_selected.length != 1) return;
    final path = _selected.single;
    final item = _items.where((entry) => entry.path == path).firstOrNull;
    if (item is! File) {
      _message('Open as is available for one selected file');
      return;
    }
    final category = await showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: Text('Open ${_displayName(item.path)} as'),
        children: [
          for (final choice in const [
            ('Text', Icons.description_outlined),
            ('Image', Icons.image_outlined),
            ('Audio', Icons.audiotrack_outlined),
            ('Video', Icons.video_file_outlined),
            ('Others', Icons.insert_drive_file_outlined),
          ])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialogContext, choice.$1),
              child: Row(
                children: [
                  Icon(choice.$2),
                  const SizedBox(width: 12),
                  Text(choice.$1),
                ],
              ),
            ),
        ],
      ),
    );
    if (!mounted || category == null) return;
    await _showOpenWithApplications(item, category);
  }

  String _categoryForFile(File file) {
    final extension = _fileExtension(_displayName(file.path)).toLowerCase();
    if (const {
      '.txt',
      '.text',
      '.md',
      '.markdown',
      '.json',
      '.csv',
      '.tsv',
      '.xml',
      '.html',
      '.htm',
      '.css',
      '.js',
      '.ts',
      '.dart',
      '.kt',
      '.java',
      '.py',
      '.yaml',
      '.yml',
      '.log',
      '.ini',
      '.cfg',
      '.conf',
      '.sh',
      '.c',
      '.h',
      '.cpp',
      '.sql',
      '.toml',
      '.properties',
    }.contains(extension)) {
      return 'Text';
    }
    if (const {
      '.png',
      '.jpg',
      '.jpeg',
      '.gif',
      '.bmp',
      '.webp',
      '.heic',
      '.svg',
    }.contains(extension)) {
      return 'Image';
    }
    if (const {
      '.mp3',
      '.wav',
      '.ogg',
      '.m4a',
      '.flac',
      '.aac',
    }.contains(extension)) {
      return 'Audio';
    }
    if (const {
      '.mp4',
      '.mkv',
      '.mov',
      '.avi',
      '.webm',
      '.3gp',
    }.contains(extension)) {
      return 'Video';
    }
    return 'Others';
  }

  Future<void> _showOpenWithApplications(
    File file,
    String category, {
    bool checkSavedDefault = true,
  }) async {
    final extension = _fileExtension(_displayName(file.path));
    var effectiveCategory = category;
    if (checkSavedDefault && extension.isNotEmpty) {
      final DefaultFileApp? savedDefault;
      try {
        savedDefault = await ref
            .read(defaultFileAppsProvider.notifier)
            .find(extension);
      } catch (error) {
        if (mounted) _message('Could not load saved default apps: $error');
        return;
      }
      if (savedDefault != null) {
        if (savedDefault.isTextEditor) {
          TabsManager.instance.openTextEditor(file.path);
          return;
        }
        final packageName = savedDefault.packageName;
        final repository = ref.read(openWithRepositoryProvider);
        if (packageName != null && packageName.isNotEmpty) {
          try {
            final availableApps = await repository.listApps(
              path: file.path,
              category: savedDefault.category,
            );
            final isAvailable = availableApps.any(
              (app) => app.packageName == packageName,
            );
            if (isAvailable) {
              await repository.openFile(
                path: file.path,
                category: savedDefault.category,
                packageName: packageName,
                mimeType: savedDefault.mimeType,
              );
              return;
            }
          } on PlatformException catch (error) {
            if (error.code != 'APP_UNAVAILABLE') {
              if (mounted) {
                _message(
                  error.message ?? 'Could not open ${_displayName(file.path)}',
                );
              }
              return;
            }
          } catch (error) {
            if (mounted) {
              _message('Could not open ${_displayName(file.path)}: $error');
            }
            return;
          }
        }
        try {
          await ref.read(defaultFileAppsProvider.notifier).delete(extension);
        } catch (error) {
          if (mounted) {
            _message('Could not clear the unavailable default app: $error');
          }
          return;
        }
        if (!mounted) return;
        _message(
          'The app previously used to open $extension files is no longer available',
        );
        effectiveCategory = savedDefault.category;
      }
    }

    final List<OpenWithApp> apps;
    try {
      apps = await ref
          .read(openWithRepositoryProvider)
          .listApps(path: file.path, category: effectiveCategory);
    } on PlatformException catch (error) {
      if (mounted) {
        _message(error.message ?? 'Could not find applications for this file');
      }
      return;
    } catch (error) {
      if (mounted) {
        _message('Could not find applications for this file: $error');
      }
      return;
    }
    if (!mounted) return;
    final canUseTextEditor = effectiveCategory == 'Text';
    if (apps.isEmpty && !canUseTextEditor) {
      _message(
        'No installed applications can open this file as $effectiveCategory',
      );
      return;
    }

    final selection = await showDialog<_OpenWithSelection>(
      context: context,
      builder: (dialogContext) {
        var saveAsDefault = false;
        return StatefulBuilder(
          builder: (context, setDialogState) => SimpleDialog(
            title: Text('Open as $effectiveCategory'),
            children: [
              if (canUseTextEditor)
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(
                    dialogContext,
                    _OpenWithSelection(
                      isTextEditor: true,
                      saveAsDefault: saveAsDefault,
                    ),
                  ),
                  child: const Text('Text Editor (built-in)'),
                ),
              for (final app in apps)
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(
                    dialogContext,
                    _OpenWithSelection(app: app, saveAsDefault: saveAsDefault),
                  ),
                  child: Text(app.name),
                ),
              if (extension.isNotEmpty)
                CheckboxListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                  activeColor: const Color(0xFF0055FF),
                  title: Text(
                    'Always use this app for $extension files',
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF0055FF),
                    ),
                  ),
                  value: saveAsDefault,
                  onChanged: (value) =>
                      setDialogState(() => saveAsDefault = value ?? false),
                ),
            ],
          ),
        );
      },
    );
    if (!mounted || selection == null) return;

    if (selection.saveAsDefault && extension.isNotEmpty) {
      final defaultApp = selection.isTextEditor
          ? DefaultFileApp(
              extension: extension,
              handlerId: DefaultFileApp.textEditorHandlerId,
              category: effectiveCategory,
              mimeType: 'text/plain',
            )
          : DefaultFileApp(
              extension: extension,
              handlerId: 'external',
              category: effectiveCategory,
              mimeType: selection.app!.mimeType,
              packageName: selection.app!.packageName,
              displayName: selection.app!.name,
            );
      try {
        await ref.read(defaultFileAppsProvider.notifier).save(defaultApp);
      } catch (error) {
        if (mounted) _message('Could not save the default app: $error');
      }
    }

    if (selection.isTextEditor) {
      TabsManager.instance.openTextEditor(file.path);
      return;
    }
    final selectedApp = selection.app;
    if (selectedApp == null) return;
    try {
      await ref
          .read(openWithRepositoryProvider)
          .openFile(
            path: file.path,
            category: effectiveCategory,
            packageName: selectedApp.packageName,
            mimeType: selectedApp.mimeType,
          );
    } on PlatformException catch (error) {
      if (mounted) {
        _message(error.message ?? 'Could not open ${_displayName(file.path)}');
      }
    } catch (error) {
      if (mounted) {
        _message('Could not open ${_displayName(file.path)}: $error');
      }
    }
  }

  void _cancelCopyMode() {
    if (_copySession.sources.isEmpty || _copySession.isPasting) return;
    _copySession.clear();
  }

  Future<void> _pasteCopiedItems() async {
    if (_dir == null ||
        _copySession.sources.isEmpty ||
        _copySession.isPasting) {
      return;
    }
    final destinationDirectory = _dir!;
    _copySession.setPasting(true);

    final nonConflicting = <FileSystemEntity>[];
    final conflicts = <_CopyConflict>[];
    for (final source in _copySession.sources) {
      final targetPath = _targetPath(
        destinationDirectory.path,
        _displayName(source.path),
      );
      try {
        if (await FileSystemEntity.type(targetPath, followLinks: false) !=
            FileSystemEntityType.notFound) {
          conflicts.add(_CopyConflict(source: source, targetPath: targetPath));
        } else {
          nonConflicting.add(source);
        }
      } catch (_) {
        nonConflicting.add(source);
      }
    }

    _copySession.setConflicts(
      destination: destinationDirectory,
      nonConflicting: nonConflicting,
      conflicts: conflicts,
    );
    if (conflicts.isEmpty) {
      _copySession.setPasting(true);
      await _copyNonConflictingItems();
      await _completePaste();
    }
  }

  Future<void> _chooseConflictScope(_CopyConflictMode mode) async {
    _copySession.setPasting(false);
    _copySession.navigateTo(_CopyPanelStep.resolveConflict);
    _copySession._mode = mode;
    _copySession._conflictIndex = 0;
    _copySession.notifyChanged();
  }

  void _showConflictCancelChoices() {
    _copySession.setPasting(false);
    if (_copySession.conflicts.length <= 1) {
      _copySession.finishPaste(retainFailures: false);
      return;
    }
    final atInitialPrompt =
        _copySession.step == _CopyPanelStep.chooseConflictScope;
    _copySession.setCancelMode(
      atInitialPrompt
          ? _CopyCancelMode.initial
          : _copySession.mode == _CopyConflictMode.separate
          ? _CopyCancelMode.separate
          : _copySession.mode == _CopyConflictMode.applyAll
          ? _CopyCancelMode.uniform
          : _CopyCancelMode.initial,
    );
  }

  void _goBackFromConflictPrompt() {
    if (_copySession.step == _CopyPanelStep.resolveConflict &&
        _copySession.mode == _CopyConflictMode.separate &&
        _copySession.conflicts.isNotEmpty) {
      _copySession.showScopeForRemainingConflicts();
      return;
    }
    _copySession.goBack();
  }

  void _chooseApplyAllRenameTarget(_CopyConflictAction action) {
    _copySession._applyAllRenameAction = action;
    _copySession.navigateTo(_CopyPanelStep.chooseApplyAllRenameMethod);
  }

  void _chooseApplyAllRenameMethod({required bool series}) {
    final action = _copySession.applyAllRenameAction;
    if (action == null) return;
    _copySession._applyAllRenameSeries = series;
    if (series) {
      _copySession.navigateTo(_CopyPanelStep.chooseApplyAllSeriesStyle);
      return;
    }
    unawaited(_applyConflictActionToAll(action));
  }

  Future<void> _chooseApplyAllSeriesStyle(_ApplyAllSeriesStyle style) async {
    final action = _copySession.applyAllRenameAction;
    if (action == null) return;
    _copySession._applyAllSeriesStyle = style;
    await _applyConflictActionToAll(action);
  }

  Future<void> _chooseConflictAction(_CopyConflictAction action) async {
    if (_copySession.mode == _CopyConflictMode.applyAll) {
      if (action == _CopyConflictAction.renameExisting ||
          action == _CopyConflictAction.renameNew) {
        _copySession.navigateTo(_CopyPanelStep.chooseApplyAllRenameTarget);
        return;
      }
      await _applyConflictActionToAll(action);
      return;
    }
    final conflict = _copySession.currentConflict;
    if (conflict == null) return;
    if (action == _CopyConflictAction.renameExisting ||
        action == _CopyConflictAction.renameNew) {
      _copySession.setPasting(false);
      _copySession.navigateTo(_CopyPanelStep.chooseRename);
      return;
    }
    _copySession.setPasting(true);
    await _applyConflictAction(conflict, action);
    await _advanceOrCompleteConflict();
  }

  Future<void> _chooseRenameAction(_CopyConflictAction action) async {
    if (action != _CopyConflictAction.renameExisting &&
        action != _CopyConflictAction.renameNew) {
      return;
    }
    _copySession.setPasting(false);
    if (_copySession.mode == _CopyConflictMode.applyAll) {
      await _applyConflictActionToAll(action);
      return;
    }
    final conflict = _copySession.currentConflict;
    if (conflict == null) return;
    final destination = _copySession.destination;
    if (destination == null) return;
    final renameExisting = action == _CopyConflictAction.renameExisting;
    final initialPath = renameExisting
        ? conflict.targetPath
        : conflict.source.path;
    final name = await _promptForAvailableName(
      title: renameExisting ? 'Rename existing item' : 'Rename incoming item',
      parentPath: destination.path,
      initialName: _displayName(initialPath),
      allowedExistingPath: conflict.targetPath,
    );
    if (!mounted || name == null) return;
    if (renameExisting && name == _displayName(conflict.targetPath)) {
      _message(
        'Cannot rename: enter a different name to free the original name',
      );
      return;
    }
    if (!renameExisting && name == _displayName(conflict.source.path)) {
      _message('Cannot rename: enter a different name for the incoming item');
      return;
    }
    _copySession.setPasting(true);
    await _applyConflictAction(conflict, action, renameTo: name);
    await _advanceOrCompleteConflict();
  }

  Future<void> _applyConflictActionToAll(_CopyConflictAction action) async {
    final destination = _copySession.destination;
    if (destination == null) return;
    final names = <_CopyConflict, String>{};
    var renumberedSeriesItems = 0;
    if (action == _CopyConflictAction.renameExisting ||
        action == _CopyConflictAction.renameNew) {
      final conflicts = _copySession.conflicts;
      final isSeries =
          _copySession.applyAllRenameAction == action &&
          _copySession._applyAllRenameSeries;
      if (isSeries) {
        final style = _copySession._applyAllSeriesStyle;
        final baseName = style == _ApplyAllSeriesStyle.useNewBaseName
            ? await _promptForNewName(
                title: 'Rename series',
                extensionNote:
                    'Items will be named with numbers in selection order, keeping each file extension.',
              )
            : null;
        if (!mounted ||
            (style == _ApplyAllSeriesStyle.useNewBaseName &&
                baseName == null)) {
          return;
        }
        if (baseName != null && !_isValidNewName(baseName)) {
          _message('Cannot rename: enter a valid base name');
          return;
        }

        var sharedSuffix = 1;
        for (final conflict in conflicts) {
          final isExisting = action == _CopyConflictAction.renameExisting;
          final entity = await _entityAtPath(
            isExisting ? conflict.targetPath : conflict.source.path,
          );
          if (entity == null) {
            _message('Cannot rename: an item is no longer available');
            return;
          }
          final itemName = _displayName(
            isExisting ? conflict.targetPath : conflict.source.path,
          );
          final extension = entity is File ? _fileExtension(itemName) : '';
          final itemBase = extension.isEmpty
              ? itemName
              : itemName.substring(0, itemName.length - extension.length);
          var foundName = false;
          var skippedProposedName = false;
          final firstSuffix = style == _ApplyAllSeriesStyle.keepItemNames
              ? 1
              : sharedSuffix;
          for (var suffix = firstSuffix; suffix <= 9999; suffix++) {
            final stem = baseName ?? itemBase;
            final candidate = '$stem$suffix$extension';
            final path = _targetPath(destination.path, candidate);
            final alreadyPlanned = names.values.any(
              (plannedName) => _sameFileName(plannedName, candidate),
            );
            final exists =
                await FileSystemEntity.type(path, followLinks: false) !=
                FileSystemEntityType.notFound;
            if (alreadyPlanned || exists) {
              if (style == _ApplyAllSeriesStyle.useNewBaseName) {
                skippedProposedName = true;
              }
              continue;
            }
            names[conflict] = candidate;
            foundName = true;
            if (style == _ApplyAllSeriesStyle.useNewBaseName) {
              sharedSuffix = suffix + 1;
              if (skippedProposedName) renumberedSeriesItems++;
            }
            break;
          }
          if (!foundName) {
            _message(
              style == _ApplyAllSeriesStyle.keepItemNames
                  ? 'Cannot rename "${itemName}" with this method: all numbered names through 9999 are already in use.'
                  : 'Cannot rename all items: numbered names through 9999 are exhausted. No items were renamed.',
            );
            return;
          }
        }
      } else {
        for (final conflict in conflicts) {
          final renameExisting = action == _CopyConflictAction.renameExisting;
          final initialPath = renameExisting
              ? conflict.targetPath
              : conflict.source.path;
          final name = await _promptForAvailableName(
            title: renameExisting
                ? 'Rename existing item'
                : 'Rename incoming item',
            parentPath: destination.path,
            initialName: _displayName(initialPath),
            allowedExistingPath: conflict.targetPath,
          );
          if (!mounted || name == null) return;
          if (renameExisting && name == _displayName(conflict.targetPath)) {
            _message(
              'Cannot rename: enter a different name to free the original name',
            );
            return;
          }
          if (!renameExisting && name == _displayName(conflict.source.path)) {
            _message(
              'Cannot rename: enter a different name for the incoming item',
            );
            return;
          }
          final path = _targetPath(destination.path, name);
          if (names.values.any((existingName) => existingName == name)) {
            _message('Cannot rename: a file with this name already exists');
            return;
          }
          names[conflict] = name;
          // Existing destination entries are checked by the shared prompt; this
          // additional check prevents two incoming entries selecting one name.
          if (await FileSystemEntity.type(path, followLinks: false) !=
              FileSystemEntityType.notFound) {
            final isTheCurrentExistingItem =
                renameExisting && path == conflict.targetPath;
            if (!isTheCurrentExistingItem) {
              _message('Cannot rename: a file with this name already exists');
              return;
            }
          }
        }
      }
    }

    _copySession.setPasting(true);
    for (final conflict in _copySession.conflicts) {
      await _applyConflictAction(conflict, action, renameTo: names[conflict]);
    }
    await _copyNonConflictingItems();
    final completionNote = renumberedSeriesItems == 0
        ? null
        : '$renumberedSeriesItems item${renumberedSeriesItems == 1 ? '' : 's'} had proposed names that already existed; later numbers were used.';
    await _completePaste(additionalMessage: completionNote);
  }

  bool _sameFileName(String left, String right) => Platform.isWindows
      ? left.toLowerCase() == right.toLowerCase()
      : left == right;

  String _fileExtension(String name) {
    final dotIndex = name.lastIndexOf('.');
    if (dotIndex <= 0 || dotIndex == name.length - 1) return '';
    return name.substring(dotIndex);
  }

  Future<void> _applyConflictAction(
    _CopyConflict conflict,
    _CopyConflictAction action, {
    String? renameTo,
  }) async {
    try {
      switch (action) {
        case _CopyConflictAction.replace:
          await _replaceWithIncoming(conflict);
        case _CopyConflictAction.renameExisting:
          if (renameTo == null) return;
          await _renameExistingAndCopy(conflict, renameTo);
        case _CopyConflictAction.renameNew:
          if (renameTo == null) return;
          final destination = _copySession.destination!;
          final target = _targetPath(destination.path, renameTo);
          await _copyIncomingToPath(conflict.source, target, destination);
      }
      _copySession.setPastedCount(_copySession.pastedCount + 1);
    } on FileSystemException catch (error) {
      _copySession.addFailedSource(conflict.source);
      debugPrint(
        'Failed to resolve copy conflict for ${conflict.source.path}: ${error.message}',
      );
    } catch (error) {
      _copySession.addFailedSource(conflict.source);
      debugPrint(
        'Failed to resolve copy conflict for ${conflict.source.path}: $error',
      );
    }
  }

  Future<void> _advanceOrCompleteConflict() async {
    if (_copySession.mode == _CopyConflictMode.single ||
        _copySession.conflictIndex + 1 >= _copySession.conflicts.length) {
      _copySession.setPasting(true);
      await _copyNonConflictingItems();
      await _completePaste();
      return;
    }
    _copySession.setPasting(false);
    _copySession.advanceConflict();
  }

  Future<void> _chooseCancelOutcome({required bool cancelAll}) async {
    switch (_copySession.cancelMode) {
      case _CopyCancelMode.initial:
      case _CopyCancelMode.uniform:
        if (cancelAll) {
          _copySession.finishPaste(retainFailures: false);
          return;
        }
        _copySession.setPasting(true);
        await _copyNonConflictingItems();
        await _completePaste();
      case _CopyCancelMode.separate:
        if (cancelAll) {
          _copySession.setPasting(true);
          await _copyNonConflictingItems();
          await _completePaste();
          return;
        }
        await _advanceOrCompleteConflict();
    }
  }

  Future<void> _copyNonConflictingItems() async {
    final destination = _copySession.destination;
    if (destination == null) return;
    for (final source in _copySession.nonConflicting) {
      try {
        await _copyIncomingToPath(
          source,
          _targetPath(destination.path, _displayName(source.path)),
          destination,
        );
        _copySession.setPastedCount(_copySession.pastedCount + 1);
      } on FileSystemException catch (error) {
        _copySession.addFailedSource(source);
        debugPrint('Failed to copy ${source.path}: ${error.message}');
      } catch (error) {
        _copySession.addFailedSource(source);
        debugPrint('Failed to copy ${source.path}: $error');
      }
    }
  }

  Future<void> _completePaste({String? additionalMessage}) async {
    final destination = _copySession.destination;
    final pastedCount = _copySession.pastedCount;
    final failedCount = _copySession.failedSources.length;
    if (destination != null) {
      _directoryCache.remove(destination.path);
      if (_dir?.path == destination.path && mounted) {
        await _loadRoot(destination.path, forceRefresh: true);
      }
    }
    if (!mounted) return;
    _copySession.finishPaste();
    final completionMessage = failedCount == 0
        ? 'Pasted $pastedCount item${pastedCount == 1 ? '' : 's'}'
        : 'Pasted $pastedCount item${pastedCount == 1 ? '' : 's'}; $failedCount could not be copied';
    _message(
      additionalMessage == null
          ? completionMessage
          : '$completionMessage. $additionalMessage',
    );
  }

  String _targetPath(String directoryPath, String name) =>
      '$directoryPath${directoryPath.endsWith(Platform.pathSeparator) ? '' : Platform.pathSeparator}$name';

  Future<void> _copyIncomingToPath(
    FileSystemEntity source,
    String targetPath,
    Directory destinationDirectory,
  ) async {
    final sourcePath = normalizeSortPath(source.path);
    final destinationPath = normalizeSortPath(destinationDirectory.path);
    if (source is Directory &&
        (destinationPath == sourcePath ||
            destinationPath.startsWith('$sourcePath/'))) {
      throw FileSystemException(
        'A folder cannot be copied into itself or one of its descendants',
        source.path,
      );
    }
    await _copyEntityToPath(source, targetPath);
  }

  Future<void> _copyEntityToPath(
    FileSystemEntity source,
    String targetPath,
  ) async {
    if (await FileSystemEntity.type(targetPath, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw FileSystemException(
        'An item with this name already exists',
        targetPath,
      );
    }

    if (source is File) {
      try {
        await source.copy(targetPath);
      } catch (_) {
        final partialFile = File(targetPath);
        if (await partialFile.exists()) await partialFile.delete();
        rethrow;
      }
      return;
    }
    if (source is Directory) {
      final targetDirectory = Directory(targetPath);
      await targetDirectory.create();
      try {
        await for (final child in source.list(followLinks: false)) {
          if (child is File || child is Directory) {
            await _copyEntityToPath(
              child,
              _targetPath(targetPath, _displayName(child.path)),
            );
          } else {
            throw FileSystemException(
              'Symbolic links cannot be copied',
              child.path,
            );
          }
        }
      } catch (_) {
        if (await targetDirectory.exists()) {
          await targetDirectory.delete(recursive: true);
        }
        rethrow;
      }
      return;
    }
    throw FileSystemException('This item type cannot be copied', source.path);
  }

  Future<void> _replaceWithIncoming(_CopyConflict conflict) async {
    final destination = _copySession.destination!;
    final stagedPath = await _stageIncoming(conflict.source, destination);
    final existing = await _entityAtPath(conflict.targetPath);
    if (existing == null) {
      await _renamePath(stagedPath, conflict.targetPath);
      return;
    }
    final backupPath = await _uniqueSiblingPath(destination.path, 'backup');
    var movedExisting = false;
    try {
      await existing.rename(backupPath);
      movedExisting = true;
      await _renamePath(stagedPath, conflict.targetPath);
    } catch (_) {
      try {
        if (movedExisting) {
          await _renamePath(backupPath, conflict.targetPath);
        }
      } finally {
        await _deletePath(stagedPath);
      }
      rethrow;
    }
    try {
      await _deletePath(backupPath);
    } catch (error) {
      debugPrint('Could not remove replaced-item backup $backupPath: $error');
    }
  }

  Future<void> _renameExistingAndCopy(
    _CopyConflict conflict,
    String newExistingName,
  ) async {
    final destination = _copySession.destination!;
    final stagedPath = await _stageIncoming(conflict.source, destination);
    final existing = await _entityAtPath(conflict.targetPath);
    if (existing == null) {
      await _renamePath(stagedPath, conflict.targetPath);
      return;
    }
    final renamedExistingPath = _targetPath(destination.path, newExistingName);
    if (await FileSystemEntity.type(renamedExistingPath, followLinks: false) !=
        FileSystemEntityType.notFound) {
      await _deletePath(stagedPath);
      throw FileSystemException(
        'An item with this name already exists',
        renamedExistingPath,
      );
    }
    var movedExisting = false;
    try {
      await existing.rename(renamedExistingPath);
      movedExisting = true;
      await _renamePath(stagedPath, conflict.targetPath);
    } catch (_) {
      try {
        if (movedExisting) {
          await _renamePath(renamedExistingPath, conflict.targetPath);
        }
      } finally {
        await _deletePath(stagedPath);
      }
      rethrow;
    }
  }

  Future<String> _stageIncoming(
    FileSystemEntity source,
    Directory destination,
  ) async {
    final stagedPath = await _uniqueSiblingPath(destination.path, 'incoming');
    try {
      await _copyIncomingToPath(source, stagedPath, destination);
    } catch (_) {
      await _deletePath(stagedPath);
      rethrow;
    }
    return stagedPath;
  }

  Future<String> _uniqueSiblingPath(String parentPath, String label) async {
    for (var attempt = 0; attempt < 100; attempt++) {
      final path = _targetPath(
        parentPath,
        '.modi-$label-${DateTime.now().microsecondsSinceEpoch}-$attempt',
      );
      if (await FileSystemEntity.type(path, followLinks: false) ==
          FileSystemEntityType.notFound) {
        return path;
      }
    }
    throw FileSystemException(
      'Cannot create a temporary copy path',
      parentPath,
    );
  }

  Future<FileSystemEntity?> _entityAtPath(String path) async {
    final type = await FileSystemEntity.type(path, followLinks: false);
    return switch (type) {
      FileSystemEntityType.file => File(path),
      FileSystemEntityType.directory => Directory(path),
      FileSystemEntityType.link => Link(path),
      _ => null,
    };
  }

  Future<void> _deletePath(String path) async {
    final entity = await _entityAtPath(path);
    if (entity != null) await entity.delete(recursive: entity is Directory);
  }

  Future<void> _renamePath(String sourcePath, String targetPath) async {
    final source = await _entityAtPath(sourcePath);
    if (source == null) {
      throw FileSystemException('Item is no longer available', sourcePath);
    }
    await source.rename(targetPath);
  }

  Future<void> _deleteSelected() async {
    final items = _items.where((e) => _selected.contains(e.path)).toList();
    if (items.isEmpty) {
      _message('Delete is not available: no items are selected');
      return;
    }
    var folderCount = 0;
    var fileCount = 0;
    var totalBytes = 0;
    final visited = <String>{};
    Future<void> measure(FileSystemEntity entity) async {
      if (!visited.add(entity.path)) return;
      if (entity is Directory) {
        folderCount++;
        await for (final child in entity.list(followLinks: false)) {
          if (child is File || child is Directory) await measure(child);
        }
      } else if (entity is File) {
        fileCount++;
        totalBytes += await entity.length();
      }
    }

    try {
      for (final item in items) {
        await measure(item);
      }
    } on FileSystemException catch (error) {
      _message('Cannot calculate deletion size: ${error.message}');
      return;
    }
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Confirm deletion'),
        content: Text(
          'Delete $folderCount folder${folderCount == 1 ? '' : 's'} and '
          '$fileCount file${fileCount == 1 ? '' : 's'}?\n'
          'Total storage used: $totalBytes bytes.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('No'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Yes'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    var deleted = 0;
    String? failure;
    for (final item in items) {
      try {
        await item.delete(recursive: item is Directory);
        deleted++;
      } on FileSystemException catch (e) {
        failure ??= e.osError?.errorCode == 13
            ? 'Permission denied'
            : e.message;
      }
    }
    setState(() {
      _selected.clear();
      _selectionMode = false;
    });
    if (_dir != null) await _loadRoot(_dir!.path, forceRefresh: true);
    _message(
      deleted > 0
          ? '$deleted item${deleted == 1 ? '' : 's'} deleted${failure == null ? '' : '; $failure'}'
          : 'Delete failed: ${failure ?? 'items could not be removed'}',
    );
  }

  String _displayName(String path) {
    if (_anchorPath != null && path == _anchorPath) {
      return widget.displayName ?? _storageDisplayName(path);
    }

    final normalizedPath = path.replaceAll('\\', '/');
    final trimmedPath = normalizedPath.endsWith('/')
        ? normalizedPath.substring(0, normalizedPath.length - 1)
        : normalizedPath;
    final separatorIndex = trimmedPath.lastIndexOf('/');
    return separatorIndex >= 0
        ? trimmedPath.substring(separatorIndex + 1)
        : trimmedPath;
  }

  String _storageDisplayName(String path) {
    final normalized = path
        .replaceAll('\\', '/')
        .replaceFirst(RegExp(r'/+$'), '');
    final lower = normalized.toLowerCase();

    if (lower == '/storage/emulated/0' ||
        lower == '/storage/self/primary' ||
        lower == '/sdcard') {
      return 'Internal Storage';
    }

    final name = normalized.split('/').last;
    if (name.isEmpty) return 'External Storage';

    // Android commonly mounts removable media as /storage/XXXX-XXXX.  The
    // identifier is not a useful display label, so use a friendly fallback.
    final isMountId = RegExp(
      r'^[0-9a-f]{4,}[-_][0-9a-f]{4,}$',
      caseSensitive: false,
    ).hasMatch(name);
    if (isMountId) return 'External Storage';

    // Some devices expose the volume label in the mount-point name.
    final readable = name.replaceAll(RegExp(r'[_-]+'), ' ').trim();
    if (readable.isEmpty || readable.toLowerCase() == 'storage') {
      return 'External Storage';
    }
    return readable
        .split(RegExp(r'\s+'))
        .map(
          (word) => word.isEmpty
              ? word
              : '${word[0].toUpperCase()}${word.substring(1)}',
        )
        .join(' ');
  }

  Widget? buildCopyPanel() {
    final sources = _copySession.sources;
    if (sources.isEmpty) return null;
    final isUnavailable = _dir == null || _copySession.isPasting;
    final theme = Theme.of(context);

    Widget button(
      String label,
      VoidCallback? onPressed, {
      bool destructive = false,
    }) {
      return Expanded(
        child: TextButton(
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            minimumSize: const Size(0, 36),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            foregroundColor: destructive ? theme.colorScheme.error : null,
          ),
          onPressed: onPressed,
          child: Text(
            label,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12),
          ),
        ),
      );
    }

    Widget actionPanel({
      required String message,
      required List<Widget> actions,
    }) {
      return SizedBox(
        height: _copySession.panelHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Column(
            children: [
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    message,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ),
              Row(children: actions),
            ],
          ),
        ),
      );
    }

    final Widget panelContent;
    switch (_copySession.step) {
      case _CopyPanelStep.standard:
        panelContent = SizedBox(
          height: _copySession.panelHeight,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Expanded(
                  flex: 3,
                  child: MarqueeText(
                    'Copy: ${sources.whereType<Directory>().length} folders and ${sources.whereType<File>().length} files',
                    style: theme.textTheme.bodySmall?.copyWith(fontSize: 12),
                    styleMode: MarqueeStyle.pauseAndLoop,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: Row(
                    children: [
                      Expanded(
                        child: TextButton(
                          style: TextButton.styleFrom(
                            padding: EdgeInsets.zero,
                            minimumSize: const Size(0, 36),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          onPressed: isUnavailable ? null : _pasteCopiedItems,
                          child: isUnavailable
                              ? const SizedBox.square(
                                  dimension: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Text(
                                  'Paste',
                                  style: TextStyle(fontSize: 12),
                                ),
                        ),
                      ),
                      Expanded(
                        child: TextButton(
                          style: TextButton.styleFrom(
                            padding: EdgeInsets.zero,
                            minimumSize: const Size(0, 36),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            foregroundColor: theme.colorScheme.error,
                          ),
                          onPressed: _copySession.isPasting
                              ? null
                              : _cancelCopyMode,
                          child: const Text(
                            'Cancel',
                            style: TextStyle(fontSize: 12),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      case _CopyPanelStep.chooseConflictScope:
        final conflictCount = _copySession.conflicts.length;
        final folderCount = _copySession.conflicts
            .where((conflict) => conflict.source is Directory)
            .length;
        final fileCount = _copySession.conflicts
            .where((conflict) => conflict.source is File)
            .length;
        final renameParts = <String>[];
        if (folderCount > 0) {
          renameParts.add('$folderCount folder${folderCount == 1 ? '' : 's'}');
        }
        if (fileCount > 0) {
          renameParts.add('$fileCount file${fileCount == 1 ? '' : 's'}');
        }
        final renameSummary = renameParts.isEmpty
            ? ''
            : ' Rename ${renameParts.join(' and ')}?';
        final summaryMessage =
            '$conflictCount item${conflictCount == 1 ? '' : 's'} already ${conflictCount == 1 ? 'exists' : 'exist'}.$renameSummary';

        panelContent = actionPanel(
          message: summaryMessage,
          actions: [
            button(
              'Apply to all ${_copySession.conflicts.length}',
              () => _chooseConflictScope(_CopyConflictMode.applyAll),
            ),
            button(
              'Choose separately',
              () => _chooseConflictScope(_CopyConflictMode.separate),
            ),
            button('Back', _goBackFromConflictPrompt),
          ],
        );
      case _CopyPanelStep.resolveConflict:
        final conflict = _copySession.currentConflict;
        final name = conflict == null ? '' : _displayName(conflict.targetPath);
        final isMultiConflictFlow = _copySession.startedWithMultipleConflicts;
        panelContent = actionPanel(
          message:
              "'$name' already exists here. Replace it with the copied item, rename the copied item, or cancel this single conflict.",
          actions: [
            button(
              'Replace',
              _copySession.isPasting
                  ? null
                  : () => _chooseConflictAction(_CopyConflictAction.replace),
            ),
            button(
              'Rename',
              _copySession.isPasting
                  ? null
                  : () => _chooseConflictAction(_CopyConflictAction.renameNew),
            ),
            button(
              isMultiConflictFlow ? 'Back' : 'Cancel',
              _copySession.isPasting
                  ? null
                  : (isMultiConflictFlow
                        ? _goBackFromConflictPrompt
                        : _showConflictCancelChoices),
              destructive: !isMultiConflictFlow,
            ),
          ],
        );
      case _CopyPanelStep.chooseRename:
        final conflict = _copySession.currentConflict;
        final name = conflict == null ? '' : _displayName(conflict.targetPath);
        panelContent = actionPanel(
          message:
              "Rename '$name' to keep both items. Choose whether to rename the existing item or the copied item.",
          actions: [
            button(
              'Rename existing',
              () => _chooseRenameAction(_CopyConflictAction.renameExisting),
            ),
            button(
              'Rename new',
              () => _chooseRenameAction(_CopyConflictAction.renameNew),
            ),
            button('Back', _goBackFromConflictPrompt),
          ],
        );
      case _CopyPanelStep.chooseApplyAllRenameTarget:
        panelContent = actionPanel(
          message: 'Choose which items to rename for all conflicts.',
          actions: [
            button(
              'Rename existing (old)',
              () => _chooseApplyAllRenameTarget(
                _CopyConflictAction.renameExisting,
              ),
            ),
            button(
              'Rename new items',
              () => _chooseApplyAllRenameTarget(_CopyConflictAction.renameNew),
            ),
            button('Back', _goBackFromConflictPrompt),
          ],
        );
      case _CopyPanelStep.chooseApplyAllRenameMethod:
        panelContent = actionPanel(
          message: 'Choose how to name the items.',
          actions: [
            button('Rename in series', () {
              _chooseApplyAllRenameMethod(series: true);
            }),
            button('Rename manually', () {
              _chooseApplyAllRenameMethod(series: false);
            }),
            button('Back', _goBackFromConflictPrompt),
          ],
        );
      case _CopyPanelStep.chooseApplyAllSeriesStyle:
        panelContent = actionPanel(
          message: 'Choose how to create the numbered names.',
          actions: [
            button(
              'Use each item name',
              () => _chooseApplyAllSeriesStyle(
                _ApplyAllSeriesStyle.keepItemNames,
              ),
            ),
            button(
              'Use a new name',
              () => _chooseApplyAllSeriesStyle(
                _ApplyAllSeriesStyle.useNewBaseName,
              ),
            ),
            button('Back', _goBackFromConflictPrompt),
          ],
        );
      case _CopyPanelStep.cancelChoice:
        final cancelMode = _copySession.cancelMode;
        final isSeparate = cancelMode == _CopyCancelMode.separate;
        final isInitial = cancelMode == _CopyCancelMode.initial;
        panelContent = actionPanel(
          message: isSeparate
              ? 'Choose how much of this paste to cancel'
              : 'Choose how much of this paste to cancel',
          actions: [
            button(
              isSeparate ? 'Cancel this and remaining' : 'Cancel all',
              () => _chooseCancelOutcome(cancelAll: true),
              destructive: true,
            ),
            button(
              isSeparate
                  ? 'Cancel only this'
                  : isInitial
                  ? 'Paste non-conflicting'
                  : 'Cancel conflicts only',
              () => _chooseCancelOutcome(cancelAll: false),
              destructive: !isSeparate,
            ),
            button('Back', _goBackFromConflictPrompt),
          ],
        );
    }

    return SafeArea(
      top: false,
      child: Material(
        elevation: 8,
        color: theme.colorScheme.surfaceContainerHigh,
        child: panelContent,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    ref.listen<AsyncValue<List<SortRule>>>(sortRulesProvider, (previous, next) {
      final rules = next.asData?.value;
      if (rules != null) _applyEffectiveSort(rules);
    });
    ref.listen<bool>(foldersFirstProvider, (previous, next) {
      if (_dir != null) _applyEffectiveSort(_currentRules());
    });
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: kToolbarHeight * 0.80,
        leading: _selectionMode
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () {
                  setState(() {
                    _selectionMode = false;
                    _selected.clear();
                  });
                },
              )
            : Consumer(
                builder: (context, ref, _) {
                  return IconButton(
                    icon: const Icon(Icons.menu),
                    onPressed: () =>
                        ref.read(settingsPanelProvider.notifier).toggle(),
                  );
                },
              ),
        title: _selectionMode
            ? Text(
                '${_selected.length} selected',
                style: const TextStyle(fontSize: 19),
              )
            : MarqueeText(
                _dir == null ? 'Storage' : _displayName(_dir!.path),
                style: const TextStyle(fontSize: 19),
                styleMode: MarqueeStyle.pauseAndLoop,
              ),
        actions: [
          if (!_selectionMode)
            IconButton(
              tooltip: 'Refresh',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              onPressed: _dir == null
                  ? null
                  : () => _loadRoot(_dir!.path, forceRefresh: true),
              icon: const Icon(Icons.refresh),
            ),
          IconButton(
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            onPressed: () {},
            icon: const Icon(Icons.search),
          ),
          PopupMenuButton<String>(
            key: _menuKey,
            padding: EdgeInsets.zero,
            icon: const Icon(Icons.more_vert),
            onSelected: _handleMenu,
            itemBuilder: (_) => _menuItems(),
          ),
        ],
      ),
      body: _dir == null
          ? const Center(child: CircularProgressIndicator())
          : ListView.builder(
              itemCount: _items.length,
              itemBuilder: (context, index) {
                final e = _items[index];
                final name = _displayName(e.path);

                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (_) {
                    _longPressTriggered = false;
                    _pressTimer?.cancel();
                    _pressTimer = Timer(const Duration(milliseconds: 500), () {
                      if (!mounted) return;
                      // start selection mode and select this item
                      setState(() {
                        _selectionMode = true;
                        _selected.add(e.path);
                        _longPressTriggered = true;
                      });
                    });
                  },
                  onTapUp: (_) {
                    _pressTimer?.cancel();
                    if (!_longPressTriggered) {
                      _openEntity(e);
                    }
                  },
                  onTapCancel: () {
                    _pressTimer?.cancel();
                    _longPressTriggered = false;
                  },
                  child: ListTile(
                    selected: _selected.contains(e.path),
                    onTap: null, // allow outer GestureDetector to handle taps
                    leading: _selectionMode
                        ? Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                _selected.contains(e.path)
                                    ? Icons.check_box
                                    : Icons.check_box_outline_blank,
                              ),
                              const SizedBox(width: 8),
                              Icon(
                                e is Directory
                                    ? Icons.folder
                                    : Icons.insert_drive_file,
                              ),
                            ],
                          )
                        : (e is Directory
                              ? const Icon(Icons.folder)
                              : const Icon(Icons.insert_drive_file)),
                    title: Text(name),
                  ),
                );
              },
            ),
    );
  }

  @override
  bool get wantKeepAlive => true;
}

class _BatchTextDialog extends StatefulWidget {
  const _BatchTextDialog({
    required this.title,
    required this.label,
    required this.help,
  });

  final String title;
  final String label;
  final String help;

  @override
  State<_BatchTextDialog> createState() => _BatchTextDialogState();
}

class _BatchTextDialogState extends State<_BatchTextDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(widget.help),
        const SizedBox(height: 12),
        TextField(
          controller: _controller,
          autofocus: true,
          decoration: InputDecoration(labelText: widget.label),
          onSubmitted: (_) => Navigator.pop(context, _controller.text),
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      TextButton(
        onPressed: () => Navigator.pop(context, _controller.text),
        child: const Text('Continue'),
      ),
    ],
  );
}

class _NewNameDialog extends StatefulWidget {
  final String title;
  final String extensionNote;
  final String initialName;

  const _NewNameDialog({
    required this.title,
    required this.extensionNote,
    required this.initialName,
  });

  @override
  State<_NewNameDialog> createState() => _NewNameDialogState();
}

class _NewNameDialogState extends State<_NewNameDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialName);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.extensionNote.isNotEmpty) ...[
          Text(widget.extensionNote),
          const SizedBox(height: 12),
        ],
        TextField(
          controller: _controller,
          autofocus: true,
          decoration: InputDecoration(labelText: '${widget.title} name'),
          onSubmitted: (_) => Navigator.pop(context, _controller.text.trim()),
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      TextButton(
        onPressed: () => Navigator.pop(context, _controller.text.trim()),
        child: Text(widget.title.startsWith('Rename') ? 'Rename' : 'Create'),
      ),
    ],
  );
}

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../core/providers/settings_provider.dart';

class StorageTab extends StatefulWidget {
  final String? initialPath;
  final String? displayName;
  const StorageTab({super.key, this.initialPath, this.displayName});

  @override
  State<StorageTab> createState() => _StorageTabState();
}

class _StorageTabState extends State<StorageTab> with AutomaticKeepAliveClientMixin {
  // Cache listings for this app session.  Keeping the cache by path means a
  // tab can be revisited without causing another filesystem read.
  static final Map<String, List<FileSystemEntity>> _directoryCache = {};

  Directory? _dir;
  String? _anchorPath;
  List<FileSystemEntity> _items = [];
  bool _selectionMode = false;
  final Set<String> _selected = {};
  bool _showHidden = false;
  String _sortBy = 'Name';
  bool _sortAscending = true;
  final GlobalKey _menuKey = GlobalKey();

  Timer? _pressTimer;
  bool _longPressTriggered = false;

  @override
  void initState() {
    super.initState();
    _prepareAndLoadRoot(widget.initialPath);
  }

  Future<void> _prepareAndLoadRoot(String? path) async {
    if (Platform.isAndroid) {
      final storagePermission = await Permission.storage.request();
      if (!storagePermission.isGranted && !storagePermission.isLimited) {
        await Permission.manageExternalStorage.request();
      }
    }
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

    final cachedItems = _directoryCache[dir.path];
    if (!forceRefresh && cachedItems != null) {
      if (!mounted) return;
      setState(() {
        _dir = dir;
        _items = cachedItems;
      });
      return;
    }

    List<FileSystemEntity> items;
    try {
      // Use the asynchronous API for shared storage. On Android, listSync()
      // can fail for an accessible directory and leave the folder empty.
      items = await dir.list(followLinks: false).toList();
      if (!_showHidden) {
        items.removeWhere((item) => _displayName(item.path).startsWith('.'));
      }
      items.sort((a, b) {
        final aIsDirectory = a is Directory;
        final bIsDirectory = b is Directory;
        if (aIsDirectory != bIsDirectory) return aIsDirectory ? -1 : 1;
        return _displayName(a.path)
            .toLowerCase()
            .compareTo(_displayName(b.path).toLowerCase());
      });
    } catch (_) {
      items = [];
    }

    _directoryCache[dir.path] = items;

    if (!mounted) return;
    setState(() {
      _dir = dir;
      _items = items;
    });
  }

  /// Called by the shell to let this tab handle a back press.
  /// Returns true if the back was handled (e.g. navigated up), false to indicate
  /// the tab is at its root and did not handle the back.
  Future<bool> handleWillPop() async {
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

    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Tapped file: ${e.path}')));
  }

  void _sortItems(String field, bool ascending) {
    setState(() {
      _sortBy = field;
      _sortAscending = ascending;
      _items.sort((a, b) {
        int result;
        switch (field) {
          case 'Date modified':
            result = _modified(a).compareTo(_modified(b));
            break;
          case 'Size':
            result = _size(a).compareTo(_size(b));
            break;
          case 'Type':
            result = a.path.split('.').last.toLowerCase().compareTo(b.path.split('.').last.toLowerCase());
            break;
          default:
            result = _displayName(a.path).toLowerCase().compareTo(_displayName(b.path).toLowerCase());
        }
        return ascending ? result : -result;
      });
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
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _showSortMenu() async {
    final box = _menuKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) { _message('Sort menu is unavailable'); return; }
    final origin = box.localToGlobal(Offset.zero);
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final rect = Rect.fromLTWH(
      origin.dx,
      origin.dy,
      box.size.width,
      box.size.height,
    );
    final position = RelativeRect.fromRect(
      rect,
      Offset.zero & overlay.size,
    );
    final options = <MapEntry<String, bool>>[
      MapEntry('Name', true), MapEntry('Name', false), MapEntry('Date modified', true),
      MapEntry('Date modified', false), MapEntry('Size', true), MapEntry('Size', false),
    ];
    final choice = await showMenu<int>(context: context, position: position, items: [
      for (var i = 0; i < options.length; i++)
        PopupMenuItem(value: i, child: Text('${options[i].key} - ${options[i].value ? 'Ascending' : 'Descending'}')),
    ]);
    if (choice == null) return;
    final option = options[choice];
    try {
      _sortItems(option.key, option.value);
      _message('Sorted by ${option.key}, ${option.value ? 'ascending' : 'descending'}');
    } catch (_) { _message('Cannot sort: file details are unavailable'); }
  }

  Future<void> _showFolderProperties(List<FileSystemEntity> entities) async {
    if (entities.isEmpty) { _message('No item is available for properties'); return; }
    var bytes = 0;
    DateTime? modified;
    try {
      for (final entity in entities) {
        if (entity is File) bytes += await entity.length();
        final date = (await entity.stat()).modified;
        if (modified == null || date.isAfter(modified)) modified = date;
      }
      if (entities.length == 1 && entities.first is Directory) {
        await for (final entity in (entities.first as Directory).list(recursive: true, followLinks: false)) {
          if (entity is File) bytes += await entity.length();
        }
      }
      if (!mounted) return;
      if (entities.length == 1) {
        final item = entities.first;
        await showDialog<void>(context: context, builder: (ctx) => AlertDialog(
          title: const Text('Properties'),
          content: Text('Name: ${_displayName(item.path)}\nPath: ${item.path}\nItem count: ${item is Directory ? _items.length : 1}\nTotal size: $bytes bytes\nLast modified: ${modified ?? 'Unavailable'}'),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
        ));
      } else {
        await showDialog<void>(context: context, builder: (ctx) => AlertDialog(
          title: const Text('Properties'), content: Text('${entities.length} items\nTotal size: $bytes bytes'),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
        ));
      }
      if (mounted) _message('Properties shown');
    } catch (_) { if (mounted) _message('Cannot read properties: permission denied or item unavailable'); }
  }

  Future<void> _renameSelected() async {
    if (_selected.length != 1) { _message('Rename requires exactly one selected item'); return; }
    final item = _items.where((e) => _selected.contains(e.path)).firstOrNull;
    if (item == null) { _message('Cannot rename: selected item is unavailable'); return; }
    final controller = TextEditingController(text: _displayName(item.path));
    final name = await showDialog<String>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Rename'), content: TextField(controller: controller, autofocus: true),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(ctx, controller.text.trim()), child: const Text('Rename'))],
    ));
    controller.dispose();
    if (name == null) { if (mounted) _message('Rename cancelled'); return; }
    if (name.isEmpty || name.contains('/') || name.contains('\\')) { if (mounted) _message('Cannot rename: enter a valid name'); return; }
    final target = '${item.parent.path}${item.parent.path.endsWith(Platform.pathSeparator) ? '' : Platform.pathSeparator}$name';
    if (await FileSystemEntity.type(target) != FileSystemEntityType.notFound) { if (mounted) _message('Cannot rename: a file with this name already exists'); return; }
    try {
      if (item is File) {
        await item.rename(target);
      } else if (item is Directory) {
        await item.rename(target);
      } else {
        if (mounted) _message('Cannot rename: this item type is unsupported');
        return;
      }
      setState(() { _selected.clear(); _selectionMode = false; });
      await _loadRoot(_dir?.path, forceRefresh: true);
      if (mounted) _message('Renamed to $name');
    } on FileSystemException catch (e) {
      if (mounted) _message(e.osError?.errorCode == 13 ? 'Permission denied' : 'Cannot rename: ${e.message}');
    }
  }

  List<PopupMenuEntry<String>> _menuItems() {
    if (_selectionMode && _selected.isNotEmpty) {
      return [
        if (_selected.length == 1) const PopupMenuItem(value: 'rename', child: Text('Rename')),
        const PopupMenuItem(value: 'delete', child: Text('Delete')),
        const PopupMenuItem(value: 'copy', child: Text('Copy')),
        const PopupMenuItem(value: 'select_all', child: Text('Select All')),
        const PopupMenuItem(value: 'properties', child: Text('Properties')),
      ];
    }
    return [
      const PopupMenuItem(value: 'select', child: Text('Select')),
      const PopupMenuItem(value: 'select_all', child: Text('Select All')),
      PopupMenuItem(value: 'sort', child: Text('Sort by ($_sortBy, ${_sortAscending ? 'ascending' : 'descending'})')),
      CheckedPopupMenuItem(value: 'hidden', checked: _showHidden, child: const Text('Show hidden files')),
    ];
  }

  void _handleMenu(String value) {
    switch (value) {
      case 'select':
        setState(() => _selectionMode = true);
        _message('Selection mode enabled');
        break;
      case 'select_all':
        setState(() { _selectionMode = true; _selected.addAll(_items.map((e) => e.path)); });
        _message('${_items.length} items selected');
        break;
      case 'hidden':
        setState(() => _showHidden = !_showHidden);
        _loadRoot(_dir?.path, forceRefresh: true).then((_) => _message(_showHidden ? 'Show hidden files enabled' : 'Show hidden files disabled'));
        break;
      case 'sort':
        _showSortMenu();
        break;
      case 'properties':
        _showFolderProperties(_selectionMode ? _items.where((e) => _selected.contains(e.path)).toList() : (_dir == null ? [] : [_dir!]));
        break;
      case 'delete':
        _deleteSelected();
        break;
      case 'rename':
        _renameSelected();
        break;
      case 'copy':
        final paths = _items.where((e) => _selected.contains(e.path)).map((e) => e.path).toList();
        if (paths.isEmpty) { _message('Copy is not available: no items are selected'); break; }
        Clipboard.setData(ClipboardData(text: paths.join('\n'))).then((_) => _message('Copied ${paths.length} item${paths.length == 1 ? '' : 's'} to clipboard'))
            .catchError((_) => _message('Copy failed: clipboard is unavailable'));
        break;
    }
  }

  Future<void> _deleteSelected() async {
    final items = _items.where((e) => _selected.contains(e.path)).toList();
    if (items.isEmpty) { _message('Delete is not available: no items are selected'); return; }
    var deleted = 0;
    String? failure;
    for (final item in items) {
      try { await item.delete(recursive: item is Directory); deleted++; }
      on FileSystemException catch (e) { failure ??= e.osError?.errorCode == 13 ? 'Permission denied' : e.message; }
    }
    setState(() { _selected.clear(); _selectionMode = false; });
    if (_dir != null) await _loadRoot(_dir!.path, forceRefresh: true);
    _message(deleted > 0 ? '$deleted item${deleted == 1 ? '' : 's'} deleted${failure == null ? '' : '; $failure'}' : 'Delete failed: ${failure ?? 'items could not be removed'}');
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
    final normalized = path.replaceAll('\\', '/').replaceFirst(RegExp(r'/+$'), '');
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
        .map((word) => word.isEmpty
            ? word
            : '${word[0].toUpperCase()}${word.substring(1)}')
        .join(' ');
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
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
            : Consumer(builder: (context, ref, _) {
                return IconButton(
                  icon: const Icon(Icons.menu),
                  onPressed: () => ref.read(settingsPanelProvider.notifier).toggle(),
                );
              }),
        title: Text(
          _selectionMode
              ? '${_selected.length} selected'
              : (_dir == null ? 'Storage' : _displayName(_dir!.path)),
          style: const TextStyle(fontSize: 19),
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
                IconButton(padding: EdgeInsets.zero, constraints: const BoxConstraints(), onPressed: () {}, icon: const Icon(Icons.search)),
                PopupMenuButton<String>(key: _menuKey, padding: EdgeInsets.zero, icon: const Icon(Icons.more_vert), onSelected: _handleMenu, itemBuilder: (_) => _menuItems()),
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
                        ? Row(mainAxisSize: MainAxisSize.min, children: [
                            Icon(_selected.contains(e.path) ? Icons.check_box : Icons.check_box_outline_blank),
                            const SizedBox(width: 8),
                            Icon(e is Directory ? Icons.folder : Icons.insert_drive_file),
                          ])
                        : (e is Directory ? const Icon(Icons.folder) : const Icon(Icons.insert_drive_file)),
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

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
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
  Directory? _dir;
  String? _anchorPath;
  List<FileSystemEntity> _items = [];
  bool _selectionMode = false;
  final Set<String> _selected = {};

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

  void _loadRoot(String? path) async {
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

    List<FileSystemEntity> items;
    try {
      // Use the asynchronous API for shared storage. On Android, listSync()
      // can fail for an accessible directory and leave the folder empty.
      items = await dir.list(followLinks: false).toList();
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

    if (!mounted) return;
    setState(() {
      _dir = dir;
      _items = items;
    });
  }

  void _goUp() {
    if (_dir == null) return;
    final parent = _dir!.parent;
    if (parent.path == _dir!.path) return; // reached root
    _loadRoot(parent.path);
  }

  /// Called by the shell to let this tab handle a back press.
  /// Returns true if the back was handled (e.g. navigated up), false to indicate
  /// the tab is at its root and did not handle the back.
  Future<bool> handleWillPop() async {
    if (_dir == null) return false;
    // If we're at or above the tab's anchor/root, do not handle back here.
    if (_anchorPath != null && _dir!.path == _anchorPath) return false;
    final parent = _dir!.parent;
    if (parent.path == _dir!.path) return false; // filesystem root
    // Do not navigate above the anchor path
    if (_anchorPath != null && parent.path.length < _anchorPath!.length && !_anchorPath!.startsWith(parent.path)) {
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
        if (_selected.contains(path)) _selected.remove(path); else _selected.add(path);
        if (_selected.isEmpty) _selectionMode = false;
      });
      return;
    }

    if (e is Directory) {
      _loadRoot(e.path);
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Tapped file: ${e.path}')));
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
        title: Text(_selectionMode
            ? '${_selected.length} selected'
          : (_dir == null ? 'Storage' : _displayName(_dir!.path))),
        actions: _selectionMode
            ? [
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert),
                  onSelected: (v) {
                    // stub: handle actions like delete/share
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Action: $v')));
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'delete', child: Text('Delete')),
                    PopupMenuItem(value: 'share', child: Text('Share')),
                  ],
                )
              ]
            : [
                IconButton(onPressed: () {}, icon: const Icon(Icons.search)),
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
                    _pressTimer = Timer(const Duration(milliseconds: 1500), () {
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
                    leading: e is Directory ? const Icon(Icons.folder) : const Icon(Icons.insert_drive_file),
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

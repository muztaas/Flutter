import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/archive_provider.dart';
import '../../core/providers/open_with_providers.dart';
import '../../core/providers/settings_provider.dart';
import '../../core/providers/storage_providers.dart';
import '../../core/utils/file_name_comparator.dart';
import '../../core/utils/format_bytes.dart';
import '../../core/utils/font_scaled_spacing.dart';
import '../../core/utils/time_format.dart';
import '../../domain/entities/archive_entry.dart';
import '../../domain/entities/file_system_entry.dart';
import '../../domain/entities/archive_operation_progress.dart';
import '../../domain/entities/open_with_app.dart';
import '../../domain/entities/storage_device.dart';
import '../../domain/utils/storage_display_name.dart';
import '../common/file_type_icon.dart';
import '../common/marquee_text.dart';
import '../common/open_with_app_option.dart';
import '../common/storage_entry_row.dart';
import '../storage/storage_tab.dart';

class ArchiveManagerPage extends ConsumerStatefulWidget {
  const ArchiveManagerPage({
    super.key,
    required this.archivePath,
    this.autoExtractTo,
    this.closeAfterAutoExtraction = false,
    this.initialFolder = '',
    this.onFolderChanged,
    this.onClose,
    this.onAutoExtractionComplete,
  });

  final String archivePath;
  final String? autoExtractTo;
  final bool closeAfterAutoExtraction;
  final String initialFolder;
  final ValueChanged<String>? onFolderChanged;
  final VoidCallback? onClose;
  final Future<void> Function()? onAutoExtractionComplete;

  @override
  ArchiveManagerPageState createState() => ArchiveManagerPageState();
}

class ArchiveManagerPageState extends ConsumerState<ArchiveManagerPage>
    with AutomaticKeepAliveClientMixin {
  List<ArchiveEntry> _entries = const [];
  final Set<String> _selected = {};
  String _folder = '';
  String? _password;
  String? _error;
  String? _activeOperationId;
  ArchiveOperationProgress? _progress;
  bool _loading = true;
  bool _selectionMode = false;
  bool _autoExtractionStarted = false;
  late final StreamSubscription<dynamic> _progressSubscription;

  @override
  bool get wantKeepAlive => true;

  String get _archiveName =>
      widget.archivePath
          .split(RegExp(r'[/\\]'))
          .where((part) => part.isNotEmpty)
          .lastOrNull ??
      'Archive';

  String get _archiveParent =>
      widget.archivePath.replaceFirst(RegExp(r'[/\\][^/\\]+$'), '');

  String get _newFolderName {
    final lower = _archiveName.toLowerCase();
    for (final suffix in [
      '.tar.gz',
      '.tar.bz2',
      '.tar.xz',
      '.tbz2',
      '.tbz',
      '.tgz',
      '.txz',
      '.zip',
      '.7z',
      '.tar',
      '.rar',
      '.gz',
      '.bz2',
      '.xz',
    ]) {
      if (lower.endsWith(suffix))
        return _archiveName.substring(0, _archiveName.length - suffix.length);
    }

    return _archiveName;
  }

  String _resolveArchiveFolder(List<ArchiveEntry> entries, String folder) {
    final normalized = folder
        .replaceAll('\\', '/')
        .replaceAll(RegExp(r'^/+|/+$'), '');
    if (normalized.isEmpty ||
        normalized.split('/').any((part) => part == '.' || part == '..')) {
      return '';
    }
    final prefix = '$normalized/';
    final exists = entries.any(
      (entry) =>
          (entry.path == normalized && entry.isDirectory) ||
          entry.path.startsWith(prefix),
    );
    return exists ? normalized : '';
  }

  @override
  void initState() {
    super.initState();
    _progressSubscription = ref
        .read(archiveRepositoryProvider)
        .progress
        .listen(
          (progress) {
            if (!mounted || progress.operationId != _activeOperationId) return;
            setState(() => _progress = progress);
          },
          onError: (Object error) {
            debugPrint('Archive progress stream failed: $error');
          },
        );
    unawaited(_load());
  }

  @override
  void dispose() {
    final operationId = _activeOperationId;
    if (operationId != null) {
      unawaited(ref.read(archiveRepositoryProvider).cancel(operationId));
    }
    unawaited(_progressSubscription.cancel());
    super.dispose();
  }

  Future<void> _load({String? password}) async {
    final requestedFolder = _folder.isNotEmpty ? _folder : widget.initialFolder;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final entries = await ref
          .read(archiveRepositoryProvider)
          .listEntries(archivePath: widget.archivePath, password: password);
      if (!mounted) return;
      final restoredFolder = _resolveArchiveFolder(entries, requestedFolder);
      setState(() {
        _entries = entries;
        _password = password;
        _folder = restoredFolder;
        _selected.clear();
        _selectionMode = false;
        _loading = false;
      });
      if (restoredFolder != requestedFolder) {
        widget.onFolderChanged?.call(restoredFolder);
        if (requestedFolder.isNotEmpty) {
          _showMessage(
            'The saved folder inside ${_archiveName} is unavailable; showing the archive root.',
          );
        }
      }
      if (widget.autoExtractTo != null && !_autoExtractionStarted) {
        _autoExtractionStarted = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            unawaited(_extract(destinationOverride: widget.autoExtractTo));
          }
        });
      }
    } on PlatformException catch (error) {
      if (!mounted) return;
      if (error.code == 'PASSWORD_REQUIRED' || error.code == 'WRONG_PASSWORD') {
        final passwordValue = await _askForPassword(
          wrongPassword: error.code == 'WRONG_PASSWORD',
        );
        if (!mounted) return;
        if (passwordValue != null) {
          await _load(password: passwordValue);
          return;
        }
      }
      setState(() {
        _loading = false;
        _error = error.message ?? 'Could not read this archive';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not read this archive: $error';
      });
    }
  }

  Future<String?> _askForPassword({required bool wrongPassword}) async {
    final controller = TextEditingController();
    final password = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Archive password'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (wrongPassword)
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text('That password is incorrect. Try again.'),
              ),
            TextField(
              controller: controller,
              autofocus: true,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Password'),
              onSubmitted: (_) => Navigator.pop(dialogContext, controller.text),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    controller.dispose();
    return password;
  }

  List<_ArchiveChild> _children() {
    final prefix = _folder.isEmpty ? '' : '$_folder/';
    final children = <String, _ArchiveChild>{};
    for (final entry in _entries) {
      if (!entry.path.startsWith(prefix)) continue;
      final relative = entry.path.substring(prefix.length);
      if (relative.isEmpty) continue;
      final slash = relative.indexOf('/');
      if (slash >= 0) {
        final name = relative.substring(0, slash);
        final path = '$prefix$name';
        children.putIfAbsent(
          path,
          () => _ArchiveChild(path: path, name: name, isDirectory: true),
        );
      } else {
        children[entry.path] = _ArchiveChild(
          path: entry.path,
          name: entry.name,
          isDirectory: entry.isDirectory,
          size: entry.size,
          modifiedTime: entry.modifiedTime,
        );
      }
    }
    final result = children.values.toList()
      ..sort(
        (left, right) => compareSearchResults(
          left.name,
          left.isDirectory,
          right.name,
          right.isDirectory,
        ),
      );
    return result;
  }

  void _navigateBack() {
    if (_selectionMode) {
      setState(() {
        _selectionMode = false;
        _selected.clear();
      });
    } else if (_folder.isNotEmpty) {
      final parent = _folder.contains('/')
          ? _folder.substring(0, _folder.lastIndexOf('/'))
          : '';
      _setFolder(parent);
    } else {
      final onClose = widget.onClose;
      if (onClose != null) {
        onClose();
      } else {
        Navigator.of(context).maybePop();
      }
    }
  }

  bool handleWillPop() {
    _navigateBack();
    return true;
  }

  void _setFolder(String folder) {
    setState(() => _folder = folder);
    widget.onFolderChanged?.call(folder);
  }

  void _toggleSelection(_ArchiveChild entry) {
    setState(() {
      _selectionMode = true;
      if (_selected.contains(entry.path)) {
        _selected.remove(entry.path);
      } else {
        _selected.add(entry.path);
      }
      if (_selected.isEmpty) _selectionMode = false;
    });
  }

  Future<void> _showMenu() async {
    final action = await showMenu<String>(
      context: context,
      position: const RelativeRect.fromLTRB(1000, 80, 0, 0),
      items: [
        const PopupMenuItem(value: 'extract_all', child: Text('Extract all')),
        if (_selected.isNotEmpty)
          const PopupMenuItem(
            value: 'extract_selected',
            child: Text('Extract selected'),
          ),
        const PopupMenuItem(
          value: 'open_with',
          child: Text('Open with another app'),
        ),
      ],
    );
    if (!mounted || action == null) return;
    if (action == 'extract_all') {
      await _extract();
    } else if (action == 'extract_selected') {
      await _extract(selectedEntries: _selected.toList(growable: false));
    } else if (action == 'open_with') {
      await _openWithAnotherApp();
    }
  }

  Future<void> _extract({
    List<String>? selectedEntries,
    String? destinationOverride,
  }) async {
    final destination = destinationOverride ?? await _chooseDestination();
    if (!mounted || destination == null) return;
    final entries = selectedEntries == null
        ? _entries
        : _entries.where((entry) {
            return selectedEntries.any(
              (selected) =>
                  entry.path == selected || entry.path.startsWith('$selected/'),
            );
          }).toList();
    final estimatedBytes = entries
        .where((entry) => !entry.isDirectory)
        .fold<int>(0, (total, entry) => total + entry.size);
    try {
      final available = await ref
          .read(archiveRepositoryProvider)
          .availableBytes(destination);
      if (!mounted) return;
      if (estimatedBytes > available) {
        final proceed = await _confirmInsufficientSpace(
          estimatedBytes,
          available,
        );
        if (!mounted || !proceed) return;
      }
    } on PlatformException catch (error) {
      if (!mounted) return;
      _showMessage(error.message ?? 'Could not check destination free space');
      return;
    } catch (error) {
      if (!mounted) return;
      _showMessage('Could not check destination free space: $error');
      return;
    }

    final conflictAction = await _chooseConflictAction();
    if (!mounted || conflictAction == null) return;
    final operationId = DateTime.now().microsecondsSinceEpoch.toString();
    setState(() {
      _activeOperationId = operationId;
      _progress = null;
    });
    try {
      final result = await ref
          .read(archiveRepositoryProvider)
          .extract(
            operationId: operationId,
            archivePath: widget.archivePath,
            destinationPath: destination,
            selectedEntries: selectedEntries,
            password: _password,
            conflictActions: {'*': conflictAction},
          );
      if (!mounted) return;
      setState(() {
        _activeOperationId = null;
        _progress = null;
        _selected.clear();
        _selectionMode = false;
      });
      await StorageTabState.refreshMountedDirectories({
        destination,
        _archiveParent,
      });
      if (!mounted) return;
      await _showOperationResult(
        result.completed,
        result.skipped,
        result.failed,
        result.cancelled,
        result.messages,
      );
      if (widget.closeAfterAutoExtraction && mounted) {
        final onAutoExtractionComplete = widget.onAutoExtractionComplete;
        widget.onClose?.call();
        await onAutoExtractionComplete?.call();
      }
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() {
        _activeOperationId = null;
        _progress = null;
      });
      if (error.code == 'PASSWORD_REQUIRED' || error.code == 'WRONG_PASSWORD') {
        final password = await _askForPassword(
          wrongPassword: error.code == 'WRONG_PASSWORD',
        );
        if (!mounted) return;
        if (password != null) {
          setState(() => _password = password);
          await _extract(
            selectedEntries: selectedEntries,
            destinationOverride: destinationOverride,
          );
          return;
        }
      }
      _showMessage(_friendlyArchiveError(error));
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _activeOperationId = null;
        _progress = null;
      });
      _showMessage('Could not extract the archive: $error');
    }
  }

  Future<String?> _chooseDestination() async {
    final archiveFolder = _archiveParent.isEmpty ? '.' : _archiveParent;
    final choices = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.create_new_folder_outlined),
              title: Text('New folder: $_newFolderName'),
              subtitle: const Text('Next to the archive'),
              onTap: () => Navigator.pop(
                context,
                _joinPath(archiveFolder, _newFolderName),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: const Text('Archive folder'),
              onTap: () => Navigator.pop(context, archiveFolder),
            ),
            ListTile(
              leading: const Icon(Icons.folder_open_outlined),
              title: const Text('Choose folder...'),
              onTap: () => Navigator.pop(context, '__pick__'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || choices == null) return null;
    if (choices == '__pick__') {
      return showDialog<String>(
        context: context,
        builder: (_) => const ArchiveFolderPickerDialog(),
      );
    }
    return choices;
  }

  Future<bool> _confirmInsufficientSpace(int required, int available) async {
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Not enough free space'),
            content: Text(
              'The selected entries need about ${formatBytes(required)}; '
              'the destination has ${formatBytes(available)} available. Continue anyway?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Continue'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<String?> _chooseConflictAction() => showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('If an extracted item already exists'),
      content: const Text(
        'Choose how to handle all name conflicts in this operation.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, 'skip'),
          child: const Text('Skip'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, 'rename'),
          child: const Text('Rename'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, 'replace'),
          child: const Text('Replace'),
        ),
      ],
    ),
  );

  Future<void> _showOperationResult(
    int completed,
    int skipped,
    int failed,
    bool cancelled,
    List<String> messages,
  ) async {
    final title = cancelled ? 'Extraction cancelled' : 'Extraction complete';
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('$completed extracted, $skipped skipped, $failed failed.'),
                if (messages.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  for (final message in messages.take(40))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(message),
                    ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _openWithAnotherApp() async {
    final List<OpenWithApp> apps;
    try {
      apps = await ref
          .read(openWithRepositoryProvider)
          .listApps(path: widget.archivePath, category: 'Archives');
    } catch (error) {
      if (mounted)
        _showMessage('Could not find an app for this archive: $error');
      return;
    }
    if (!mounted) return;
    if (apps.isEmpty) {
      _showMessage('No app available to open this archive');
      return;
    }
    final app = await showDialog<OpenWithApp>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Open with another app'),
        children: [
          for (final item in apps)
            OpenWithAppOption(
              app: item,
              onTap: () => Navigator.pop(context, item),
            ),
        ],
      ),
    );
    if (!mounted || app == null) return;
    try {
      await ref
          .read(openWithRepositoryProvider)
          .openFile(
            path: widget.archivePath,
            category: 'Archives',
            packageName: app.packageName,
            activityName: app.activityName,
            mimeType: app.mimeType,
          );
    } catch (error) {
      if (mounted) _showMessage('Could not open the archive: $error');
    }
  }

  void _showMessage(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  String _friendlyArchiveError(PlatformException error) => switch (error.code) {
    'UNSUPPORTED_ENCRYPTION' =>
      error.message ?? 'This archive uses an unsupported encryption method',
    'UNSUPPORTED_FORMAT' =>
      error.message ?? 'This archive format is not supported',
    _ => error.message ?? 'Could not process this archive',
  };

  String _joinPath(String parent, String child) =>
      '$parent${parent.endsWith('/') || parent.endsWith('\\') ? '' : '/'}$child';

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final children = _children();
    final currentTitle = _folder.isEmpty
        ? _archiveName
        : _folder.split('/').last;
    final mutedStyle = Theme.of(context).textTheme.bodySmall?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
      fontSize: (Theme.of(context).textTheme.titleMedium?.fontSize ?? 16) - 4,
    );
    final nameStyle = Theme.of(context).textTheme.titleMedium?.copyWith(
      fontSize: (Theme.of(context).textTheme.titleMedium?.fontSize ?? 16) + 1,
    );
    return Scaffold(
      appBar: AppBar(
          leading: IconButton(
            tooltip: _folder.isNotEmpty || _selectionMode ? 'Back' : 'Close',
            onPressed: _navigateBack,
            icon: const Icon(Icons.arrow_back),
          ),
          title: MarqueeText(
            _selectionMode ? '${_selected.length} selected' : currentTitle,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          actions: [
            IconButton(
              tooltip: 'More options',
              onPressed: _showMenu,
              icon: const Icon(Icons.more_vert),
            ),
          ],
        ),
      body: Column(
          children: [
            if (_activeOperationId != null)
              Material(
                color: Theme.of(context).colorScheme.surfaceContainer,
                child: Padding(
                  padding: EdgeInsets.all(fontScaledSpacing(context, 10)),
                  child: Column(
                    children: [
                      LinearProgressIndicator(value: _progress?.fraction),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              _progress?.currentEntry ??
                                  'Preparing extraction…',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          TextButton(
                            onPressed: _cancelOperation,
                            child: const Text('Cancel'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                  ? _buildError(_error!)
                  : children.isEmpty
                  ? const Center(child: Text('This folder is empty'))
                  : Scrollbar(
                      thumbVisibility: true,
                      interactive: true,
                      child: ListView.separated(
                        itemCount: children.length,
                        separatorBuilder: (_, _) =>
                            SizedBox(height: fontScaledSpacing(context, 2)),
                        itemBuilder: (context, index) {
                        final entry = children[index];
                        final selected = _selected.contains(entry.path);
                        final modified = entry.modifiedTime;
                        final details = [
                          if (!entry.isDirectory) formatBytes(entry.size),
                          if (modified != null)
                            '${modified.year.toString().padLeft(4, '0')}-'
                                '${modified.month.toString().padLeft(2, '0')}-'
                                '${modified.day.toString().padLeft(2, '0')} '
                                '${formatClockTime(modified, use24HourTime: ref.read(appSettingsProvider).use24HourTime)}',
                        ].join('  •  ');
                        return GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onLongPress: () => _toggleSelection(entry),
                          onTap: () {
                            if (_selectionMode) {
                              _toggleSelection(entry);
                            } else if (entry.isDirectory) {
                              _setFolder(entry.path);
                            }
                          },
                          child: StorageEntryRow(
                            leading: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (_selectionMode)
                                  Icon(
                                    selected
                                        ? Icons.check_box
                                        : Icons.check_box_outline_blank,
                                    size: 20,
                                  ),
                                FileTypeIcon(
                                  extension: _extension(entry.name),
                                  isFolder: entry.isDirectory,
                                  size: 20,
                                ),
                              ],
                            ),
                            content: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                MarqueeText(
                                  entry.name,
                                  style: nameStyle,
                                  textAlign: TextAlign.left,
                                ),
                                if (details.isNotEmpty)
                                  Text(details, style: mutedStyle, maxLines: 1),
                              ],
                            ),
                            selected: selected,
                            detailsEnabled: details.isNotEmpty,
                          ),
                        );
                        },
                      ),
                    ),
            ),
          ],
        ),
    );
  }

  Widget _buildError(String message) {
    final unavailable =
        message.toLowerCase().contains('unsupported') ||
        widget.archivePath.toLowerCase().endsWith('.rar');
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            if (unavailable) ...[
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _openWithAnotherApp,
                icon: const Icon(Icons.open_in_new),
                label: const Text('Open with another app'),
              ),
            ],
            TextButton(onPressed: _load, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }

  Future<void> _cancelOperation() async {
    final operationId = _activeOperationId;
    if (operationId == null) return;
    try {
      await ref.read(archiveRepositoryProvider).cancel(operationId);
    } catch (error) {
      if (mounted) _showMessage('Could not cancel extraction: $error');
    }
  }

  String _extension(String name) {
    final dot = name.lastIndexOf('.');
    return dot <= 0 ? '' : name.substring(dot);
  }
}

class _ArchiveChild {
  const _ArchiveChild({
    required this.path,
    required this.name,
    required this.isDirectory,
    this.size = 0,
    this.modifiedTime,
  });

  final String path;
  final String name;
  final bool isDirectory;
  final int size;
  final DateTime? modifiedTime;
}

class ArchiveFolderPickerDialog extends ConsumerStatefulWidget {
  const ArchiveFolderPickerDialog({super.key});

  @override
  ConsumerState<ArchiveFolderPickerDialog> createState() =>
      _ArchiveFolderPickerDialogState();
}

class _ArchiveFolderPickerDialogState
    extends ConsumerState<ArchiveFolderPickerDialog> {
  List<StorageDevice> _drives = const [];
  List<FileSystemEntry> _folders = const [];
  String? _driveRoot;
  String? _path;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_loadDrives());
  }

  Future<void> _loadDrives() async {
    try {
      final drives = await ref
          .read(storageRepositoryProvider)
          .listStorageDevices();
      if (!mounted) return;
      setState(() {
        _drives = drives;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not list storage folders: $error';
      });
    }
  }

  Future<void> _open(String path, String root) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final entries = await ref
          .read(storageRepositoryProvider)
          .listDirectory(path);
      if (!mounted) return;
      setState(() {
        _path = path;
        _driveRoot = root;
        _folders = entries.where((entry) => entry.isDirectory).toList()
          ..sort((left, right) => compareStorageNames(left.name, right.name));
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not read this folder: $error';
        _loading = false;
      });
    }
  }

  String? get _parentPath {
    final path = _path;
    final root = _driveRoot;
    if (path == null || root == null || _samePath(path, root)) return null;
    final normalized = path.replaceAll('\\', '/');
    final parent = normalized.substring(0, normalized.lastIndexOf('/'));
    return parent.isEmpty ? '/' : parent;
  }

  bool _samePath(String left, String right) =>
      left.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '').toLowerCase() ==
      right.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '').toLowerCase();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          if (_path != null)
            IconButton(
              onPressed: _parentPath == null
                  ? () => setState(() {
                      _path = null;
                      _driveRoot = null;
                      _folders = const [];
                    })
                  : () => _open(_parentPath!, _driveRoot!),
              icon: const Icon(Icons.arrow_back),
            ),
          Expanded(
            child: Text(
              _path
                      ?.split(RegExp(r'[/\\]'))
                      .where((part) => part.isNotEmpty)
                      .lastOrNull ??
                  'Choose destination folder',
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        height: 360,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
            ? Center(child: Text(_error!))
            : _path == null
            ? Scrollbar(
                thumbVisibility: true,
                interactive: true,
                child: ListView(
                  children: [
                    for (final drive in _drives)
                      ListTile(
                        leading: const Icon(Icons.sd_storage_outlined),
                        title: Text(
                          storageDisplayName(path: drive.path, drive: drive),
                        ),
                        onTap: () => _open(drive.path, drive.path),
                      ),
                  ],
                ),
              )
            : Scrollbar(
                thumbVisibility: true,
                interactive: true,
                child: ListView(
                  children: [
                    for (final folder in _folders)
                      ListTile(
                        leading: const Icon(Icons.folder_outlined),
                        title: Text(storageDisplayName(path: folder.path)),
                        onTap: () => _open(folder.path, _driveRoot!),
                      ),
                  ],
                ),
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        if (_path != null)
          FilledButton(
            onPressed: () => Navigator.pop(context, _path),
            child: const Text('Use this folder'),
          ),
      ],
    );
  }
}

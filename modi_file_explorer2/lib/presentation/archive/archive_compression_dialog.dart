import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/archive_provider.dart';
import '../../core/utils/format_bytes.dart';
import '../../domain/entities/archive_operation_progress.dart';
import '../../domain/entities/archive_operation_result.dart';
import 'archive_manager_page.dart';

class ArchiveCompressionOutcome {
  const ArchiveCompressionOutcome({
    required this.outputPath,
    required this.cancelled,
    this.runningInBackground = false,
    this.error,
  });

  final String outputPath;
  final bool cancelled;
  final bool runningInBackground;
  final String? error;
}

class ArchiveCompressionDialog extends ConsumerStatefulWidget {
  const ArchiveCompressionDialog({
    super.key,
    required this.sourcePaths,
    required this.destinationPath,
    this.onBackgroundComplete,
  });

  final List<String> sourcePaths;
  final String destinationPath;
  final Future<void> Function(ArchiveCompressionOutcome outcome)?
  onBackgroundComplete;

  @override
  ConsumerState<ArchiveCompressionDialog> createState() =>
      _ArchiveCompressionDialogState();
}

class _ArchiveCompressionDialogState
    extends ConsumerState<ArchiveCompressionDialog> {
  static const _formatExtensions = {
    'ZIP': '.zip',
    '7z': '.7z',
    'TAR': '.tar',
    'TAR.GZ': '.tar.gz',
  };

  late final TextEditingController _nameController;
  late final TextEditingController _passwordController;
  final ScrollController _formScrollController = ScrollController();
  late final StreamSubscription<ArchiveOperationProgress> _progressSubscription;
  String _format = 'ZIP';
  String _compressionLevel = 'normal';
  late String _destinationPath;
  String? _activeOperationId;
  ArchiveOperationProgress? _progress;
  ArchiveOperationResult? _result;
  String? _outputPath;
  String? _error;
  bool _busy = false;
  bool _cancelRequested = false;
  bool _runInBackground = false;

  String get _targetPath {
    var name = _nameController.text.trim();
    for (final extension in _formatExtensions.values) {
      if (name.toLowerCase().endsWith(extension.toLowerCase())) {
        name = name.substring(0, name.length - extension.length);
        break;
      }
    }
    final filename = '$name${_formatExtensions[_format]!}';
    return '${_destinationPath.replaceFirst(RegExp(r'[/\\]+$'), '')}/$filename';
  }

  @override
  void initState() {
    super.initState();
    _destinationPath = widget.destinationPath;
    final names = widget.sourcePaths
        .map((path) => path.split(RegExp(r'[/\\]')).last)
        .toList(growable: false);
    _nameController = TextEditingController(
      text: names.length == 1 ? names.single : 'Archive',
    );
    _passwordController = TextEditingController();
    _progressSubscription = ref
        .read(archiveRepositoryProvider)
        .progress
        .listen(
          (progress) {
            if (!mounted || progress.operationId != _activeOperationId) return;
            setState(() => _progress = progress);
          },
          onError: (Object error) {
            debugPrint('Archive compression progress stream failed: $error');
          },
        );
  }

  @override
  void dispose() {
    final operationId = _activeOperationId;
    if (operationId != null && !_runInBackground) {
      unawaited(ref.read(archiveRepositoryProvider).cancel(operationId));
    }
    unawaited(_progressSubscription.cancel());
    _nameController.dispose();
    _passwordController.dispose();
    _formScrollController.dispose();
    super.dispose();
  }

  Future<void> _chooseDestination() async {
    final path = await showDialog<String>(
      context: context,
      builder: (_) => const ArchiveFolderPickerDialog(),
    );
    if (!mounted || path == null) return;
    setState(() => _destinationPath = path);
  }

  Future<String?> _chooseOutputConflict({
    required bool isDirectory,
  }) => showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(
        isDirectory ? 'Folder already exists' : 'Archive already exists',
      ),
      content: Text(
        isDirectory
            ? 'A folder named "${_targetPath.split('/').last}" already exists. Choose another archive name or rename the output.'
            : 'An item named "${_targetPath.split('/').last}" already exists in this folder.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, 'rename'),
          child: const Text('Rename'),
        ),
        if (!isDirectory)
          FilledButton(
            onPressed: () => Navigator.pop(context, 'replace'),
            child: const Text('Replace'),
          ),
      ],
    ),
  );

  Future<bool> _confirmInsufficientSpace(int required, int available) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Not enough free space'),
          content: Text(
            'The selected items use about ${formatBytes(required)}; '
            'the destination has ${formatBytes(available)} available. '
            'Continue anyway?',
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

  Future<void> _compress() async {
    final name = _nameController.text.trim();
    if (name.isEmpty ||
        name == '.' ||
        name == '..' ||
        name.contains('/') ||
        name.contains('\\')) {
      setState(
        () => _error = 'Enter a valid archive name without path separators.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _cancelRequested = false;
    });
    final repository = ref.read(archiveRepositoryProvider);
    String? conflictAction;
    try {
      if (await repository.pathExists(_targetPath)) {
        if (!mounted) return;
        if (_cancelRequested) {
          setState(() => _busy = false);
          return;
        }
        conflictAction = await _chooseOutputConflict(
          isDirectory: await repository.pathIsDirectory(_targetPath),
        );
        if (!mounted) return;
        if (conflictAction == null) {
          setState(() => _busy = false);
          return;
        }
      } else {
        conflictAction = 'cancel';
      }
      if (!mounted) return;
      if (_cancelRequested) {
        setState(() => _busy = false);
        return;
      }
      final estimate = await repository.estimateCreateBytes(
        archivePath: _targetPath,
        sourcePaths: widget.sourcePaths,
        excludeOutputPath: conflictAction != 'rename',
      );
      if (!mounted) return;
      if (_cancelRequested) {
        setState(() => _busy = false);
        return;
      }
      final available = await repository.availableBytes(_destinationPath);
      if (!mounted) return;
      if (_cancelRequested) {
        setState(() => _busy = false);
        return;
      }
      final overhead = estimate ~/ 100 < 1 << 20 ? 1 << 20 : estimate ~/ 100;
      final estimatedRequired = estimate + overhead;
      if (estimatedRequired > available &&
          !await _confirmInsufficientSpace(estimatedRequired, available)) {
        setState(() => _busy = false);
        return;
      }
      if (!mounted) return;
      if (_cancelRequested) {
        setState(() => _busy = false);
        return;
      }
      final operationId = DateTime.now().microsecondsSinceEpoch.toString();
      setState(() {
        _activeOperationId = operationId;
        _progress = null;
      });
      final result = await repository.create(
        operationId: operationId,
        archivePath: _targetPath,
        format: _format,
        sourcePaths: widget.sourcePaths,
        compressionLevel: _compressionLevel,
        conflictAction: conflictAction,
        password: _format == 'ZIP' && _passwordController.text.isNotEmpty
            ? _passwordController.text
            : null,
      );
      final outputPath = result.outputPath ?? _targetPath;
      if (_runInBackground) {
        await _notifyBackgroundComplete(
          ArchiveCompressionOutcome(
            outputPath: outputPath,
            cancelled: result.cancelled,
            runningInBackground: true,
          ),
        );
        return;
      }
      if (!mounted) return;
      setState(() {
        _activeOperationId = null;
        _progress = null;
        _busy = false;
        _result = result;
        _outputPath = result.outputPath ?? _targetPath;
      });
    } on PlatformException catch (error) {
      if (_runInBackground) {
        await _notifyBackgroundComplete(
          ArchiveCompressionOutcome(
            outputPath: _targetPath,
            cancelled: false,
            runningInBackground: true,
            error: error.message ?? 'Could not create the archive',
          ),
        );
        return;
      }
      if (!mounted) return;
      setState(() {
        _activeOperationId = null;
        _progress = null;
        _busy = false;
        _error = error.message ?? 'Could not create the archive';
      });
    } catch (error) {
      if (_runInBackground) {
        await _notifyBackgroundComplete(
          ArchiveCompressionOutcome(
            outputPath: _targetPath,
            cancelled: false,
            runningInBackground: true,
            error: 'Could not create the archive: $error',
          ),
        );
        return;
      }
      if (!mounted) return;
      setState(() {
        _activeOperationId = null;
        _progress = null;
        _busy = false;
        _error = 'Could not create the archive: $error';
      });
    }
  }

  Future<void> _notifyBackgroundComplete(
    ArchiveCompressionOutcome outcome,
  ) async {
    try {
      await widget.onBackgroundComplete?.call(outcome);
    } catch (error, stackTrace) {
      debugPrint('Compression background completion callback failed: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  Future<void> _cancel() async {
    final operationId = _activeOperationId;
    if (operationId == null) {
      setState(() => _cancelRequested = true);
      return;
    }
    try {
      await ref.read(archiveRepositoryProvider).cancel(operationId);
    } catch (error) {
      if (mounted) {
        setState(() => _error = 'Could not cancel compression: $error');
      }
    }
  }

  void _close() {
    final result = _result;
    if (result == null || _outputPath == null) {
      Navigator.pop(context);
      return;
    }

    Navigator.pop(
      context,
      ArchiveCompressionOutcome(
        outputPath: _outputPath!,
        cancelled: result.cancelled,
      ),
    );
  }

  void _continueInBackground() {
    final outputPath = _targetPath;
    setState(() => _runInBackground = true);
    Navigator.pop(
      context,
      ArchiveCompressionOutcome(
        outputPath: outputPath,
        cancelled: false,
        runningInBackground: true,
      ),
    );
  }

  String _outputName(String path) => path.split(RegExp(r'[/\\]')).last;

  @override
  Widget build(BuildContext context) {
    final progress = _progress;
    final result = _result;
    return PopScope(
      canPop: !_busy || _runInBackground,
      child: AlertDialog(
        title: Text(
          result == null
              ? 'Compress'
              : (result.cancelled
                    ? 'Compression cancelled'
                    : 'Compression complete'),
        ),
        content: SizedBox(
          width: 420,
          child: result != null
              ? _buildResult(result)
              : _busy
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    LinearProgressIndicator(value: progress?.fraction),
                    const SizedBox(height: 12),
                    Text(progress?.currentEntry ?? 'Preparing files…'),
                    Text(
                      '${progress?.completedEntries ?? 0} of ${progress?.totalEntries ?? 0} items',
                    ),
                    TextButton(
                      onPressed: _cancel,
                      child: const Text('Cancel compression'),
                    ),
                    if (_activeOperationId != null)
                      TextButton(
                        onPressed: _continueInBackground,
                        child: const Text('Continue in background'),
                      ),
                  ],
                )
              : _buildForm(),
        ),
        actions: result != null
            ? [TextButton(onPressed: _close, child: const Text('Close'))]
            : _busy
            ? const []
            : [
                TextButton(onPressed: _close, child: const Text('Cancel')),
                FilledButton(
                  onPressed: _compress,
                  child: const Text('Compress'),
                ),
              ],
      ),
    );
  }

  Widget _buildForm() => Scrollbar(
    controller: _formScrollController,
    thumbVisibility: true,
    interactive: true,
    child: SingleChildScrollView(
      controller: _formScrollController,
      child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DropdownButtonFormField<String>(
          initialValue: _format,
          decoration: const InputDecoration(labelText: 'Format'),
          items: [
            for (final format in _formatExtensions.keys)
              DropdownMenuItem(value: format, child: Text(format)),
          ],
          onChanged: (format) {
            if (format != null) setState(() => _format = format);
          },
        ),
        TextField(
          controller: _nameController,
          decoration: const InputDecoration(labelText: 'Archive name'),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Destination'),
          subtitle: Text(
            _destinationPath,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: IconButton(
            tooltip: 'Choose destination folder',
            onPressed: _chooseDestination,
            icon: const Icon(Icons.folder_open_outlined),
          ),
        ),
        const SizedBox(height: 8),
        const Text('Compression level'),
        const SizedBox(height: 6),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'fast', label: Text('Fast')),
            ButtonSegment(value: 'normal', label: Text('Normal')),
            ButtonSegment(value: 'maximum', label: Text('Maximum')),
          ],
          selected: {_compressionLevel},
          onSelectionChanged: _format == 'TAR'
              ? null
              : (selection) =>
                    setState(() => _compressionLevel = selection.single),
        ),
        if (_format == 'TAR')
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'TAR is uncompressed.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        if (_format == 'ZIP')
          TextField(
            controller: _passwordController,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Password (optional)',
              helperText: 'Uses AES encryption.',
            ),
          ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
      ],
      ),
    ),
  );

  Widget _buildResult(ArchiveOperationResult result) {
    final output = _outputPath ?? _targetPath;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          result.cancelled
              ? 'The partial archive was removed.'
              : _outputName(output),
        ),
        if (!result.cancelled && result.outputSize != null)
          Text('Size: ${formatBytes(result.outputSize!)}'),
        Text('${result.completed} items added, ${result.skipped} skipped.'),
        if (result.messages.isNotEmpty) ...[
          const SizedBox(height: 8),
          for (final message in result.messages.take(10)) Text(message),
        ],
      ],
    );
  }
}

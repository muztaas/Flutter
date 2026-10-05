import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/text_file_providers.dart';

enum TextEditorCloseDecision { save, discard, cancel }

class TextEditorTab extends ConsumerStatefulWidget {
  const TextEditorTab({super.key, required this.path});

  final String path;

  @override
  TextEditorTabState createState() => TextEditorTabState();
}

class TextEditorTabState extends ConsumerState<TextEditorTab>
    with AutomaticKeepAliveClientMixin {
  TextEditingController? _controller;
  final FocusNode _focusNode = FocusNode();
  Object? _loadError;
  bool _loading = true;
  bool _saving = false;
  bool _dirty = false;
  bool _editing = false;
  String? _lastSavedContents;

  bool get hasUnsavedChanges => _dirty;

  @override
  void initState() {
    super.initState();
    _loadFile();
  }

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _controller?.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _loadFile() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final contents = await ref
          .read(textFileRepositoryProvider)
          .readText(widget.path);
      if (!mounted) return;
      final controller = TextEditingController(text: contents)
        ..addListener(_onTextChanged);
      setState(() {
        _controller?.removeListener(_onTextChanged);
        _controller?.dispose();
        _controller = controller;
        _lastSavedContents = contents;
        _dirty = false;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = error;
        _loading = false;
      });
    }
  }

  void _onTextChanged() {
    final isDirty = _controller?.text != _lastSavedContents;
    if (_dirty != isDirty) setState(() => _dirty = isDirty);
  }

  void _toggleEditing() {
    if (_editing) {
      _focusNode.unfocus();
      setState(() => _editing = false);
      return;
    }
    setState(() => _editing = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _editing) _focusNode.requestFocus();
    });
  }

  Future<bool> saveFromClosePrompt() => _save(showFeedback: false);

  Future<bool> confirmClose(BuildContext context) async {
    if (!_dirty) return true;
    final decision = await showUnsavedChangesDialog(
      context,
      fileCount: 1,
      fileName: widget.path.split(RegExp(r'[/\\]')).last,
    );
    if (decision == TextEditorCloseDecision.cancel || decision == null) {
      return false;
    }
    if (decision == TextEditorCloseDecision.discard) return true;
    return _save(showFeedback: false);
  }

  static Future<TextEditorCloseDecision?> showUnsavedChangesDialog(
    BuildContext context, {
    required int fileCount,
    String? fileName,
    bool isExit = false,
  }) {
    final message = fileCount == 1
        ? 'Save changes to "$fileName" before ${isExit ? 'exiting' : 'closing'}?'
        : '$fileCount files have unsaved changes. Save them before exiting?';
    return showDialog<TextEditorCloseDecision>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Unsaved changes'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () =>
                Navigator.pop(context, TextEditorCloseDecision.cancel),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.pop(context, TextEditorCloseDecision.discard),
            child: const Text('Discard'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(context, TextEditorCloseDecision.save),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<bool> _save({bool showFeedback = true}) async {
    final contents = _controller?.text;
    if (contents == null || _saving) return false;
    setState(() => _saving = true);
    try {
      await ref
          .read(textFileRepositoryProvider)
          .writeText(widget.path, contents);
      if (!mounted) return false;
      setState(() {
        _saving = false;
        _lastSavedContents = contents;
        _dirty = _controller?.text != _lastSavedContents;
      });
      if (showFeedback) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('File saved')));
      }
      return true;
    } catch (error) {
      if (!mounted) return false;
      setState(() => _saving = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not save file: $error')));
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final fileName = widget.path.split(RegExp(r'[/\\]')).last;
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    return Column(
      children: [
        Material(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          child: SizedBox(
            height: 52,
            child: Row(
              children: [
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    fileName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  tooltip: _editing ? 'View file' : 'Edit file',
                  onPressed: _loading || _loadError != null
                      ? null
                      : _toggleEditing,
                  icon: Icon(
                    _editing ? Icons.edit : Icons.edit_outlined,
                    color: _editing ? Colors.green : null,
                  ),
                ),
                IconButton(
                  tooltip: 'Save',
                  onPressed: _dirty && !_saving ? _save : null,
                  icon: _saving
                      ? const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.save_outlined),
                ),
                const SizedBox(width: 8),
              ],
            ),
          ),
        ),
        Expanded(
          child: Padding(
            padding: EdgeInsets.only(bottom: bottomInset),
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _loadError != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('Could not open file: $_loadError'),
                          const SizedBox(height: 12),
                          FilledButton(
                            onPressed: _loadFile,
                            child: const Text('Retry'),
                          ),
                        ],
                      ),
                    ),
                  )
                : TextField(
                    controller: _controller,
                    focusNode: _focusNode,
                    readOnly: !_editing,
                    expands: true,
                    minLines: null,
                    maxLines: null,
                    textAlignVertical: TextAlignVertical.top,
                    keyboardType: TextInputType.multiline,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      alignLabelWithHint: true,
                    ),
                  ),
          ),
        ),
      ],
    );
  }
}

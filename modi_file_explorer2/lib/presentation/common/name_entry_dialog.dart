import 'package:flutter/material.dart';

Future<String?> showNameEntryDialog(
  BuildContext context, {
  required String title,
  String extensionNote = '',
  String initialName = '',
}) => showDialog<String>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _NameEntryDialog(
    title: title,
    extensionNote: extensionNote,
    initialName: initialName,
  ),
);

class _NameEntryDialog extends StatefulWidget {
  const _NameEntryDialog({
    required this.title,
    required this.extensionNote,
    required this.initialName,
  });

  final String title;
  final String extensionNote;
  final String initialName;

  @override
  State<_NameEntryDialog> createState() => _NameEntryDialogState();
}

class _NameEntryDialogState extends State<_NameEntryDialog> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    final extensionSeparator = widget.initialName.lastIndexOf('.');
    final cursorOffset =
        widget.title.startsWith('Rename') &&
            extensionSeparator > 0 &&
            extensionSeparator < widget.initialName.length - 1
        ? extensionSeparator
        : widget.initialName.length;
    _controller = TextEditingController.fromValue(
      TextEditingValue(
        text: widget.initialName,
        selection: TextSelection.collapsed(offset: cursorOffset),
      ),
    );
    _focusNode = FocusNode()..addListener(_handleFocusChange);
  }

  void _handleFocusChange() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.removeListener(_handleFocusChange);
    _focusNode.dispose();
    super.dispose();
  }

  void _handleTapOutside(PointerDownEvent event) {
    final keyboardVisible =
        _focusNode.hasFocus || MediaQuery.viewInsetsOf(context).bottom > 0;
    if (keyboardVisible) {
      _focusNode.unfocus();
    } else {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final keyboardVisible =
        _focusNode.hasFocus || MediaQuery.viewInsetsOf(context).bottom > 0;
    return PopScope(
      canPop: !keyboardVisible,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && keyboardVisible) _focusNode.unfocus();
      },
      child: TapRegion(
        onTapOutside: _handleTapOutside,
        consumeOutsideTaps: true,
        child: AlertDialog(
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
                focusNode: _focusNode,
                autofocus: true,
                decoration: InputDecoration(labelText: '${widget.title} name'),
                onSubmitted: (_) =>
                    Navigator.pop(context, _controller.text.trim()),
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
              child: Text(
                widget.title.startsWith('Rename') ? 'Rename' : 'Create',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

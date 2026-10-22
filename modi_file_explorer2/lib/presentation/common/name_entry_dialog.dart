import 'package:flutter/material.dart';

Future<String?> showNameEntryDialog(
  BuildContext context, {
  required String title,
  String extensionNote = '',
  String initialName = '',
}) => showDialog<String>(
  context: context,
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

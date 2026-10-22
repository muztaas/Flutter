import 'package:flutter/material.dart';

import '../../domain/entities/open_with_app.dart';

class OpenWithAppOption extends StatelessWidget {
  const OpenWithAppOption({
    super.key,
    required this.app,
    required this.onTap,
    this.label,
  });

  final OpenWithApp app;
  final VoidCallback onTap;
  final String? label;

  @override
  Widget build(BuildContext context) => SimpleDialogOption(
    onPressed: onTap,
    child: Row(
      children: [
        if (app.iconBytes case final iconBytes?)
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Image.memory(
              iconBytes,
              width: 32,
              height: 32,
              fit: BoxFit.contain,
              errorBuilder: (context, error, stackTrace) =>
                  const Icon(Icons.apps),
            ),
          )
        else
          const Icon(Icons.apps),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            label ?? app.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    ),
  );
}

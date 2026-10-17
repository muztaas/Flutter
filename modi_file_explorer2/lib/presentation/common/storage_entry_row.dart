import 'package:flutter/material.dart';

class StorageEntryRow extends StatelessWidget {
  const StorageEntryRow({
    super.key,
    required this.leading,
    required this.content,
    this.selected = false,
    this.detailsEnabled = false,
    this.detailsHeight = 52,
    this.grid = false,
    this.onTap,
  });

  final Widget leading;
  final Widget content;
  final bool selected;
  final bool detailsEnabled;
  final double detailsHeight;
  final bool grid;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    if (grid) {
      return Card(
        margin: EdgeInsets.zero,
        color: selected
            ? Theme.of(context).colorScheme.secondaryContainer
            : null,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                leading,
                const SizedBox(width: 8),
                Expanded(child: content),
              ],
            ),
          ),
        ),
      );
    }
    return ListTile(
      selected: selected,
      onTap: onTap,
      dense: true,
      visualDensity: const VisualDensity(vertical: -1),
      minVerticalPadding: 2,
      horizontalTitleGap: 12,
      leading: leading,
      title: detailsEnabled
          ? SizedBox(height: detailsHeight, child: content)
          : content,
    );
  }
}

import 'package:flutter/material.dart';
import '../../core/utils/font_scaled_spacing.dart';

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
            padding: EdgeInsets.symmetric(
              horizontal: fontScaledSpacing(context, 8),
              vertical: fontScaledSpacing(context, 4),
            ),
            child: Row(
              children: [
                leading,
                SizedBox(width: fontScaledSpacing(context, 8)),
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
      minVerticalPadding: fontScaledSpacing(context, 2),
      horizontalTitleGap: fontScaledSpacing(context, 12),
      leading: leading,
      title: detailsEnabled
          ? SizedBox(height: detailsHeight, child: content)
          : content,
    );
  }
}

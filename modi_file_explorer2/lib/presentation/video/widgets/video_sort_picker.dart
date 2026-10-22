import 'package:flutter/material.dart';

class VideoSortOption {
  const VideoSortOption(this.field, this.label, this.icon);

  final String field;
  final String label;
  final IconData icon;
}

const videoSortOptions = [
  VideoSortOption('title', 'Title', Icons.sort_by_alpha),
  VideoSortOption('date', 'Date', Icons.calendar_today_outlined),
  VideoSortOption('playedTime', 'Played time', Icons.history),
  VideoSortOption('status', 'Status', Icons.new_releases_outlined),
  VideoSortOption('length', 'Length', Icons.timer_outlined),
  VideoSortOption('size', 'Size', Icons.data_usage),
  VideoSortOption('resolution', 'Resolution', Icons.high_quality_outlined),
  VideoSortOption('path', 'Path', Icons.folder_outlined),
  VideoSortOption('frameRate', 'Frame rate', Icons.slow_motion_video),
  VideoSortOption('type', 'Type', Icons.insert_drive_file_outlined),
];

class VideoSortPicker extends StatefulWidget {
  const VideoSortPicker({
    super.key,
    required this.field,
    required this.ascending,
    required this.onChanged,
    this.applyFieldImmediately = true,
  });

  final String field;
  final bool ascending;
  final void Function(String field, bool ascending) onChanged;
  final bool applyFieldImmediately;

  @override
  State<VideoSortPicker> createState() => _VideoSortPickerState();
}

class _VideoSortPickerState extends State<VideoSortPicker> {
  late String _field;

  @override
  void initState() {
    super.initState();
    _field = widget.field;
  }

  @override
  void didUpdateWidget(covariant VideoSortPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.field != widget.field) _field = widget.field;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final directions = _directions(_field);
    final headingSize = theme.textTheme.titleMedium?.fontSize ?? 16;
    final baseLabelStyle = theme.textTheme.titleMedium?.copyWith(
      fontSize: headingSize - 1,
    );
    return Column(
      children: [
        GridView.builder(
          shrinkWrap: true,
          primary: false,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: videoSortOptions.length,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 5,
            mainAxisExtent: 64,
            crossAxisSpacing: 4,
            mainAxisSpacing: 4,
          ),
          itemBuilder: (context, index) {
            final item = videoSortOptions[index];
            final selected = item.field == _field;
            return LayoutBuilder(
              builder: (context, constraints) {
                final labelFontSize = _commonLabelFontSize(
                  context,
                  constraints.maxWidth - 4,
                  baseLabelStyle,
                );
                return InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () {
                    setState(() => _field = item.field);
                    if (widget.applyFieldImmediately) {
                      widget.onChanged(item.field, widget.ascending);
                    }
                  },
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: selected
                          ? theme.colorScheme.secondaryContainer
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: selected
                            ? theme.colorScheme.primary
                            : theme.colorScheme.outlineVariant,
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 1,
                        vertical: 3,
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            item.icon,
                            size: 28,
                            color: selected
                                ? theme.colorScheme.primary
                                : theme.colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            item.label,
                            maxLines: 1,
                            softWrap: false,
                            overflow: TextOverflow.clip,
                            textAlign: TextAlign.center,
                            style: baseLabelStyle?.copyWith(
                              fontSize: labelFontSize,
                              color: selected
                                  ? theme.colorScheme.onSecondaryContainer
                                  : theme.colorScheme.onSurface,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            );
          },
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _DirectionButton(
                label: directions.$1,
                selected: widget.ascending,
                icon: Icons.arrow_upward,
                onTap: () => widget.onChanged(_field, true),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _DirectionButton(
                label: directions.$2,
                selected: !widget.ascending,
                icon: Icons.arrow_downward,
                onTap: () => widget.onChanged(_field, false),
              ),
            ),
          ],
        ),
      ],
    );
  }

  double _commonLabelFontSize(
    BuildContext context,
    double maxWidth,
    TextStyle? baseStyle,
  ) {
    final baseSize = baseStyle?.fontSize ?? 15;
    if (maxWidth <= 0) return baseSize;
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    const longestLabels = ['Resolution', 'Played time', 'Frame rate'];

    bool fits(double fontSize) {
      for (final label in longestLabels) {
        final painter = TextPainter(
          text: TextSpan(
            text: label,
            style: baseStyle?.copyWith(fontSize: fontSize),
          ),
          textDirection: direction,
          textScaler: scaler,
          maxLines: 1,
        )..layout();
        if (painter.width > maxWidth) return false;
      }
      return true;
    }

    var low = 0.0;
    var high = baseSize;
    for (var attempt = 0; attempt < 16; attempt++) {
      final candidate = (low + high) / 2;
      if (fits(candidate)) {
        low = candidate;
      } else {
        high = candidate;
      }
    }
    return low;
  }

  static (String, String) _directions(String field) => switch (field) {
    'title' => ('A to Z', 'Z to A'),
    'date' || 'playedTime' => ('Oldest', 'Newest'),
    'length' => ('Shortest', 'Longest'),
    'resolution' || 'frameRate' => ('Lowest', 'Highest'),
    'size' => ('Smallest', 'Largest'),
    _ => ('Ascending', 'Descending'),
  };
}

class _DirectionButton extends StatelessWidget {
  const _DirectionButton({
    required this.label,
    required this.selected,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 18),
      label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      style: OutlinedButton.styleFrom(
        backgroundColor: selected
            ? Theme.of(context).colorScheme.secondaryContainer
            : null,
        foregroundColor: selected
            ? Theme.of(context).colorScheme.onSecondaryContainer
            : null,
        padding: const EdgeInsets.symmetric(horizontal: 6),
      ),
    );
  }
}

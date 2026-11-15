import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import 'animated_bar_visibility.dart';
import 'marquee_text.dart';

class BuiltInViewerShell extends StatefulWidget {
  const BuiltInViewerShell({
    super.key,
    required this.name,
    required this.child,
    required this.isChromeHidden,
    required this.onChromeHiddenChanged,
    required this.onOpenWithAnother,
    this.actions = const [],
    this.notShownFeatures = const [],
    this.notShownFeaturesProvider,
    this.notShownListenable,
  });

  final String name;
  final Widget child;
  final bool isChromeHidden;
  final ValueChanged<bool> onChromeHiddenChanged;
  final VoidCallback onOpenWithAnother;
  final List<Widget> actions;
  final List<String> notShownFeatures;
  final List<String> Function()? notShownFeaturesProvider;
  final Listenable? notShownListenable;

  @override
  State<BuiltInViewerShell> createState() => _BuiltInViewerShellState();
}

class _BuiltInViewerShellState extends State<BuiltInViewerShell> {
  bool _reportDismissed = false;
  late List<String> _lastFeatures;

  List<String> get _currentFeatures =>
      widget.notShownFeaturesProvider?.call() ?? widget.notShownFeatures;

  @override
  void initState() {
    super.initState();
    _lastFeatures = _currentFeatures;
    widget.notShownListenable?.addListener(_handleReportChanged);
  }

  @override
  void didUpdateWidget(covariant BuiltInViewerShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.notShownListenable != widget.notShownListenable) {
      oldWidget.notShownListenable?.removeListener(_handleReportChanged);
      widget.notShownListenable?.addListener(_handleReportChanged);
    }
    if (!listEquals(_lastFeatures, _currentFeatures)) {
      _reportDismissed = false;
      _lastFeatures = _currentFeatures;
    }
  }

  @override
  void dispose() {
    widget.notShownListenable?.removeListener(_handleReportChanged);
    super.dispose();
  }

  void _handleReportChanged() {
    if (!mounted) return;
    final features = _currentFeatures;
    setState(() {
      if (!listEquals(_lastFeatures, features)) {
        _reportDismissed = false;
        _lastFeatures = features;
      }
    });
  }

  Future<void> _showReport() async {
    final features = _currentFeatures;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Some content is not shown'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 320),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: features
                  .map(
                    (feature) => ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.info_outline, size: 20),
                      title: Text(feature),
                    ),
                  )
                  .toList(growable: false),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Theme.of(context).colorScheme.surface,
    child: Stack(
      fit: StackFit.expand,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: () => widget.onChromeHiddenChanged(!widget.isChromeHidden),
          child: widget.child,
        ),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: AnimatedBarVisibility(
            visible: !widget.isChromeHidden,
            height: 44,
            child: ColoredBox(
              color: Colors.grey.withValues(alpha: 0.72),
              child: Row(
                children: [
                  const SizedBox(width: 12),
                  Expanded(
                    child: MarqueeText(
                      widget.name,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                      styleMode: MarqueeStyle.pauseAndLoop,
                    ),
                  ),
                  ...widget.actions,
                  if (_currentFeatures.isNotEmpty && !_reportDismissed)
                    _NotShownNote(
                      onTap: _showReport,
                      onDismiss: () => setState(() => _reportDismissed = true),
                    ),
                  IconButton(
                    tooltip: 'Open with another app',
                    onPressed: widget.onOpenWithAnother,
                    icon: const Icon(Icons.open_in_new),
                  ),
                  IconButton(
                    tooltip: widget.isChromeHidden
                        ? 'Show viewer controls'
                        : 'Full screen',
                    onPressed: () =>
                        widget.onChromeHiddenChanged(!widget.isChromeHidden),
                    icon: Icon(
                      widget.isChromeHidden
                          ? Icons.fullscreen_exit
                          : Icons.fullscreen,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

class _NotShownNote extends StatelessWidget {
  const _NotShownNote({required this.onTap, required this.onDismiss});

  final VoidCallback onTap;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      IconButton(
        tooltip: 'Some content is not shown',
        visualDensity: VisualDensity.compact,
        onPressed: onTap,
        icon: const Icon(Icons.info_outline),
      ),
      IconButton(
        tooltip: 'Dismiss content notice',
        visualDensity: VisualDensity.compact,
        onPressed: onDismiss,
        icon: const Icon(Icons.close, size: 18),
      ),
    ],
  );
}

import 'package:flutter/material.dart';

import 'animated_bar_visibility.dart';
import 'marquee_text.dart';

class BuiltInViewerShell extends StatelessWidget {
  const BuiltInViewerShell({
    super.key,
    required this.name,
    required this.child,
    required this.isChromeHidden,
    required this.onChromeHiddenChanged,
    required this.onOpenWithAnother,
    this.actions = const [],
  });

  final String name;
  final Widget child;
  final bool isChromeHidden;
  final ValueChanged<bool> onChromeHiddenChanged;
  final VoidCallback onOpenWithAnother;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Theme.of(context).colorScheme.surface,
    child: Stack(
      fit: StackFit.expand,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: () => onChromeHiddenChanged(!isChromeHidden),
          child: child,
        ),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: AnimatedBarVisibility(
            visible: !isChromeHidden,
            height: 44,
            child: ColoredBox(
              color: Colors.grey.withValues(alpha: 0.72),
              child: Row(
                children: [
                  const SizedBox(width: 12),
                  Expanded(
                    child: MarqueeText(
                      name,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                      styleMode: MarqueeStyle.pauseAndLoop,
                    ),
                  ),
                  ...actions,
                  IconButton(
                    tooltip: 'Open with another app',
                    onPressed: onOpenWithAnother,
                    icon: const Icon(Icons.open_in_new),
                  ),
                  IconButton(
                    tooltip: isChromeHidden ? 'Show viewer controls' : 'Full screen',
                    onPressed: () =>
                        onChromeHiddenChanged(!isChromeHidden),
                    icon: Icon(
                      isChromeHidden ? Icons.fullscreen_exit : Icons.fullscreen,
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

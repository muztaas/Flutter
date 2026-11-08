import 'dart:async';

import 'package:flutter/material.dart';
import 'marquee_text.dart';

typedef ContentMenuChildBuilder =
    Widget Function(BuildContext context, VoidCallback openMenu);

List<ContentMenuItem<T>> contentMenuItemsFromPopupEntries<T>(
  Iterable<PopupMenuEntry<T>> entries,
) => [
  for (final entry in entries)
    if (entry is PopupMenuItem<T>)
      ContentMenuItem<T>(
        value: entry.value,
        child:
            entry.child ??
            (throw StateError('Popup menu item must have a child')),
        enabled: entry.enabled,
        padding: entry.padding ?? const EdgeInsets.symmetric(horizontal: 16),
        minHeight: entry.height,
      )
    else
      throw UnsupportedError(
        'Unsupported content menu entry: ${entry.runtimeType}',
      ),
];

class ContentMenuItem<T> {
  const ContentMenuItem({
    required this.child,
    this.value,
    this.enabled = true,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    this.minHeight = 48,
    this.onPressed,
  });

  final T? value;
  final Widget child;
  final bool enabled;
  final EdgeInsets padding;
  final double minHeight;
  final VoidCallback? onPressed;
}

class ContentSizedMenuButton<T> extends StatefulWidget {
  const ContentSizedMenuButton({
    super.key,
    required this.builder,
    required this.itemBuilder,
    required this.onSelected,
    this.menuColor,
    this.onOpened,
    this.onCanceled,
  });

  final ContentMenuChildBuilder builder;
  final PopupMenuItemBuilder<T> itemBuilder;
  final ValueChanged<T> onSelected;
  final Color? menuColor;
  final VoidCallback? onOpened;
  final VoidCallback? onCanceled;

  @override
  State<ContentSizedMenuButton<T>> createState() =>
      _ContentSizedMenuButtonState<T>();
}

class _ContentSizedMenuButtonState<T> extends State<ContentSizedMenuButton<T>> {
  final GlobalKey _anchorKey = GlobalKey();
  bool _isOpen = false;

  Future<void> _openMenu() async {
    if (_isOpen) {
      dismissContentSizedMenu();
      return;
    }
    final anchorContext = _anchorKey.currentContext;
    if (anchorContext == null) return;
    setState(() => _isOpen = true);
    widget.onOpened?.call();
    final selected = await showContentSizedMenu<T>(
      context: context,
      anchorContext: anchorContext,
      items: contentMenuItemsFromPopupEntries(widget.itemBuilder(context)),
      menuColor: widget.menuColor,
    );
    if (!mounted) return;
    setState(() => _isOpen = false);
    if (selected != null) {
      widget.onSelected(selected);
    } else {
      widget.onCanceled?.call();
    }
  }

  @override
  Widget build(BuildContext context) =>
      KeyedSubtree(key: _anchorKey, child: widget.builder(context, _openMenu));
}

class _ActiveContentMenu {
  _ActiveContentMenu(this.entry, this.finish);

  final OverlayEntry entry;
  final void Function(Object? value) finish;
}

_ActiveContentMenu? _activeContentMenu;

bool get hasOpenContentSizedMenu => _activeContentMenu != null;

void dismissContentSizedMenu() {
  _activeContentMenu?.finish(null);
}

Future<T?> showContentSizedMenu<T>({
  required BuildContext context,
  required BuildContext anchorContext,
  required List<ContentMenuItem<T>> items,
  Color? menuColor,
}) async {
  final anchorObject = anchorContext.findRenderObject();
  final overlay = Overlay.of(context, rootOverlay: true);
  final overlayObject = overlay.context.findRenderObject();
  if (anchorObject is! RenderBox ||
      overlayObject is! RenderBox ||
      !anchorObject.hasSize ||
      !overlayObject.hasSize) {
    return null;
  }

  dismissContentSizedMenu();
  final anchorTopLeft = anchorObject.localToGlobal(
    Offset.zero,
    ancestor: overlayObject,
  );
  final anchorRect = anchorTopLeft & anchorObject.size;
  if (items.isEmpty) return null;
  final completer = Completer<T?>();
  late final OverlayEntry entry;
  void finish(Object? value) {
    if (!identical(_activeContentMenu?.entry, entry)) return;
    _activeContentMenu = null;
    entry.remove();
    entry.dispose();
    if (!completer.isCompleted) completer.complete(value as T?);
  }

  entry = OverlayEntry(
    builder: (overlayContext) => _ContentMenuOverlay<T>(
      anchorRect: anchorRect,
      items: items,
      menuColor: menuColor,
      onSelected: finish,
      onDismiss: () => finish(null),
    ),
  );
  _activeContentMenu = _ActiveContentMenu(entry, finish);
  overlay.insert(entry);
  return completer.future;
}

Future<T?> showContentMenuFromPopupEntries<T>({
  required BuildContext context,
  required GlobalKey anchorKey,
  required Iterable<PopupMenuEntry<T>> entries,
}) {
  final anchorContext = anchorKey.currentContext;
  if (anchorContext == null) return Future<T?>.value();
  return showContentSizedMenu<T>(
    context: context,
    anchorContext: anchorContext,
    items: contentMenuItemsFromPopupEntries(entries),
  );
}

class _ContentMenuOverlay<T> extends StatelessWidget {
  const _ContentMenuOverlay({
    required this.anchorRect,
    required this.items,
    required this.menuColor,
    required this.onSelected,
    required this.onDismiss,
  });

  final Rect anchorRect;
  final List<ContentMenuItem<T>> items;
  final Color? menuColor;
  final ValueChanged<T> onSelected;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      const edgeInset = 8.0;
      const anchorGap = 4.0;
      final belowSpace = constraints.maxHeight - anchorRect.bottom - edgeInset;
      final aboveSpace = anchorRect.top - edgeInset;
      final openAbove = belowSpace < 200 && aboveSpace > belowSpace;
      final maxHeight = (openAbove ? aboveSpace : belowSpace).clamp(
        0.0,
        constraints.maxHeight - edgeInset * 2,
      );
      final right = (constraints.maxWidth - anchorRect.right).clamp(
        edgeInset,
        constraints.maxWidth - edgeInset,
      );
      final maxWidth = (anchorRect.right - edgeInset)
          .clamp(0.0, constraints.maxWidth - edgeInset * 2)
          .clamp(0.0, constraints.maxWidth * 0.6);
      final minimumWidthFraction =
          MediaQuery.orientationOf(context) == Orientation.portrait ? 0.4 : 0.2;
      final minWidth = (constraints.maxWidth * minimumWidthFraction).clamp(
        0.0,
        maxWidth,
      );
      final menuTextStyle =
          Theme.of(context).textTheme.titleMedium ?? const TextStyle();
      var naturalWidth = 0.0;
      for (final item in items) {
        final itemWidth =
            _measureMenuChildWidth(context, item.child, menuTextStyle) +
            item.padding.horizontal;
        if (itemWidth > naturalWidth) naturalWidth = itemWidth;
      }
      final menuWidth = naturalWidth.clamp(minWidth, maxWidth);
      return Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onDismiss,
              child: const SizedBox.expand(),
            ),
          ),
          Positioned(
            top: openAbove ? null : anchorRect.bottom + anchorGap,
            bottom: openAbove
                ? constraints.maxHeight - anchorRect.top + anchorGap
                : null,
            right: right,
            child: SizedBox(
              width: menuWidth,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: maxHeight),
                child: Material(
                  color:
                      menuColor ??
                      Theme.of(context).colorScheme.surfaceContainer,
                  elevation: 8,
                  clipBehavior: Clip.antiAlias,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: DefaultTextStyle(
                    style:
                        Theme.of(context).textTheme.titleMedium ??
                        const TextStyle(),
                    child: SingleChildScrollView(
                      primary: false,
                      child: Padding(
                        padding: const EdgeInsets.only(top: 8, bottom: 2),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (final item in items)
                              _ContentMenuItemWidget<T>(
                                item: item,
                                onSelected: onSelected,
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    },
  );
}

class _ContentMenuItemWidget<T> extends StatelessWidget {
  const _ContentMenuItemWidget({required this.item, required this.onSelected});

  final ContentMenuItem<T> item;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    final content = Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: item.padding,
        child: _withScrollableMenuLabels(context, item.child),
      ),
    );
    final constrained = ConstrainedBox(
      constraints: BoxConstraints(minHeight: item.minHeight),
      child: content,
    );
    if (!item.enabled || (item.value == null && item.onPressed == null)) {
      return constrained;
    }
    return InkWell(
      onTap: () {
        item.onPressed?.call();
        final value = item.value;
        if (value != null) onSelected(value);
      },
      child: constrained,
    );
  }
}

Widget _withScrollableMenuLabels(BuildContext context, Widget child) {
  if (child is Text) {
    final textSpan = child.textSpan;
    final text = child.data ?? textSpan?.toPlainText() ?? '';
    final style = child.style ?? DefaultTextStyle.of(context).style;
    return MarqueeText(
      text,
      textSpan: textSpan,
      style: style,
      textAlign: child.textAlign ?? TextAlign.start,
      styleMode: MarqueeStyle.pauseAndLoop,
    );
  }
  if (child is Row) {
    return Row(
      key: child.key,
      mainAxisAlignment: child.mainAxisAlignment,
      mainAxisSize: child.mainAxisSize,
      crossAxisAlignment: child.crossAxisAlignment,
      textDirection: child.textDirection,
      verticalDirection: child.verticalDirection,
      textBaseline: child.textBaseline,
      children: [
        for (final item in child.children)
          if (item is Text)
            Flexible(
              fit: FlexFit.loose,
              child: _withScrollableMenuLabels(context, item),
            )
          else
            _withScrollableMenuLabels(context, item),
      ],
    );
  }
  if (child is Padding) {
    return Padding(
      key: child.key,
      padding: child.padding,
      child: _withScrollableMenuLabels(context, child.child!),
    );
  }
  if (child is Align) {
    return Align(
      key: child.key,
      alignment: child.alignment,
      widthFactor: child.widthFactor,
      heightFactor: child.heightFactor,
      child: _withScrollableMenuLabels(context, child.child!),
    );
  }
  return child;
}

double _measureMenuChildWidth(
  BuildContext context,
  Widget child,
  TextStyle defaultStyle,
) {
  if (child is Text) {
    final style = defaultStyle.merge(child.style);
    final span = TextSpan(
      style: style,
      children: [child.textSpan ?? TextSpan(text: child.data ?? '')],
    );
    final painter = TextPainter(
      text: span,
      maxLines: 1,
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    return painter.width;
  }
  if (child is Icon) return child.size ?? 24;
  if (child is SizedBox) {
    return child.width ??
        (child.child == null
            ? 0
            : _measureMenuChildWidth(context, child.child!, defaultStyle));
  }
  if (child is Padding) {
    return child.padding.horizontal +
        _measureMenuChildWidth(context, child.child!, defaultStyle);
  }
  if (child is Align) {
    return _measureMenuChildWidth(context, child.child!, defaultStyle);
  }
  if (child is Flexible) {
    return _measureMenuChildWidth(context, child.child, defaultStyle);
  }
  if (child is Row) {
    return child.children.fold<double>(
      0,
      (width, item) =>
          width + _measureMenuChildWidth(context, item, defaultStyle),
    );
  }
  return 0;
}

import 'package:flutter/material.dart';

import '../../domain/repositories/csv_file_repository.dart';

abstract class SpreadsheetGridDataSource extends ChangeNotifier {
  int get rowCount;
  int get columnCount;
  List<int> get visibleColumnIndexes =>
      List<int>.generate(columnCount, (index) => index);
  int rowNumberAt(int rowIndex) => rowIndex + 1;
  double? columnWidthAt(int columnIndex) => null;
  double? rowHeightAt(int rowIndex) => null;
  String get statusText => '$rowCount rows';
  List<String> get omittedFeatureLabels => const [];
  bool get isIndexing;
  bool get isTruncated;
  String get truncationMessage;
  String? get warningMessage;
  Future<SpreadsheetRowData> loadRow(int rowIndex);
}

class SpreadsheetGrid extends StatefulWidget {
  const SpreadsheetGrid({super.key, required this.source, this.onZoomChanged});

  final SpreadsheetGridDataSource source;
  final ValueChanged<bool>? onZoomChanged;

  @override
  State<SpreadsheetGrid> createState() => _SpreadsheetGridState();
}

class _SpreadsheetGridState extends State<SpreadsheetGrid> {
  static const double _rowNumberWidth = 52;
  static const double _baseCellWidth = 132;
  static const double _baseRowHeight = 40;
  static const double _headerHeight = 34;

  final ScrollController _headerScrollController = ScrollController();
  final Map<int, ScrollController> _rowScrollControllers = {};
  double _horizontalOffset = 0;
  double _zoom = 1;
  double _zoomAtGestureStart = 1;
  String? _selectedCellText;
  bool _syncingScroll = false;
  bool _isDisposed = false;

  @override
  void initState() {
    super.initState();
    _headerScrollController.addListener(
      () => _syncHorizontalScroll(_headerScrollController),
    );
  }

  @override
  void dispose() {
    _isDisposed = true;
    _headerScrollController.dispose();
    for (final controller in _rowScrollControllers.values) {
      controller.dispose();
    }
    _rowScrollControllers.clear();
    super.dispose();
  }

  ScrollController _controllerForRow(int rowIndex) {
    final existing = _rowScrollControllers[rowIndex];
    if (existing != null) return existing;
    final controller = ScrollController(initialScrollOffset: _horizontalOffset);
    controller.addListener(() => _syncHorizontalScroll(controller));
    _rowScrollControllers[rowIndex] = controller;
    return controller;
  }

  void _releaseRowController(int rowIndex, ScrollController controller) {
    if (_isDisposed || !identical(_rowScrollControllers[rowIndex], controller)) {
      return;
    }
    _rowScrollControllers.remove(rowIndex);
    controller.dispose();
  }

  void _syncHorizontalScroll(ScrollController active) {
    if (_syncingScroll || _isDisposed || !active.hasClients) return;
    _horizontalOffset = active.offset;
    _syncingScroll = true;
    try {
      void sync(ScrollController controller) {
        if (!controller.hasClients) return;
        final offset = _horizontalOffset.clamp(
          0.0,
          controller.position.maxScrollExtent,
        );
        if ((controller.offset - offset).abs() > 0.5) {
          controller.jumpTo(offset);
        }
      }

      sync(_headerScrollController);
      for (final controller in _rowScrollControllers.values) {
        if (!identical(controller, active)) sync(controller);
      }
    } finally {
      _syncingScroll = false;
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.source,
    builder: (context, _) {
      final source = widget.source;
      final colors = Theme.of(context).colorScheme;
      final cellWidth = _baseCellWidth * _zoom;
      double widthForColumn(int index) =>
          (source.columnWidthAt(index) ?? _baseCellWidth) * _zoom;
      final columns = source.visibleColumnIndexes
          .take(maxSpreadsheetColumns)
          .toList(growable: false);
      final firstColumn = columns.firstOrNull;
      final remainingColumns = columns.skip(1);
      return Column(
        children: [
          if (_selectedCellText != null)
            SizedBox(
              height: 44,
              child: ColoredBox(
                color: colors.surfaceContainerHigh,
                child: Row(
                  children: [
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 10),
                      child: Icon(Icons.grid_on, size: 18),
                    ),
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: SelectableText(_selectedCellText!),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onScaleStart: (_) => _zoomAtGestureStart = _zoom,
              onScaleUpdate: (details) {
                if (details.pointerCount < 2) return;
                final zoom = (_zoomAtGestureStart * details.scale)
                    .clamp(0.65, 1.8)
                    .toDouble();
                if ((zoom - _zoom).abs() > 0.015) {
                  setState(() => _zoom = zoom);
                  widget.onZoomChanged?.call(zoom > 1.001);
                }
              },
              child: Column(
                children: [
                  SizedBox(
                    height: _headerHeight,
                    child: Row(
                      children: [
                        _gridCell(
                          '#',
                          width: _rowNumberWidth,
                          height: _headerHeight,
                          background: colors.surfaceContainerHighest,
                          bold: true,
                        ),
                        if (firstColumn != null)
                          _gridCell(
                            _columnLabel(firstColumn),
                            width: widthForColumn(firstColumn),
                            height: _headerHeight,
                            background: colors.surfaceContainerHighest,
                            bold: true,
                          ),
                        Expanded(
                          child: SingleChildScrollView(
                            controller: _headerScrollController,
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              children: [
                                for (final column in remainingColumns)
                                  _gridCell(
                                    _columnLabel(column),
                                    width: widthForColumn(column),
                                    height: _headerHeight,
                                    background: colors.surfaceContainerHighest,
                                    bold: true,
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: ListView.builder(
                      itemCount: source.rowCount,
                      itemBuilder: (context, rowIndex) => _SpreadsheetRow(
                        key: ValueKey(rowIndex),
                        source: source,
                        rowIndex: rowIndex,
                        columns: columns,
                        rowNumberWidth: _rowNumberWidth,
                        cellWidth: cellWidth,
                        rowNumber: source.rowNumberAt(rowIndex),
                        rowHeight:
                            (source.rowHeightAt(rowIndex) ?? _baseRowHeight) *
                            _zoom,
                        widthForColumn: widthForColumn,
                        horizontalController: _controllerForRow(rowIndex),
                        onHorizontalControllerDisposed: (controller) =>
                            _releaseRowController(rowIndex, controller),
                        onCellSelected: (text) =>
                            setState(() => _selectedCellText = text),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          SizedBox(
            height: 30,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Text(
                  source.isIndexing
                      ? 'Loading rows... ${source.rowCount} found'
                      : source.isTruncated
                      ? source.truncationMessage
                      : source.statusText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
            ),
          ),
          if (source.warningMessage != null)
            _gridNote(source.warningMessage!, color: colors.error),
          if (source.omittedFeatureLabels.isNotEmpty)
            _gridNote('Not shown: ${source.omittedFeatureLabels.join(', ')}'),
        ],
      );
    },
  );

  Widget _gridNote(String message, {Color? color}) => SizedBox(
    height: 28,
    child: Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Text(
          message,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
        ),
      ),
    ),
  );

  Widget _gridCell(
    String text, {
    required double width,
    required double height,
    required Color background,
    bool bold = false,
  }) => Container(
    width: width,
    height: height,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: background,
      border: Border.all(color: Theme.of(context).dividerColor, width: 0.5),
    ),
    child: Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: bold ? const TextStyle(fontWeight: FontWeight.w600) : null,
    ),
  );

  static String _columnLabel(int index) {
    var value = index + 1;
    final label = StringBuffer();
    while (value > 0) {
      value--;
      label.writeCharCode(65 + value % 26);
      value ~/= 26;
    }
    return String.fromCharCodes(label.toString().codeUnits.reversed);
  }
}

class _SpreadsheetRow extends StatefulWidget {
  const _SpreadsheetRow({
    super.key,
    required this.source,
    required this.rowIndex,
    required this.columns,
    required this.rowNumberWidth,
    required this.cellWidth,
    required this.rowNumber,
    required this.rowHeight,
    required this.widthForColumn,
    required this.horizontalController,
    required this.onHorizontalControllerDisposed,
    required this.onCellSelected,
  });

  final SpreadsheetGridDataSource source;
  final int rowIndex;
  final List<int> columns;
  final double rowNumberWidth;
  final double cellWidth;
  final int rowNumber;
  final double rowHeight;
  final double Function(int) widthForColumn;
  final ScrollController horizontalController;
  final ValueChanged<ScrollController> onHorizontalControllerDisposed;
  final ValueChanged<String> onCellSelected;

  @override
  State<_SpreadsheetRow> createState() => _SpreadsheetRowState();
}

class _SpreadsheetRowState extends State<_SpreadsheetRow> {
  late Future<SpreadsheetRowData> _row;

  @override
  void initState() {
    super.initState();
    _row = widget.source.loadRow(widget.rowIndex);
  }

  @override
  void didUpdateWidget(covariant _SpreadsheetRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source ||
        oldWidget.rowIndex != widget.rowIndex) {
      _row = widget.source.loadRow(widget.rowIndex);
    }
  }

  @override
  void dispose() {
    widget.onHorizontalControllerDisposed(widget.horizontalController);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<SpreadsheetRowData>(
    future: _row,
    builder: (context, snapshot) {
      final row = snapshot.data;
      final error = snapshot.error;
      return SizedBox(
        height: widget.rowHeight,
        child: Row(
          children: [
            Container(
              width: widget.rowNumberWidth,
              height: widget.rowHeight,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                border: Border.all(
                  color: Theme.of(context).dividerColor,
                  width: 0.5,
                ),
              ),
              child: Text(
                '${widget.rowNumber}',
                maxLines: 1,
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
            if (error != null)
              Expanded(
                child: Center(
                  child: Text(
                    'Could not read row: $error',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ),
              )
            else ...[
              if (widget.columns.isNotEmpty)
                _cell(context, row, widget.columns.first),
              Expanded(
                child: SingleChildScrollView(
                  controller: widget.horizontalController,
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final column in widget.columns.skip(1))
                        _cell(context, row, column),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      );
    },
  );

  Widget _cell(BuildContext context, SpreadsheetRowData? row, int column) {
    final value = row?.valueAt(column) ?? '';
    return InkWell(
      onTap: row == null ? null : () => widget.onCellSelected(value),
      child: Container(
        width: widget.widthForColumn(column),
        height: widget.rowHeight,
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          border: Border.all(color: Theme.of(context).dividerColor, width: 0.5),
        ),
        child: Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
    );
  }
}

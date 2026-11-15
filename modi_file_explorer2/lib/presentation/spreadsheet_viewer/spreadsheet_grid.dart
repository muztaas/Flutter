import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/repositories/csv_file_repository.dart';
import '../common/office_chart.dart';

abstract class SpreadsheetGridDataSource extends ChangeNotifier {
  int get rowCount;
  int get columnCount;
  List<int> get visibleColumnIndexes =>
      List<int>.generate(columnCount, (index) => index);
  int rowNumberAt(int rowIndex) => rowIndex + 1;
  double? columnWidthAt(int columnIndex) => null;
  double? rowHeightAt(int rowIndex) => null;
  String get statusText => '$rowCount rows x $columnCount columns';
  List<String> get omittedFeatureLabels => const [];
  List<Map<Object?, Object?>> get charts => const [];
  bool get isIndexing;
  bool get isTruncated;
  String get truncationMessage;
  String? get warningMessage;
  Future<SpreadsheetRowData> loadRow(int rowIndex);
}

class SpreadsheetGrid extends StatefulWidget {
  const SpreadsheetGrid({
    super.key,
    required this.source,
    this.onZoomChanged,
    this.freezePanes = false,
    this.freezeRowCount = 0,
    this.freezeColumnCount = 0,
  });

  final SpreadsheetGridDataSource source;
  final ValueChanged<bool>? onZoomChanged;
  final bool freezePanes;
  final int freezeRowCount;
  final int freezeColumnCount;

  @override
  SpreadsheetGridState createState() => SpreadsheetGridState();
}

class SpreadsheetGridState extends State<SpreadsheetGrid> {
  static const double _rowNumberWidth = 52;
  static const double _baseCellWidth = 132;
  static const double _baseRowHeight = 40;
  static const double _headerHeight = 34;

  final ScrollController _headerScrollController = ScrollController();
  final ScrollController _verticalScrollController = ScrollController();
  final Map<int, ScrollController> _rowScrollControllers = {};
  double _horizontalOffset = 0;
  double _zoom = 1;
  double _zoomAtGestureStart = 1;
  String? _selectedCellText;
  String? _selectedCellAddress;
  String? _searchStatus;
  bool _syncingScroll = false;
  bool _isDisposed = false;
  int _lastFoundRow = -1;
  int _lastFoundColumn = -1;
  String? _lastSearchQuery;

  @override
  void initState() {
    super.initState();
    _headerScrollController.addListener(
      () => _syncHorizontalScroll(_headerScrollController),
    );
    _headerScrollController.addListener(_rebuildChartOverlays);
    _verticalScrollController.addListener(_rebuildChartOverlays);
  }

  void _rebuildChartOverlays() {
    if (mounted && widget.source.charts.isNotEmpty) setState(() {});
  }

  @override
  void dispose() {
    _isDisposed = true;
    _headerScrollController.dispose();
    _verticalScrollController.dispose();
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
    if (_isDisposed ||
        !identical(_rowScrollControllers[rowIndex], controller)) {
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

  Future<bool> goToCell(String address) async {
    final match = RegExp(
      r'^([A-Za-z]{1,3})([1-9]\d*)$',
    ).firstMatch(address.trim());
    if (match == null) return false;
    var column = 0;
    for (final letter in match.group(1)!.toUpperCase().codeUnits) {
      column = column * 26 + letter - 64;
      if (column > maxSpreadsheetColumns) return false;
    }
    column--;
    final targetRow = int.tryParse(match.group(2)!);
    if (targetRow == null || column < 0) return false;
    final source = widget.source;
    while (mounted && source.isIndexing && source.rowCount < targetRow) {
      await _waitForSourceChange(source);
    }
    int? rowIndex;
    var low = 0;
    var high = source.rowCount - 1;
    while (low <= high) {
      final middle = (low + high) >> 1;
      final rowNumber = source.rowNumberAt(middle);
      if (rowNumber == targetRow) {
        rowIndex = middle;
        break;
      }
      if (rowNumber < targetRow) {
        low = middle + 1;
      } else {
        high = middle - 1;
      }
    }
    if (rowIndex == null || !mounted) return false;
    await WidgetsBinding.instance.endOfFrame;
    if (_verticalScrollController.hasClients) {
      var offset = 0.0;
      for (var index = 0; index < rowIndex; index++) {
        offset += (source.rowHeightAt(index) ?? _baseRowHeight) * _zoom;
      }
      _verticalScrollController.jumpTo(
        offset.clamp(0.0, _verticalScrollController.position.maxScrollExtent),
      );
    }
    var horizontalOffset = 0.0;
    for (final visibleColumn in source.visibleColumnIndexes) {
      if (visibleColumn >= column) break;
      horizontalOffset +=
          (source.columnWidthAt(visibleColumn) ?? _baseCellWidth) * _zoom;
    }
    await WidgetsBinding.instance.endOfFrame;
    if (_headerScrollController.hasClients) {
      _headerScrollController.jumpTo(
        horizontalOffset.clamp(
          0.0,
          _headerScrollController.position.maxScrollExtent,
        ),
      );
    }
    return true;
  }

  Future<String?> findNext(String query, {bool backwards = false}) async {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return null;
    final source = widget.source;
    if (_lastSearchQuery != needle) {
      _lastSearchQuery = needle;
      _lastFoundRow = -1;
      _lastFoundColumn = -1;
    }
    final initialRow = _lastFoundRow < 0
        ? (backwards ? source.rowCount - 1 : 0)
        : _lastFoundRow + (backwards ? -1 : 1);
    var rowIndex = initialRow;
    var scanned = 0;
    while (mounted) {
      if (rowIndex < 0 || rowIndex >= source.rowCount) {
        if (source.isIndexing && !backwards) {
          await _waitForSourceChange(source);
          continue;
        }
        rowIndex = backwards ? source.rowCount - 1 : 0;
      }
      if (source.rowCount == 0) {
        if (!source.isIndexing) break;
        await _waitForSourceChange(source);
        continue;
      }
      final row = await source.loadRow(rowIndex);
      final indexes =
          row.columnIndexes ??
          List<int>.generate(row.cells.length, (index) => index);
      final candidates = backwards ? indexes.reversed : indexes;
      for (final column in candidates) {
        if (scanned == 0 &&
            rowIndex == _lastFoundRow &&
            (backwards
                ? column >= _lastFoundColumn
                : column <= _lastFoundColumn)) {
          continue;
        }
        if (row.valueAt(column).toLowerCase().contains(needle)) {
          _lastFoundRow = rowIndex;
          _lastFoundColumn = column;
          final address =
              '${_columnLabel(column)}${row.rowNumber ?? source.rowNumberAt(rowIndex)}';
          await goToCell(address);
          if (mounted) setState(() => _searchStatus = 'Found $address');
          return address;
        }
      }
      scanned++;
      if (scanned % 128 == 0 && mounted) {
        setState(() => _searchStatus = 'Searching... $scanned rows checked');
      }
      rowIndex += backwards ? -1 : 1;
      if (scanned >= source.rowCount && !source.isIndexing) break;
    }
    if (mounted) setState(() => _searchStatus = 'No more matches');
    return null;
  }

  Future<void> _waitForSourceChange(SpreadsheetGridDataSource source) {
    final changed = Completer<void>();
    void listener() {
      if (!changed.isCompleted) changed.complete();
    }

    source.addListener(listener);
    if (!source.isIndexing || !mounted) listener();
    return changed.future.whenComplete(() => source.removeListener(listener));
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
      final frozenColumns = widget.freezePanes
          ? columns
                .where((column) => column < widget.freezeColumnCount)
                .toList(growable: false)
          : const <int>[];
      final scrollingColumns = columns
          .where((column) => !frozenColumns.contains(column))
          .toList(growable: false);
      final frozenRowCount = widget.freezePanes
          ? widget.freezeRowCount.clamp(0, source.rowCount).toInt()
          : 0;
      Widget buildRow(int rowIndex) => _SpreadsheetRow(
        key: ValueKey(rowIndex),
        source: source,
        rowIndex: rowIndex,
        columns: columns,
        frozenColumnCount: frozenColumns.length,
        rowNumberWidth: _rowNumberWidth,
        cellWidth: cellWidth,
        rowNumber: source.rowNumberAt(rowIndex),
        rowHeight: (source.rowHeightAt(rowIndex) ?? _baseRowHeight) * _zoom,
        widthForColumn: widthForColumn,
        horizontalController: _controllerForRow(rowIndex),
        onHorizontalControllerDisposed: (controller) =>
            _releaseRowController(rowIndex, controller),
        onCellSelected: (text, address) => setState(() {
          _selectedCellText = text;
          _selectedCellAddress = address;
        }),
      );
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
                        child: SelectableText(
                          '${_selectedCellAddress ?? ''}  $_selectedCellText',
                        ),
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
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Column(
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
                            for (final column in frozenColumns)
                              _gridCell(
                                _columnLabel(column),
                                width: widthForColumn(column),
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
                                    for (final column in scrollingColumns)
                                      _gridCell(
                                        _columnLabel(column),
                                        width: widthForColumn(column),
                                        height: _headerHeight,
                                        background:
                                            colors.surfaceContainerHighest,
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
                        child: Column(
                          children: [
                            for (
                              var index = 0;
                              index < frozenRowCount;
                              index++
                            )
                              buildRow(index),
                            Expanded(
                              child: ListView.builder(
                                itemCount: source.rowCount - frozenRowCount,
                                controller: _verticalScrollController,
                                itemBuilder: (context, index) =>
                                    buildRow(index + frozenRowCount),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  ..._chartOverlays(source, widthForColumn),
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
                  _searchStatus != null
                      ? _searchStatus!
                      : source.isIndexing
                      ? 'Loading rows... ${source.rowCount} found'
                      : source.isTruncated
                      ? source.truncationMessage
                      : '${source.statusText}${_selectedCellAddress == null ? '' : ' • $_selectedCellAddress'}',
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

  List<Widget> _chartOverlays(
    SpreadsheetGridDataSource source,
    double Function(int) widthForColumn,
  ) {
    if (source.charts.isEmpty) return const [];
    final overlays = <Widget>[];
    for (final chart in source.charts) {
      final chartData = chart['chartData'];
      if (chartData is! Map) continue;
      final column = (chart['column'] as num?)?.toInt() ?? 0;
      final row = (chart['row'] as num?)?.toInt() ?? 0;
      final widthColumns =
          ((chart['widthColumns'] as num?)?.toInt() ?? 5).clamp(1, 32);
      final heightRows =
          ((chart['heightRows'] as num?)?.toInt() ?? 8).clamp(1, 80);
      var left = _rowNumberWidth - _horizontalOffset;
      for (final visibleColumn in source.visibleColumnIndexes) {
        if (visibleColumn >= column) break;
        left += widthForColumn(visibleColumn);
      }
      var top = _headerHeight + (_selectedCellText == null ? 0 : 44);
      for (var index = 0; index < row && index < source.rowCount; index++) {
        top += (source.rowHeightAt(index) ?? _baseRowHeight) * _zoom;
      }
      if (_verticalScrollController.hasClients) {
        top -= _verticalScrollController.offset;
      }
      var width = 0.0;
      for (var index = column; index < column + widthColumns; index++) {
        width += widthForColumn(index);
      }
      var height = 0.0;
      for (var index = row; index < row + heightRows; index++) {
        height += (source.rowHeightAt(index) ?? _baseRowHeight) * _zoom;
      }
      overlays.add(
        Positioned(
          left: left,
          top: top,
          width: width,
          height: height,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                border: Border.all(
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
              ),
              child: OfficeChartView(
                chart: OfficeChartData.fromMap(
                  Map<Object?, Object?>.from(chartData),
                ),
              ),
            ),
          ),
        ),
      );
    }
    return overlays;
  }

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
    required this.frozenColumnCount,
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
  final int frozenColumnCount;
  final double rowNumberWidth;
  final double cellWidth;
  final int rowNumber;
  final double rowHeight;
  final double Function(int) widthForColumn;
  final ScrollController horizontalController;
  final ValueChanged<ScrollController> onHorizontalControllerDisposed;
  final void Function(String value, String address) onCellSelected;

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
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              )
            else ...[
              for (final column in widget.columns.take(
                widget.frozenColumnCount,
              ))
                _cell(context, row, column),
              Expanded(
                child: SingleChildScrollView(
                  controller: widget.horizontalController,
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final column in widget.columns.skip(
                        widget.frozenColumnCount,
                      ))
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
    final style = row?.styleAt(column) ?? const <String, Object?>{};
    final richRuns = row?.richTextAt(column);
    Color? colorValue(String key) {
      final value = style[key];
      return value is num ? Color(value.toInt()) : null;
    }

    final horizontal = switch (style['horizontalAlignment']) {
      'center' || 'centerContinuous' => Alignment.center,
      'right' => Alignment.centerRight,
      'fill' => Alignment.centerLeft,
      _ => Alignment.centerLeft,
    };
    final verticalFactor = switch (style['verticalAlignment']) {
      'top' => -1.0,
      'bottom' => 1.0,
      _ => 0.0,
    };
    final fontSize = style['fontSize'];
    final indent = style['indent'] is num
        ? ((style['indent'] as num).toDouble() * 10).clamp(0, 80).toDouble()
        : 0.0;
    final address =
        '${SpreadsheetGridState._columnLabel(column)}${row?.rowNumber ?? widget.rowNumber}';
    final borderColor =
        colorValue('borderColor') ?? Theme.of(context).dividerColor;
    final textStyle = Theme.of(context).textTheme.bodySmall?.copyWith(
      fontWeight: style['bold'] == true ? FontWeight.bold : null,
      fontStyle: style['italic'] == true ? FontStyle.italic : null,
      decoration: style['underline'] == true ? TextDecoration.underline : null,
      fontSize: fontSize is num ? fontSize.toDouble() * 4 / 3 : null,
      fontFamily: style['fontFamily'] as String?,
      color: colorValue('fontColor'),
    );
    final child = richRuns == null
        ? Text(
            value,
            style: textStyle,
            maxLines: style['wrapText'] == true ? null : 1,
            overflow: style['wrapText'] == true
                ? TextOverflow.visible
                : TextOverflow.ellipsis,
          )
        : Text.rich(
            TextSpan(
              children: [
                for (final run in richRuns)
                  TextSpan(
                    text: run['text'] as String? ?? '',
                    style: TextStyle(
                      fontWeight: run['bold'] == true ? FontWeight.bold : null,
                      fontStyle: run['italic'] == true
                          ? FontStyle.italic
                          : null,
                      color: run['color'] is num
                          ? Color((run['color'] as num).toInt())
                          : null,
                    ),
                  ),
              ],
            ),
            style: textStyle,
            maxLines: style['wrapText'] == true ? null : 1,
            overflow: style['wrapText'] == true
                ? TextOverflow.visible
                : TextOverflow.ellipsis,
          );
    return InkWell(
      onTap: row == null ? null : () => widget.onCellSelected(value, address),
      onLongPress: row == null
          ? null
          : () async {
              await Clipboard.setData(ClipboardData(text: value));
              if (!context.mounted) return;
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(SnackBar(content: Text('Copied $address')));
            },
      child: Container(
        width: widget.widthForColumn(column),
        height: widget.rowHeight,
        alignment: Alignment(horizontal.x, verticalFactor),
        padding: EdgeInsets.only(left: 8 + indent, right: 8),
        decoration: BoxDecoration(
          color: colorValue('fillColor'),
          border: Border.all(color: borderColor, width: 0.5),
        ),
        child: DefaultTextStyle.merge(
          textAlign: switch (style['horizontalAlignment']) {
            'center' || 'centerContinuous' => TextAlign.center,
            'right' => TextAlign.right,
            _ => TextAlign.left,
          },
          child: child,
        ),
      ),
    );
  }
}

Future<void> showSpreadsheetGoToCell(
  BuildContext context,
  GlobalKey<SpreadsheetGridState> gridKey,
) async {
  final controller = TextEditingController();
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Go to cell'),
      content: TextField(
        controller: controller,
        autofocus: true,
        textCapitalization: TextCapitalization.characters,
        decoration: const InputDecoration(hintText: 'For example, B2000'),
        onSubmitted: (_) => Navigator.of(dialogContext).pop(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Go'),
        ),
      ],
    ),
  );
  final address = controller.text.trim();
  controller.dispose();
  if (!context.mounted || address.isEmpty) return;
  final found = await gridKey.currentState?.goToCell(address) ?? false;
  if (!context.mounted) return;
  if (!found) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('That cell is outside the loaded sheet.')),
    );
  }
}

Future<void> showSpreadsheetFind(
  BuildContext context,
  GlobalKey<SpreadsheetGridState> gridKey,
) async {
  final controller = TextEditingController();
  var searching = false;
  var status = '';
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setDialogState) {
        Future<void> runSearch(bool backwards) async {
          if (searching || controller.text.trim().isEmpty) return;
          setDialogState(() {
            searching = true;
            status = 'Searching...';
          });
          String? result;
          Object? searchError;
          try {
            result = await gridKey.currentState?.findNext(
              controller.text,
              backwards: backwards,
            );
          } catch (error) {
            searchError = error;
          }
          if (!dialogContext.mounted) return;
          setDialogState(() {
            searching = false;
            status = searchError != null
                ? 'Search stopped: $searchError'
                : result == null
                ? 'No more matches'
                : 'Found $result';
          });
        }

        return AlertDialog(
          title: const Text('Find in sheet'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: controller,
                autofocus: true,
                decoration: const InputDecoration(hintText: 'Search text'),
                onSubmitted: (_) => runSearch(false),
              ),
              if (searching) ...[
                const SizedBox(height: 12),
                const LinearProgressIndicator(),
              ],
              if (status.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(status),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: searching ? null : () => runSearch(true),
              child: const Text('Previous'),
            ),
            TextButton(
              onPressed: searching ? null : () => runSearch(false),
              child: const Text('Next'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    ),
  );
  controller.dispose();
}

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/xlsx_file_provider.dart';
import '../../domain/repositories/csv_file_repository.dart';
import '../../domain/repositories/xlsx_file_repository.dart';
import '../common/built_in_viewer_shell.dart';
import '../common/marquee_text.dart';
import '../common/open_spreadsheet_file.dart';
import 'spreadsheet_grid.dart';

class XlsxViewerTab extends ConsumerStatefulWidget {
  const XlsxViewerTab({
    super.key,
    required this.path,
    required this.isChromeHidden,
    required this.onChromeHiddenChanged,
    required this.onZoomChanged,
  });

  final String path;
  final bool isChromeHidden;
  final ValueChanged<bool> onChromeHiddenChanged;
  final ValueChanged<bool> onZoomChanged;

  @override
  ConsumerState<XlsxViewerTab> createState() => _XlsxViewerTabState();
}

class _XlsxViewerTabState extends ConsumerState<XlsxViewerTab>
    with AutomaticKeepAliveClientMixin {
  XlsxReadSession? _session;
  XlsxSpreadsheetGridSource? _source;
  List<XlsxSheetInfo> _sheets = const [];
  int _selectedSheet = 0;
  int _loadGeneration = 0;
  Object? _loadError;
  bool _isVisible = false;
  bool _isOpening = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _setVisible(MarqueeVisibility.isVisibleOf(context));
  }

  @override
  void didUpdateWidget(covariant XlsxViewerTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) {
      _closeWorkbook();
      _loadError = null;
      if (_isVisible) unawaited(_openFile());
    }
  }

  @override
  void dispose() {
    _isVisible = false;
    _closeWorkbook();
    super.dispose();
  }

  void _setVisible(bool visible) {
    if (_isVisible == visible) return;
    _isVisible = visible;
    if (visible) {
      if (_session == null && !_isOpening) unawaited(_openFile());
    } else {
      _closeWorkbook();
    }
  }

  void _closeWorkbook() {
    ++_loadGeneration;
    final source = _source;
    final session = _session;
    _source = null;
    _session = null;
    _sheets = const [];
    _isOpening = false;
    source?.dispose();
    if (session != null) unawaited(session.close());
  }

  Future<void> _openFile() async {
    if (!_isVisible || _isOpening) return;
    final generation = ++_loadGeneration;
    setState(() {
      _isOpening = true;
      _loadError = null;
    });
    XlsxReadSession? session;
    try {
      session = await ref.read(xlsxFileRepositoryProvider).open(widget.path);
      if (!mounted || !_isVisible || generation != _loadGeneration) {
        await session.close();
        return;
      }
      if (session.sheets.isEmpty) {
        throw const FormatException('The workbook contains no visible sheets.');
      }
      final source = await XlsxSpreadsheetGridSource.open(
        session,
        session.sheets.first,
      );
      if (!mounted || !_isVisible || generation != _loadGeneration) {
        source.dispose();
        await session.close();
        return;
      }
      setState(() {
        _session = session;
        _sheets = session!.sheets;
        _source = source;
        _selectedSheet = 0;
        _isOpening = false;
      });
      source.continueParsing();
    } catch (error) {
      if (session != null) await session.close();
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _loadError = error;
        _isOpening = false;
      });
    }
  }

  Future<void> _selectSheet(int index) async {
    final session = _session;
    if (session == null || index == _selectedSheet) return;
    final generation = ++_loadGeneration;
    final oldSource = _source;
    oldSource?.dispose();
    setState(() {
      _source = null;
      _selectedSheet = index;
      _loadError = null;
    });
    try {
      final source = await XlsxSpreadsheetGridSource.open(
        session,
        _sheets[index],
      );
      if (!mounted || !_isVisible || generation != _loadGeneration) {
        source.dispose();
        return;
      }
      setState(() => _source = source);
      source.continueParsing();
    } catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() => _loadError = error);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final source = _source;
    return BuiltInViewerShell(
      name: widget.path.split(RegExp(r'[/\\]')).last,
      isChromeHidden: widget.isChromeHidden,
      onChromeHiddenChanged: widget.onChromeHiddenChanged,
      onOpenWithAnother: () => openSpreadsheetFile(
        context,
        ref,
        path: widget.path,
        name: widget.path.split(RegExp(r'[/\\]')).last,
        excludeBuiltIn: true,
        useSavedDefaultApps: false,
        allowSaveDefault: false,
      ),
      child: _loadError != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Could not open this XLSX workbook: $_loadError',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : source == null
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 12),
                  Text('Loading workbook...'),
                ],
              ),
            )
          : Column(
              children: [
                Expanded(
                  child: SpreadsheetGrid(
                    key: ValueKey(_selectedSheet),
                    source: source,
                    onZoomChanged: widget.onZoomChanged,
                  ),
                ),
                _SheetTabs(
                  sheets: _sheets,
                  selectedIndex: _selectedSheet,
                  onSelected: (index) => unawaited(_selectSheet(index)),
                ),
              ],
            ),
    );
  }
}

class _SheetTabs extends StatelessWidget {
  const _SheetTabs({
    required this.sheets,
    required this.selectedIndex,
    required this.onSelected,
  });

  final List<XlsxSheetInfo> sheets;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 48,
    child: Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: sheets.length,
        itemBuilder: (context, index) {
          final selected = index == selectedIndex;
          return InkWell(
            onTap: () => onSelected(index),
            child: Container(
              constraints: const BoxConstraints(minWidth: 96, maxWidth: 200),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: selected
                        ? Theme.of(context).colorScheme.primary
                        : Colors.transparent,
                    width: 2,
                  ),
                ),
              ),
              child: MarqueeText(
                sheets[index].name,
                isActive: selected,
                style: Theme.of(context).textTheme.labelLarge,
                styleMode: MarqueeStyle.pauseAndLoop,
              ),
            ),
          );
        },
      ),
    ),
  );
}

class XlsxSpreadsheetGridSource extends SpreadsheetGridDataSource {
  static const int _maxCachedRows = 64;

  XlsxSpreadsheetGridSource._(this._session, this.sheet)
    : _rowCount = 0,
      _isComplete = false,
      _isTruncated = false,
      _columnCount = 1,
      _visibleColumnIndexes = const [0],
      _columnWidths = const {},
      _omittedFeatureLabels = const [],
      _defaultRowHeight = sheet.defaultRowHeight;

  static Future<XlsxSpreadsheetGridSource> open(
    XlsxReadSession session,
    XlsxSheetInfo sheet,
  ) async {
    final source = XlsxSpreadsheetGridSource._(session, sheet);
    source._applyProgress(await session.openSheet(sheet.id));
    return source;
  }

  final XlsxReadSession _session;
  final XlsxSheetInfo sheet;
  final Map<int, Future<SpreadsheetRowData>> _rowCache = {};
  int _rowCount;
  bool _isComplete;
  bool _isTruncated;
  int _columnCount;
  List<int> _visibleColumnIndexes;
  Map<int, double> _columnWidths;
  List<String> _omittedFeatureLabels;
  double _defaultRowHeight;
  final List<int> _rowNumbers = [];
  final Map<int, double> _rowHeights = {};
  String? _warningMessage;
  bool _stopped = false;
  bool _parsing = false;

  @override
  int get rowCount => _rowCount;

  @override
  int get columnCount => _columnCount;

  @override
  List<int> get visibleColumnIndexes => _visibleColumnIndexes;

  @override
  int rowNumberAt(int rowIndex) =>
      rowIndex >= 0 && rowIndex < _rowNumbers.length
      ? _rowNumbers[rowIndex]
      : rowIndex + 1;

  @override
  double? columnWidthAt(int columnIndex) => _columnWidths[columnIndex];

  @override
  double? rowHeightAt(int rowIndex) =>
      _rowHeights[rowIndex] ?? _defaultRowHeight * 4 / 3;

  @override
  String get statusText => '$_rowCount rows';

  @override
  List<String> get omittedFeatureLabels => _omittedFeatureLabels;

  @override
  bool get isIndexing => !_isComplete && _warningMessage == null;

  @override
  bool get isTruncated => _isTruncated;

  @override
  String get truncationMessage {
    if (_rowCount >= 200000) {
      return 'Showing the first 200,000 rows';
    }
    if (_columnCount > 256) return 'Showing the first 256 columns';
    return 'Some spreadsheet content exceeds viewer limits';
  }

  @override
  String? get warningMessage => _warningMessage;

  void _applyProgress(XlsxSheetProgress progress) {
    _rowCount = progress.rowCount;
    _isComplete = progress.isComplete;
    _isTruncated = progress.isTruncated;
    _columnCount = progress.columnCount;
    _visibleColumnIndexes = progress.visibleColumnIndexes;
    _columnWidths = progress.columnWidths;
    _omittedFeatureLabels = progress.omittedFeatureLabels;
    _defaultRowHeight = progress.defaultRowHeight;
    if (progress.rows.any((row) => row.isTruncated)) {
      _warningMessage = 'Some cell text exceeded the XLSX viewer limit.';
    }
    for (var offset = 0; offset < progress.rows.length; offset++) {
      final row = progress.rows[offset];
      final index = progress.startRowIndex + offset;
      if (_rowNumbers.length == index) {
        _rowNumbers.add(row.rowNumber ?? index + 1);
      }
      if (row.rowHeight != null) {
        _rowHeights[index] = row.rowHeight! * 4 / 3;
      }
      _rowCache[index] = Future.value(row);
    }
    while (_rowCache.length > _maxCachedRows) {
      _rowCache.remove(_rowCache.keys.first);
    }
  }

  void continueParsing() {
    if (_parsing || _stopped || _isComplete) return;
    _parsing = true;
    unawaited(_parseRemaining());
  }

  Future<void> _parseRemaining() async {
    try {
      while (!_stopped && !_isComplete) {
        _applyProgress(await _session.readNextRows());
        if (!_stopped) notifyListeners();
      }
    } catch (error) {
      if (!_stopped) {
        _warningMessage = 'Worksheet parsing stopped: $error';
        _isComplete = true;
        notifyListeners();
      }
    } finally {
      _parsing = false;
    }
  }

  @override
  Future<SpreadsheetRowData> loadRow(int rowIndex) {
    if (_stopped) return Future.error(StateError('Worksheet is closed'));
    final cached = _rowCache.remove(rowIndex);
    if (cached != null) {
      _rowCache[rowIndex] = cached;
      return cached;
    }
    final result = _session.readRow(rowIndex).then((row) {
      if (row.isTruncated && !_stopped) {
        _warningMessage = 'Some cell text exceeded the XLSX viewer limit.';
        notifyListeners();
      }
      if (row.rowHeight != null && !_stopped) {
        _rowHeights[rowIndex] = row.rowHeight! * 4 / 3;
        if (row.rowNumber != null && rowIndex < _rowNumbers.length) {
          _rowNumbers[rowIndex] = row.rowNumber!;
        }
      }
      return row;
    });
    _rowCache[rowIndex] = result;
    while (_rowCache.length > _maxCachedRows) {
      _rowCache.remove(_rowCache.keys.first);
    }
    return result;
  }

  @override
  void dispose() {
    _stopped = true;
    _rowCache.clear();
    super.dispose();
  }
}

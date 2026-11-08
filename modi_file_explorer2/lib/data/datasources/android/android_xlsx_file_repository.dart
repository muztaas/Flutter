import 'package:flutter/services.dart';

import '../../../domain/repositories/csv_file_repository.dart';
import '../../../domain/repositories/xlsx_file_repository.dart';

class AndroidXlsxFileRepository implements XlsxFileRepository {
  static const _channel = MethodChannel('modi_file_explorer2/xlsx');

  @override
  Future<XlsxReadSession> open(String path) async {
    final response = await _channel.invokeMapMethod<String, Object?>(
      'openWorkbook',
      {'path': path},
    );
    if (response == null) {
      throw const FormatException('The workbook reader returned no data.');
    }
    return _AndroidXlsxReadSession(
      _channel,
      response['id']! as String,
      (response['sheets']! as List)
          .cast<Map<Object?, Object?>>()
          .map(
            (sheet) => XlsxSheetInfo(
              id: sheet['id']! as String,
              name: sheet['name']! as String,
              defaultRowHeight: (sheet['defaultRowHeight'] as num).toDouble(),
            ),
          )
          .toList(growable: false),
    );
  }
}

class _AndroidXlsxReadSession implements XlsxReadSession {
  _AndroidXlsxReadSession(this._channel, this._id, this.sheets);

  final MethodChannel _channel;
  final String _id;
  @override
  final List<XlsxSheetInfo> sheets;

  bool _closed = false;
  bool _sheetOpen = false;

  @override
  Future<XlsxSheetProgress> openSheet(String sheetId) async {
    _ensureOpen();
    final result = await _invoke('openSheet', {'sheetId': sheetId});
    _sheetOpen = true;
    return _decodeProgress(result);
  }

  @override
  Future<XlsxSheetProgress> readNextRows() async {
    _ensureOpen();
    if (!_sheetOpen) throw StateError('No worksheet is open');
    final result = await _invoke('readNextRows');
    return _decodeProgress(result);
  }

  @override
  Future<SpreadsheetRowData> readRow(int rowIndex) async {
    _ensureOpen();
    if (!_sheetOpen) throw StateError('No worksheet is open');
    return _decodeRow(await _invoke('readRow', {'index': rowIndex}));
  }

  Future<Map<String, Object?>> _invoke(
    String method, [
    Map<String, Object?> arguments = const {},
  ]) async {
    final result = await _channel.invokeMapMethod<String, Object?>(
      method,
      {'id': _id, ...arguments},
    );
    if (result == null) {
      throw const FormatException('The workbook reader returned no data.');
    }
    return result;
  }

  XlsxSheetProgress _decodeProgress(Map<String, Object?> result) {
    final widths = <int, double>{};
    for (final entry in (result['columnWidths']! as Map).entries) {
      widths[int.parse(entry.key as String)] = (entry.value as num).toDouble();
    }
    return XlsxSheetProgress(
      rows: (result['rows']! as List)
          .cast<Map<Object?, Object?>>()
          .map(_decodeRow)
          .toList(growable: false),
      startRowIndex: result['startRowIndex']! as int,
      rowCount: result['rowCount']! as int,
      defaultRowHeight: (result['defaultRowHeight']! as num).toDouble(),
      isComplete: result['complete']! as bool,
      isTruncated: result['truncated']! as bool,
      columnCount: result['columnCount']! as int,
      visibleColumnIndexes: (result['visibleColumns']! as List)
          .cast<int>()
          .toList(growable: false),
      columnWidths: widths,
      omittedFeatureLabels: (result['omittedFeatures']! as List)
          .cast<String>()
          .toList(growable: false),
    );
  }

  SpreadsheetRowData _decodeRow(Map<Object?, Object?> row) =>
      SpreadsheetRowData(
        columnIndexes: (row['columns']! as List).cast<int>(),
        cells: (row['values']! as List).cast<String>(),
        rowNumber: row['rowNumber']! as int,
        rowHeight: (row['height'] as num?)?.toDouble(),
        isTruncated: row['truncated']! as bool,
      );

  void _ensureOpen() {
    if (_closed) throw StateError('The workbook is closed');
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _channel.invokeMethod<void>('closeWorkbook', {'id': _id});
  }
}

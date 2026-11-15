import 'csv_file_repository.dart';

class XlsxSheetInfo {
  const XlsxSheetInfo({
    required this.id,
    required this.name,
    required this.defaultRowHeight,
    this.tabColor,
  });

  final String id;
  final String name;
  final double defaultRowHeight;
  final int? tabColor;
}

class XlsxSheetProgress {
  const XlsxSheetProgress({
    required this.rows,
    required this.startRowIndex,
    required this.rowCount,
    required this.defaultRowHeight,
    required this.isComplete,
    required this.isTruncated,
    required this.columnCount,
    required this.visibleColumnIndexes,
    required this.columnWidths,
    required this.omittedFeatureLabels,
    required this.freezeRowCount,
    required this.freezeColumnCount,
    this.tabColor,
    this.notShownFeatures = const [],
    this.charts = const [],
  });

  final List<SpreadsheetRowData> rows;
  final int startRowIndex;
  final int rowCount;
  final double defaultRowHeight;
  final bool isComplete;
  final bool isTruncated;
  final int columnCount;
  final List<int> visibleColumnIndexes;
  final Map<int, double> columnWidths;
  final List<String> omittedFeatureLabels;
  final int freezeRowCount;
  final int freezeColumnCount;
  final int? tabColor;
  final List<String> notShownFeatures;
  final List<Map<Object?, Object?>> charts;
}

abstract interface class XlsxFileRepository {
  Future<XlsxReadSession> open(String path);
}

abstract interface class XlsxReadSession {
  List<XlsxSheetInfo> get sheets;
  Future<XlsxSheetProgress> openSheet(String sheetId);
  Future<XlsxSheetProgress> readNextRows();
  Future<SpreadsheetRowData> readRow(int rowIndex);
  Future<void> close();
}

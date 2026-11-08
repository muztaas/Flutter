import 'csv_file_repository.dart';

class XlsxSheetInfo {
  const XlsxSheetInfo({
    required this.id,
    required this.name,
    required this.defaultRowHeight,
  });

  final String id;
  final String name;
  final double defaultRowHeight;
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

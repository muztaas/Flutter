enum CsvTextEncoding { utf8, utf16LittleEndian, utf16BigEndian, windows1252 }

const int maxCsvRows = 200000;
const int maxSpreadsheetColumns = 256;

class CsvIndexProgress {
  const CsvIndexProgress({
    required this.rowCount,
    required this.columnCount,
    required this.isComplete,
    required this.isTruncated,
  });

  final int rowCount;
  final int columnCount;
  final bool isComplete;
  final bool isTruncated;
}

class SpreadsheetRowData {
  const SpreadsheetRowData({
    required this.cells,
    required this.isTruncated,
    this.columnIndexes,
    this.rowNumber,
    this.rowHeight,
    this.cellStyles = const [],
    this.cellRichText = const [],
  });

  final List<String> cells;
  final bool isTruncated;
  final List<int>? columnIndexes;
  final int? rowNumber;
  final double? rowHeight;
  final List<Map<String, Object?>> cellStyles;
  final List<List<Map<String, Object?>>?> cellRichText;

  Map<String, Object?>? styleAt(int column) {
    final indexes = columnIndexes;
    if (indexes == null) return null;
    final index = _findColumn(indexes, column);
    return index < 0 || index >= cellStyles.length ? null : cellStyles[index];
  }

  List<Map<String, Object?>>? richTextAt(int column) {
    final indexes = columnIndexes;
    if (indexes == null) return null;
    final index = _findColumn(indexes, column);
    return index < 0 || index >= cellRichText.length
        ? null
        : cellRichText[index];
  }

  String valueAt(int column) {
    final indexes = columnIndexes;
    if (indexes == null) {
      return column >= 0 && column < cells.length ? cells[column] : '';
    }
    final index = _findColumn(indexes, column);
    return index < 0 ? '' : cells[index];
  }

  static int _findColumn(List<int> indexes, int column) {
    var low = 0;
    var high = indexes.length - 1;
    while (low <= high) {
      final middle = (low + high) >> 1;
      final candidate = indexes[middle];
      if (candidate == column) return middle;
      if (candidate < column) {
        low = middle + 1;
      } else {
        high = middle - 1;
      }
    }
    return -1;
  }
}

abstract interface class CsvFileRepository {
  Future<CsvReadSession> open(String path);
}

abstract interface class CsvReadSession {
  Stream<CsvIndexProgress> get progress;
  CsvIndexProgress get currentProgress;
  CsvTextEncoding get encoding;
  String get delimiter;

  Future<SpreadsheetRowData> readRow(int rowIndex);
  Future<void> close();
}

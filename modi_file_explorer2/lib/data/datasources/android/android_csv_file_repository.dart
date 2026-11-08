import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import '../../../domain/repositories/csv_file_repository.dart';
import 'csv_limits.dart';

class AndroidCsvFileRepository implements CsvFileRepository {
  @override
  Future<CsvReadSession> open(String path) async {
    final events = ReceivePort();
    final session = _AndroidCsvReadSession(events);
    final isolate = await Isolate.spawn(
      _csvWorker,
      (path, events.sendPort),
      onError: events.sendPort,
      onExit: events.sendPort,
    );
    session._setIsolate(isolate);
    try {
      await session._opened.future;
      return session;
    } catch (_) {
      await session.close();
      rethrow;
    }
  }
}

class _AndroidCsvReadSession implements CsvReadSession {
  _AndroidCsvReadSession(this._events) {
    _subscription = _events.listen(_handleMessage);
  }

  final ReceivePort _events;
  late final StreamSubscription<Object?> _subscription;
  final _opened = Completer<void>();
  final _done = Completer<void>();
  final _progressController = StreamController<CsvIndexProgress>.broadcast();
  final Map<int, Completer<SpreadsheetRowData>> _pendingRows = {};
  Isolate? _isolate;
  SendPort? _commands;
  int _nextRequestId = 0;
  bool _closed = false;
  CsvTextEncoding _encoding = CsvTextEncoding.utf8;
  String _delimiter = ',';
  CsvIndexProgress _currentProgress = const CsvIndexProgress(
    rowCount: 0,
    columnCount: 1,
    isComplete: false,
    isTruncated: false,
  );

  void _setIsolate(Isolate isolate) => _isolate = isolate;

  @override
  Stream<CsvIndexProgress> get progress => _progressController.stream;

  @override
  CsvIndexProgress get currentProgress => _currentProgress;

  @override
  CsvTextEncoding get encoding => _encoding;

  @override
  String get delimiter => _delimiter;

  void _handleMessage(Object? message) {
    if (message == null) {
      if (!_done.isCompleted) _done.complete();
      return;
    }
    if (message is List && message.length == 2 && message.first is String) {
      _fail(
        FileSystemException(
          'Could not read CSV file: ${message.first}',
          message[1] is String ? message[1] as String : null,
        ),
      );
      return;
    }
    if (message is! Map) return;
    final type = message['type'];
    if (type == 'ready') {
      _commands = message['commands'] as SendPort;
      return;
    }
    if (type == 'opened') {
      _encoding = CsvTextEncoding.values[message['encoding'] as int];
      _delimiter = message['delimiter'] as String;
      _opened.complete();
      return;
    }
    if (type == 'progress') {
      _currentProgress = CsvIndexProgress(
        rowCount: message['rows'] as int,
        columnCount: message['columns'] as int,
        isComplete: message['complete'] as bool,
        isTruncated: message['truncated'] as bool,
      );
      _progressController.add(_currentProgress);
      return;
    }
    if (type == 'row') {
      final id = message['id'] as int;
      final completer = _pendingRows.remove(id);
      if (completer != null) {
        completer.complete(
          SpreadsheetRowData(
            cells: (message['cells'] as List).cast<String>(),
            isTruncated: message['truncated'] as bool,
          ),
        );
      }
      return;
    }
    if (type == 'error') {
      _fail(
        FileSystemException(
          message['message'] as String,
          message['path'] as String?,
        ),
      );
    }
  }

  void _fail(Object error) {
    if (!_opened.isCompleted) _opened.completeError(error);
    if (!_progressController.isClosed) {
      _progressController.addError(error);
    }
    for (final request in _pendingRows.values) {
      if (!request.isCompleted) request.completeError(error);
    }
    _pendingRows.clear();
  }

  @override
  Future<SpreadsheetRowData> readRow(int rowIndex) {
    if (_closed) {
      return Future.error(StateError('CSV reader is closed'));
    }
    final commands = _commands;
    if (commands == null) {
      return Future.error(StateError('CSV reader is not ready'));
    }
    final id = _nextRequestId++;
    final completer = Completer<SpreadsheetRowData>();
    _pendingRows[id] = completer;
    commands.send({'type': 'row', 'id': id, 'index': rowIndex});
    return completer.future;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _commands?.send(const {'type': 'close'});
    if (_commands != null) await _done.future;
    _isolate?.kill(priority: Isolate.immediate);
    await _subscription.cancel();
    _events.close();
    await _progressController.close();
    for (final request in _pendingRows.values) {
      if (!request.isCompleted) {
        request.completeError(StateError('CSV reader was closed'));
      }
    }
    _pendingRows.clear();
  }
}

Future<void> _csvWorker((String, SendPort) args) async {
  final (path, output) = args;
  final commands = ReceivePort();
  output.send({'type': 'ready', 'commands': commands.sendPort});

  RandomAccessFile? file;
  var isClosed = false;
  final pendingRows = Queue<Map>();
  Completer<void>? pendingRowSignal;

  commands.listen((message) {
    if (message is! Map) return;
    if (message['type'] == 'close') {
      isClosed = true;
      pendingRowSignal?.complete();
    } else if (message['type'] == 'row') {
      pendingRows.add(Map.from(message));
      pendingRowSignal?.complete();
    }
  });

  try {
    file = await File(path).open(mode: FileMode.read);
    final fileSize = await file.length();
    if (fileSize > maxCsvFileSizeBytes) {
      throw FileSystemException(
        'CSV files larger than 1 GiB are not supported',
        path,
      );
    }
    final headerLength = fileSize.clamp(0, csvIndexChunkBytes + 4).toInt();
    final header = await file.read(headerLength);
    final encoding = _detectEncoding(header);
    final bomLength = switch (encoding) {
      CsvTextEncoding.utf8 => _hasUtf8Bom(header) ? 3 : 0,
      CsvTextEncoding.utf16LittleEndian ||
      CsvTextEncoding.utf16BigEndian => 2,
      CsvTextEncoding.windows1252 => 0,
    };
    final sample = header.sublist(bomLength);
    if (encoding != CsvTextEncoding.utf16LittleEndian &&
        encoding != CsvTextEncoding.utf16BigEndian &&
        sample.contains(0)) {
      throw FileSystemException('This file is not a text CSV or TSV file', path);
    }
    final delimiter = _detectDelimiter(sample, encoding);
    await file.setPosition(bomLength);
    output.send({
      'type': 'opened',
      'encoding': encoding.index,
      'delimiter': delimiter,
    });

    final rowStarts = <int>[bomLength];
    var columns = 1;
    var currentColumns = 1;
    var inQuotes = false;
    var quotePending = false;
    var atFieldStart = true;
    var skipLf = false;
    var scanOffset = bomLength;
    var truncated = false;
    var lastPublishedRows = 0;
    final unitWidth = switch (encoding) {
      CsvTextEncoding.utf16LittleEndian ||
      CsvTextEncoding.utf16BigEndian => 2,
      _ => 1,
    };

    while (!isClosed && scanOffset < fileSize) {
      await file.setPosition(scanOffset);
      final bytes = await file.read(csvIndexChunkBytes);
      if (bytes.isEmpty) break;
      var index = 0;
      var reachedRowLimit = false;
      while (index + unitWidth <= bytes.length) {
        final unit = _readCodeUnit(bytes, index, encoding);
        index += unitWidth;
        final unitEnd = scanOffset + index;

        if (skipLf) {
          skipLf = false;
          if (unit == 0x0a) {
            rowStarts[rowStarts.length - 1] = unitEnd;
            continue;
          }
        }

        if (quotePending) {
          quotePending = false;
          if (unit == 0x22) {
            continue;
          }
          inQuotes = false;
        }

        if (inQuotes) {
          if (unit == 0x22) quotePending = true;
          continue;
        }

        if (unit == 0x22 && atFieldStart) {
          inQuotes = true;
          atFieldStart = false;
        } else if (unit == delimiter.codeUnitAt(0)) {
          atFieldStart = true;
          if (currentColumns < maxSpreadsheetColumns) currentColumns++;
          if (currentColumns > columns) columns = currentColumns;
        } else if (unit == 0x0d || unit == 0x0a) {
          rowStarts.add(unitEnd);
          atFieldStart = true;
          currentColumns = 1;
          if (unit == 0x0d) skipLf = true;
          final indexedRows = rowStarts.length - 1;
          if (indexedRows >= maxCsvRows) {
            final onlyTrailingLineFeed =
                unit == 0x0d && unitEnd + unitWidth == fileSize;
            truncated = unitEnd < fileSize && !onlyTrailingLineFeed;
            scanOffset = onlyTrailingLineFeed ? fileSize : unitEnd;
            if (onlyTrailingLineFeed) rowStarts[rowStarts.length - 1] = fileSize;
            reachedRowLimit = true;
            break;
          }
        } else {
          atFieldStart = false;
        }

      }
      if (!reachedRowLimit) scanOffset += bytes.length;
      await _drainRows(
        file,
        path,
        output,
        pendingRows,
        rowStarts,
        fileSize,
        encoding,
        delimiter,
      );
      final indexedRows = rowStarts.length - 1;
      if (indexedRows != lastPublishedRows &&
          (lastPublishedRows == 0 ||
              indexedRows - lastPublishedRows >= csvProgressBatchRows)) {
        lastPublishedRows = indexedRows;
        output.send({
          'type': 'progress',
          'rows': indexedRows,
          'columns': columns,
          'complete': false,
          'truncated': false,
        });
      }
      if (indexedRows >= maxCsvRows) {
        truncated = scanOffset < fileSize || rowStarts.last < fileSize;
        break;
      }
    }

    if (!isClosed &&
        rowStarts.last < fileSize &&
        rowStarts.length - 1 < maxCsvRows) {
      rowStarts.add(fileSize);
    }
    if (!isClosed) {
      output.send({
        'type': 'progress',
        'rows': rowStarts.length - 1,
        'columns': columns,
        'complete': true,
        'truncated': truncated,
      });
    }

    while (!isClosed) {
      await _drainRows(
        file,
        path,
        output,
        pendingRows,
        rowStarts,
        fileSize,
        encoding,
        delimiter,
      );
      if (isClosed) break;
      pendingRowSignal = Completer<void>();
      await pendingRowSignal.future;
      pendingRowSignal = null;
    }
  } catch (error) {
    output.send({
      'type': 'error',
      'message': error.toString(),
      'path': path,
    });
  } finally {
    await file?.close();
    commands.close();
  }
}

Future<void> _drainRows(
  RandomAccessFile file,
  String path,
  SendPort output,
  Queue<Map> pendingRows,
  List<int> rowStarts,
  int fileSize,
  CsvTextEncoding encoding,
  String delimiter,
) async {
  while (pendingRows.isNotEmpty) {
    final request = pendingRows.removeFirst();
    final id = request['id'] as int;
    final rowIndex = request['index'] as int;
    if (rowIndex < 0 || rowIndex + 1 >= rowStarts.length) {
      output.send({
        'type': 'error',
        'message': 'The requested CSV row is not indexed yet',
        'path': path,
      });
      continue;
    }
    final start = rowStarts[rowIndex];
    final end = rowStarts[rowIndex + 1].clamp(start, fileSize);
    final rowByteLength = end - start;
    final byteLength = rowByteLength.clamp(0, maxCsvRowBytes).toInt();
    await file.setPosition(start);
    final bytes = await file.read(byteLength);
    var text = _decodeCsvBytes(bytes, encoding);
    text = text.replaceFirst(RegExp(r'[\r\n]+$'), '');
    final parsed = _parseCsvRow(text, delimiter);
    output.send({
      'type': 'row',
      'id': id,
      'cells': parsed.cells,
      'truncated':
          rowByteLength > maxCsvRowBytes ||
          parsed.isTruncated,
    });
  }
}

({List<String> cells, bool isTruncated}) _parseCsvRow(
  String row,
  String delimiter,
) {
  final cells = <String>[];
  final cell = StringBuffer();
  var inQuotes = false;
  var truncated = false;

  void addCell() {
    if (cells.length < maxSpreadsheetColumns) {
      cells.add(cell.toString());
    } else {
      truncated = true;
    }
    cell.clear();
  }

  for (var index = 0; index < row.length; index++) {
    final character = row[index];
    if (character == '"') {
      if (inQuotes &&
          index + 1 < row.length &&
          row[index + 1] == '"') {
        if (cell.length < maxCsvCellCharacters) {
          cell.write('"');
        } else {
          truncated = true;
        }
        index++;
      } else {
        inQuotes = !inQuotes;
      }
    } else if (!inQuotes && character == delimiter) {
      addCell();
    } else if (cell.length < maxCsvCellCharacters) {
      cell.write(character);
    } else {
      truncated = true;
    }
  }
  addCell();
  return (cells: cells, isTruncated: truncated);
}

CsvTextEncoding _detectEncoding(List<int> header) {
  if (_hasUtf8Bom(header)) return CsvTextEncoding.utf8;
  if (header.length >= 2 && header[0] == 0xff && header[1] == 0xfe) {
    return CsvTextEncoding.utf16LittleEndian;
  }
  if (header.length >= 2 && header[0] == 0xfe && header[1] == 0xff) {
    return CsvTextEncoding.utf16BigEndian;
  }
  try {
    utf8.decode(header, allowMalformed: false);
    return CsvTextEncoding.utf8;
  } on FormatException {
    if (_hasIncompleteUtf8Suffix(header)) return CsvTextEncoding.utf8;
    return CsvTextEncoding.windows1252;
  }
}

bool _hasIncompleteUtf8Suffix(List<int> bytes) {
  for (var start = bytes.length - 1;
      start >= 0 && bytes.length - start <= 3;
      start--) {
    final lead = bytes[start];
    final expectedLength = lead >= 0xc2 && lead <= 0xdf
        ? 2
        : lead >= 0xe0 && lead <= 0xef
        ? 3
        : lead >= 0xf0 && lead <= 0xf4
        ? 4
        : 0;
    if (expectedLength == 0 || bytes.length - start >= expectedLength) {
      continue;
    }
    var validContinuation = true;
    for (var index = start + 1; index < bytes.length; index++) {
      if (bytes[index] < 0x80 || bytes[index] > 0xbf) {
        validContinuation = false;
        break;
      }
    }
    if (validContinuation) return true;
  }
  return false;
}

String _detectDelimiter(List<int> sample, CsvTextEncoding encoding) {
  final text = _decodeCsvBytes(sample, encoding);
  const candidates = [',', ';', '\t', '|'];
  final counts = <String, List<int>>{
    for (final candidate in candidates) candidate: <int>[],
  };
  var inQuotes = false;
  var fieldStart = true;
  var recordCounts = <String, int>{for (final item in candidates) item: 0};
  for (var index = 0; index < text.length; index++) {
    final character = text[index];
    if (character == '"') {
      if (inQuotes && index + 1 < text.length && text[index + 1] == '"') {
        index++;
      } else if (fieldStart || inQuotes) {
        inQuotes = !inQuotes;
        fieldStart = false;
      }
    } else if (!inQuotes &&
        candidates.contains(character)) {
      recordCounts[character] = recordCounts[character]! + 1;
      fieldStart = true;
    } else if (!inQuotes && (character == '\r' || character == '\n')) {
      for (final candidate in candidates) {
        counts[candidate]!.add(recordCounts[candidate]!);
        recordCounts[candidate] = 0;
      }
      fieldStart = true;
    } else if (!inQuotes) {
      fieldStart = false;
    }
  }
  for (final candidate in candidates) {
    if (recordCounts[candidate] != 0) {
      counts[candidate]!.add(recordCounts[candidate]!);
    }
  }
  var selected = ',';
  var selectedConsistentCount = 0;
  var selectedTotal = 0;
  for (final candidate in candidates) {
    final nonzero = counts[candidate]!.where((count) => count > 0).toList();
    if (nonzero.isEmpty) continue;
    final frequencies = <int, int>{};
    for (final count in nonzero) {
      frequencies.update(count, (value) => value + 1, ifAbsent: () => 1);
    }
    final consistentCount = frequencies.values.reduce((a, b) => a > b ? a : b);
    final total = nonzero.fold<int>(0, (sum, count) => sum + count);
    if (consistentCount > selectedConsistentCount ||
        (consistentCount == selectedConsistentCount && total > selectedTotal)) {
      selected = candidate;
      selectedConsistentCount = consistentCount;
      selectedTotal = total;
    }
  }
  return selected;
}

String _decodeCsvBytes(List<int> bytes, CsvTextEncoding encoding) {
  switch (encoding) {
    case CsvTextEncoding.utf8:
      try {
        return utf8.decode(bytes, allowMalformed: false);
      } on FormatException {
        return _decodeWindows1252(bytes);
      }
    case CsvTextEncoding.utf16LittleEndian:
      return _decodeUtf16(bytes, littleEndian: true);
    case CsvTextEncoding.utf16BigEndian:
      return _decodeUtf16(bytes, littleEndian: false);
    case CsvTextEncoding.windows1252:
      return _decodeWindows1252(bytes);
  }
}

String _decodeUtf16(List<int> bytes, {required bool littleEndian}) {
  final codePoints = <int>[];
  for (var index = 0; index + 1 < bytes.length; index += 2) {
    final unit = littleEndian
        ? bytes[index] | (bytes[index + 1] << 8)
        : (bytes[index] << 8) | bytes[index + 1];
    if (unit >= 0xd800 && unit <= 0xdbff) {
      if (index + 3 < bytes.length) {
        final next = littleEndian
            ? bytes[index + 2] | (bytes[index + 3] << 8)
            : (bytes[index + 2] << 8) | bytes[index + 3];
        if (next >= 0xdc00 && next <= 0xdfff) {
          codePoints.add(
            0x10000 + ((unit - 0xd800) << 10) + (next - 0xdc00),
          );
          index += 2;
          continue;
        }
      }
      codePoints.add(0xfffd);
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      codePoints.add(0xfffd);
    } else {
      codePoints.add(unit);
    }
  }
  return String.fromCharCodes(codePoints);
}

String _decodeWindows1252(List<int> bytes) {
  const extended = [
    0x20ac,
    0x81,
    0x201a,
    0x192,
    0x201e,
    0x2026,
    0x2020,
    0x2021,
    0x2c6,
    0x2030,
    0x160,
    0x2039,
    0x152,
    0x8d,
    0x17d,
    0x8f,
    0x90,
    0x2018,
    0x2019,
    0x201c,
    0x201d,
    0x2022,
    0x2013,
    0x2014,
    0x2dc,
    0x2122,
    0x161,
    0x203a,
    0x153,
    0x9d,
    0x17e,
    0x178,
  ];
  final units = bytes.map((byte) {
    if (byte >= 0x80 && byte <= 0x9f) return extended[byte - 0x80];
    return byte;
  }).toList(growable: false);
  return String.fromCharCodes(units);
}

bool _hasUtf8Bom(List<int> bytes) =>
    bytes.length >= 3 &&
    bytes[0] == 0xef &&
    bytes[1] == 0xbb &&
    bytes[2] == 0xbf;

int _readCodeUnit(List<int> bytes, int index, CsvTextEncoding encoding) {
  if (encoding == CsvTextEncoding.utf16LittleEndian) {
    return bytes[index] | (bytes[index + 1] << 8);
  }
  if (encoding == CsvTextEncoding.utf16BigEndian) {
    return (bytes[index] << 8) | bytes[index + 1];
  }
  return bytes[index];
}

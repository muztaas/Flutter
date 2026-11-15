import 'package:flutter/services.dart';

import '../../../domain/repositories/docx_file_repository.dart';

class AndroidDocxFileRepository implements DocxFileRepository {
  static const _channel = MethodChannel('modi_file_explorer2/docx');

  @override
  Future<DocxReadSession> open(String path) async {
    final result = await _channel.invokeMapMethod<String, Object?>(
      'openDocument',
      {'path': path},
    );
    if (result == null || result['id'] is! String) {
      throw const FormatException('The DOCX reader returned no data.');
    }
    return _AndroidDocxReadSession(result['id']! as String);
  }
}

class _AndroidDocxReadSession implements DocxReadSession {
  _AndroidDocxReadSession(this._id);

  static const _channel = MethodChannel('modi_file_explorer2/docx');
  final String _id;
  bool _closed = false;

  @override
  Future<DocxReadProgress> readNextBlocks() async {
    _ensureOpen();
    final result = await _invoke('readNextBlocks');
    final blocks = (result['blocks']! as List)
        .cast<Map<Object?, Object?>>()
        .map(_decodeBlock)
        .toList(growable: false);
    return DocxReadProgress(
      blocks: blocks,
      startIndex: result['startIndex']! as int,
      blockCount: result['blockCount']! as int,
      isComplete: result['complete']! as bool,
      isTruncated: result['truncated']! as bool,
      notShownFeatures: (result['notShown'] as List? ?? const [])
          .cast<String>()
          .toList(growable: false),
      sectionPageWidth: (result['pageWidth'] as num?)?.toDouble(),
      sectionPageHeight: (result['pageHeight'] as num?)?.toDouble(),
      sectionMarginLeft: (result['marginLeft'] as num?)?.toDouble(),
      sectionMarginRight: (result['marginRight'] as num?)?.toDouble(),
      sectionMarginTop: (result['marginTop'] as num?)?.toDouble(),
      sectionMarginBottom: (result['marginBottom'] as num?)?.toDouble(),
    );
  }

  DocxBlock _decodeBlock(Map<Object?, Object?> block) => DocxBlock(
    type: block['type']! as String,
    runs: _decodeRuns(block['runs']),
    tableRows: (block['rows'] as List? ?? const [])
        .cast<List>()
        .map(
          (row) => row
              .cast<List>()
              .map((cell) => _decodeRuns(cell))
              .toList(growable: false),
        )
        .toList(growable: false),
    tableId: block['tableId'] as int?,
    tableColumnWidths: (block['columnWidths'] as List? ?? const [])
        .whereType<num>()
        .map((width) => width.toDouble())
        .toList(growable: false),
    tableCellSpans: (block['cellSpans'] as List? ?? const [])
        .whereType<num>()
        .map((span) => span.toInt())
        .toList(growable: false),
    styleName: block['styleName'] as String?,
    styleBold: block['styleBold'] as bool? ?? false,
    styleItalic: block['styleItalic'] as bool? ?? false,
    styleUnderline: block['styleUnderline'] as bool? ?? false,
    styleStrikethrough: block['styleStrike'] as bool? ?? false,
    styleFontSize: (block['styleFontSize'] as num?)?.toDouble(),
    styleFontFamily: block['styleFontFamily'] as String?,
    styleColor: block['styleColor'] as int?,
    styleHighlight: block['styleHighlight'] as int?,
    headingLevel: block['headingLevel'] as int?,
    alignment: block['alignment'] as String?,
    isRightToLeft: block['rtl'] as bool? ?? false,
    listMarker: block['listMarker'] as String?,
    listLevel: block['listLevel'] as int? ?? 0,
    imagePath: block['imagePath'] as String?,
    chartData: block['chartData'] is Map
        ? Map<Object?, Object?>.from(block['chartData']! as Map)
        : null,
    imageWidth: (block['width'] as num?)?.toDouble(),
    imageHeight: (block['height'] as num?)?.toDouble(),
    imageCropLeft: (block['cropLeft'] as num?)?.toDouble() ?? 0,
    imageCropTop: (block['cropTop'] as num?)?.toDouble() ?? 0,
    imageCropRight: (block['cropRight'] as num?)?.toDouble() ?? 0,
    imageCropBottom: (block['cropBottom'] as num?)?.toDouble() ?? 0,
    pageBreakBefore: block['pageBreakBefore'] as bool? ?? false,
    placeholder: block['placeholder'] as String?,
    floatingLeft: (block['floatingLeft'] as num?)?.toDouble(),
    floatingTop: (block['floatingTop'] as num?)?.toDouble(),
    floatingWidth: (block['floatingWidth'] as num?)?.toDouble(),
    floatingHeight: (block['floatingHeight'] as num?)?.toDouble(),
    floatingId: block['floatingId'] as int?,
    floatingBackground: block['floatingBackground'] as int?,
    floatingShape: block['floatingShape'] as String?,
    floatingOutlineColor: block['floatingOutlineColor'] as int?,
    floatingOutlineWidth: (block['floatingOutlineWidth'] as num?)?.toDouble(),
    floatingRotation: (block['floatingRotation'] as num?)?.toDouble(),
    paragraphSpaceBefore: (block['spaceBefore'] as num?)?.toDouble(),
    paragraphSpaceAfter: (block['spaceAfter'] as num?)?.toDouble(),
    paragraphLineHeight: (block['lineHeight'] as num?)?.toDouble(),
    paragraphIndentLeft: (block['indentLeft'] as num?)?.toDouble(),
    paragraphIndentRight: (block['indentRight'] as num?)?.toDouble(),
    paragraphHangingIndent: (block['hangingIndent'] as num?)?.toDouble(),
    paragraphFirstLineIndent: (block['firstLineIndent'] as num?)?.toDouble(),
    paragraphBackground: block['paragraphBackground'] as int?,
    paragraphBottomBorderColor: block['bottomBorderColor'] as int?,
    paragraphBottomBorderWidth: (block['bottomBorderWidth'] as num?)
        ?.toDouble(),
    tableCellBackgrounds:
        (block['cellBackgrounds'] as List? ?? const [])
            .map((value) => value as int?)
            .toList(growable: false),
    tableCellVerticalMerges:
        (block['cellVerticalMerges'] as List? ?? const [])
            .map((value) => value as String?)
            .toList(growable: false),
    tableCellBorders: (block['cellBorders'] as List? ?? const [])
        .map((value) => value as int?)
        .toList(growable: false),
    tableRowBackground: block['rowBackground'] as int?,
    sectionPageWidth: (block['pageWidth'] as num?)?.toDouble(),
    sectionPageHeight: (block['pageHeight'] as num?)?.toDouble(),
    sectionMarginLeft: (block['marginLeft'] as num?)?.toDouble(),
    sectionMarginRight: (block['marginRight'] as num?)?.toDouble(),
    sectionMarginTop: (block['marginTop'] as num?)?.toDouble(),
    sectionMarginBottom: (block['marginBottom'] as num?)?.toDouble(),
  );

  List<DocxTextRun> _decodeRuns(Object? value) => (value as List? ?? const [])
      .cast<Map<Object?, Object?>>()
      .map(
        (run) => DocxTextRun(
          text:
              run['text'] as String? ??
              (run['type'] == 'placeholder' ? 'Object not shown' : ''),
          bold: run['bold'] as bool? ?? false,
          italic: run['italic'] as bool? ?? false,
          underline: run['underline'] as bool? ?? false,
          strikethrough: run['strike'] as bool? ?? false,
          fontSize: (run['fontSize'] as num?)?.toDouble(),
          fontFamily: run['fontFamily'] as String?,
          color: run['color'] as int?,
          highlight: run['highlight'] as int?,
          hyperlink: run['hyperlink'] as String?,
          imagePath: run['imagePath'] as String?,
          imageWidth: (run['width'] as num?)?.toDouble(),
          imageHeight: (run['height'] as num?)?.toDouble(),
          imageCropLeft: (run['cropLeft'] as num?)?.toDouble() ?? 0,
          imageCropTop: (run['cropTop'] as num?)?.toDouble() ?? 0,
          imageCropRight: (run['cropRight'] as num?)?.toDouble() ?? 0,
          imageCropBottom: (run['cropBottom'] as num?)?.toDouble() ?? 0,
        ),
      )
      .toList(growable: false);

  Future<Map<String, Object?>> _invoke(
    String method, [
    Map<String, Object?> arguments = const {},
  ]) async {
    final result = await _channel.invokeMapMethod<String, Object?>(method, {
      'id': _id,
      ...arguments,
    });
    if (result == null) {
      throw const FormatException('The DOCX reader returned no data.');
    }
    return result;
  }

  @override
  Future<Uint8List> readImage(String path) async {
    _ensureOpen();
    final bytes = await _channel.invokeMethod<Uint8List>('readImage', {
      'id': _id,
      'path': path,
    });
    if (bytes == null || bytes.isEmpty) {
      throw const FormatException('The embedded image could not be read.');
    }
    return bytes;
  }

  @override
  Future<void> openExternalLink(String uri) async {
    _ensureOpen();
    await _channel.invokeMethod<void>('openExternalLink', {
      'id': _id,
      'uri': uri,
    });
  }

  void _ensureOpen() {
    if (_closed) throw StateError('The DOCX document is closed');
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _channel.invokeMethod<void>('closeDocument', {'id': _id});
  }
}

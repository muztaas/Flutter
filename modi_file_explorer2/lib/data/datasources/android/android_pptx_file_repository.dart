import 'package:flutter/services.dart';

import '../../../domain/repositories/pptx_file_repository.dart';

class AndroidPptxFileRepository implements PptxFileRepository {
  static const _channel = MethodChannel('modi_file_explorer2/pptx');

  @override
  Future<PptxReadSession> open(String path) async {
    final result = await _channel.invokeMapMethod<String, Object?>(
      'openPresentation',
      {'path': path},
    );
    if (result == null || result['id'] is! String) {
      throw const FormatException('The PPTX reader returned no presentation.');
    }
    return _AndroidPptxReadSession(
      _channel,
      result['id']! as String,
      PptxDeckInfo(
        id: result['id']! as String,
        width: (result['width']! as num).toDouble(),
        height: (result['height']! as num).toDouble(),
        slideCount: result['slideCount']! as int,
        embeddedFontFamilies:
            (result['embeddedFontFamilies'] as List? ?? const [])
                .cast<String>(),
      ),
    );
  }
}

class _AndroidPptxReadSession implements PptxReadSession {
  _AndroidPptxReadSession(this._channel, this._id, this.deckInfo);

  final MethodChannel _channel;
  final String _id;

  @override
  final PptxDeckInfo deckInfo;

  bool _closed = false;

  Future<Map<String, Object?>> _invoke(
    String method, [
    Map<String, Object?> arguments = const {},
  ]) async {
    _ensureOpen();
    final result = await _channel.invokeMapMethod<String, Object?>(method, {
      'id': _id,
      ...arguments,
    });
    if (result == null) {
      throw const FormatException('The PPTX reader returned no data.');
    }
    return result;
  }

  @override
  Future<PptxSlide> readSlide(int index) async {
    final result = await _invoke('readSlide', {'index': index});
    return PptxSlide(
      index: result['index']! as int,
      backgroundColor: result['backgroundColor'] as int?,
      notShownFeatures: (result['notShown'] as List? ?? const [])
          .cast<String>()
          .toList(growable: false),
      backgroundGradientColors:
          (result['backgroundGradientColors'] as List? ?? const [])
              .cast<int>()
              .toList(growable: false),
      backgroundGradientStops:
          (result['backgroundGradientStops'] as List? ?? const [])
              .cast<num>()
              .map((stop) => stop.toDouble())
              .toList(growable: false),
      backgroundGradientAngle:
          (result['backgroundGradientAngle'] as num?)?.toDouble() ?? 0,
      backgroundImagePath: result['backgroundImagePath'] as String?,
      elements: (result['elements']! as List)
          .cast<Map<Object?, Object?>>()
          .map(_decodeElement)
          .toList(growable: false),
    );
  }

  PptxElement _decodeElement(Map<Object?, Object?> element) => PptxElement(
    type: element['type']! as String,
    x: (element['x']! as num).toDouble(),
    y: (element['y']! as num).toDouble(),
    width: (element['width']! as num).toDouble(),
    height: (element['height']! as num).toDouble(),
    shape: element['shape'] as String? ?? 'rect',
    fillColor: element['fillColor'] as int?,
    lineColor: element['lineColor'] as int?,
    lineWidth: (element['lineWidth'] as num?)?.toDouble() ?? 1,
    rotationDegrees: (element['rotationDegrees'] as num?)?.toDouble() ?? 0,
    textVerticalAlignment: element['textVerticalAlignment'] as String? ?? 'top',
    textInsetLeft: (element['textInsetLeft'] as num?)?.toDouble() ?? 0,
    textInsetTop: (element['textInsetTop'] as num?)?.toDouble() ?? 0,
    textInsetRight: (element['textInsetRight'] as num?)?.toDouble() ?? 0,
    textInsetBottom: (element['textInsetBottom'] as num?)?.toDouble() ?? 0,
    imagePath: element['imagePath'] as String?,
    chartData: element['chartData'] is Map
        ? Map<Object?, Object?>.from(element['chartData']! as Map)
        : null,
    tableRows: (element['tableRows'] as List? ?? const [])
        .cast<List>()
        .map((row) => row.cast<String>().toList(growable: false))
        .toList(growable: false),
    customPaths: (element['customPaths'] as List? ?? const [])
        .cast<Map<Object?, Object?>>()
        .map(
          (customPath) => PptxCustomPath(
            fill: customPath['fill'] as bool? ?? true,
            stroke: customPath['stroke'] as bool? ?? true,
            commands: (customPath['commands'] as List? ?? const [])
                .cast<Map<Object?, Object?>>()
                .map(
                  (command) => PptxPathCommand(
                    type: command['type']! as String,
                    points: (command['points'] as List? ?? const [])
                        .cast<List>()
                        .map(
                          (point) => point
                              .cast<num>()
                              .map((coordinate) => coordinate.toDouble())
                              .toList(growable: false),
                        )
                        .toList(growable: false),
                  ),
                )
                .toList(growable: false),
          ),
        )
        .toList(growable: false),
    flipHorizontal: element['flipHorizontal'] as bool? ?? false,
    flipVertical: element['flipVertical'] as bool? ?? false,
    imageCropLeft: (element['imageCropLeft'] as num?)?.toDouble() ?? 0,
    imageCropTop: (element['imageCropTop'] as num?)?.toDouble() ?? 0,
    imageCropRight: (element['imageCropRight'] as num?)?.toDouble() ?? 0,
    imageCropBottom: (element['imageCropBottom'] as num?)?.toDouble() ?? 0,
    placeholderType: element['placeholderType'] as String?,
    placeholderIndex: element['placeholderIndex'] as int?,
    hasTransform: element['hasTransform'] as bool? ?? true,
    textScale: (element['textScale'] as num?)?.toDouble() ?? 1,
    fillGradientColors: (element['fillGradientColors'] as List? ?? const [])
        .cast<int>()
        .toList(growable: false),
    fillGradientStops: (element['fillGradientStops'] as List? ?? const [])
        .cast<num>()
        .map((stop) => stop.toDouble())
        .toList(growable: false),
    fillGradientAngle: (element['fillGradientAngle'] as num?)?.toDouble() ?? 0,
    paragraphs: (element['paragraphs'] as List? ?? const [])
        .cast<Map<Object?, Object?>>()
        .map(
          (paragraph) => PptxTextParagraph(
            alignment: paragraph['alignment'] as String? ?? 'left',
            bullet: paragraph['bullet'] as String?,
            fontSize: (paragraph['fontSize'] as num?)?.toDouble(),
            color: paragraph['color'] as int?,
            level: paragraph['level'] as int? ?? 0,
            indent: (paragraph['indent'] as num?)?.toDouble() ?? 0,
            spaceBefore: (paragraph['spaceBefore'] as num?)?.toDouble(),
            spaceAfter: (paragraph['spaceAfter'] as num?)?.toDouble(),
            lineSpacing: (paragraph['lineSpacing'] as num?)?.toDouble(),
            runs: (paragraph['runs'] as List? ?? const [])
                .cast<Map<Object?, Object?>>()
                .map(
                  (run) => PptxTextRun(
                    text: run['text'] as String? ?? '',
                    bold: run['bold'] as bool? ?? false,
                    italic: run['italic'] as bool? ?? false,
                    underline: run['underline'] as bool? ?? false,
                    strikethrough: run['strikethrough'] as bool? ?? false,
                    fontSize: (run['fontSize'] as num?)?.toDouble(),
                    color: run['color'] as int?,
                    fontFamily: run['fontFamily'] is String
                        ? _fontFamily(run['fontFamily']! as String)
                        : null,
                    superscript: run['superscript'] as bool? ?? false,
                    subscript: run['subscript'] as bool? ?? false,
                    hyperlink: run['hyperlink'] as String?,
                  ),
                )
                .toList(growable: false),
          ),
        )
        .toList(growable: false),
  );

  String _fontFamily(String family) =>
      deckInfo.embeddedFontFamilies.contains(family) ? '$_id::$family' : family;

  @override
  Future<Uint8List> readImage(String path) async {
    _ensureOpen();
    final bytes = await _channel.invokeMethod<Uint8List>('readImage', {
      'id': _id,
      'path': path,
    });
    if (bytes == null || bytes.isEmpty) {
      throw const FormatException('The slide image could not be read.');
    }
    return bytes;
  }

  @override
  Future<Uint8List> readFont(String family) async {
    _ensureOpen();
    final bytes = await _channel.invokeMethod<Uint8List>('readFont', {
      'id': _id,
      'family': family,
    });
    if (bytes == null || bytes.isEmpty) {
      throw const FormatException(
        'The embedded presentation font is unavailable.',
      );
    }
    return bytes;
  }

  void _ensureOpen() {
    if (_closed) throw StateError('The PPTX presentation is closed');
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _channel.invokeMethod<void>('closePresentation', {'id': _id});
  }
}

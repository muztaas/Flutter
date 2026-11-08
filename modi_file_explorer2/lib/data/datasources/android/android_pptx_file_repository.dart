import 'dart:typed_data';

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
    imagePath: element['imagePath'] as String?,
    tableRows: (element['tableRows'] as List? ?? const [])
        .cast<List>()
        .map((row) => row.cast<String>().toList(growable: false))
        .toList(growable: false),
    paragraphs: (element['paragraphs'] as List? ?? const [])
        .cast<Map<Object?, Object?>>()
        .map(
          (paragraph) => PptxTextParagraph(
            alignment: paragraph['alignment'] as String? ?? 'left',
            bullet: paragraph['bullet'] as String?,
            fontSize: (paragraph['fontSize'] as num?)?.toDouble(),
            color: paragraph['color'] as int?,
            runs: (paragraph['runs'] as List? ?? const [])
                .cast<Map<Object?, Object?>>()
                .map(
                  (run) => PptxTextRun(
                    text: run['text'] as String? ?? '',
                    bold: run['bold'] as bool? ?? false,
                    italic: run['italic'] as bool? ?? false,
                    underline: run['underline'] as bool? ?? false,
                    fontSize: (run['fontSize'] as num?)?.toDouble(),
                    color: run['color'] as int?,
                  ),
                )
                .toList(growable: false),
          ),
        )
        .toList(growable: false),
  );

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

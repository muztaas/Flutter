import 'dart:typed_data';

class PptxDeckInfo {
  const PptxDeckInfo({
    required this.id,
    required this.width,
    required this.height,
    required this.slideCount,
  });

  final String id;
  final double width;
  final double height;
  final int slideCount;
}

class PptxTextRun {
  const PptxTextRun({
    required this.text,
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.fontSize,
    this.color,
  });

  final String text;
  final bool bold;
  final bool italic;
  final bool underline;
  final double? fontSize;
  final int? color;
}

class PptxTextParagraph {
  const PptxTextParagraph({
    required this.runs,
    this.alignment = 'left',
    this.bullet,
    this.fontSize,
    this.color,
  });

  final List<PptxTextRun> runs;
  final String alignment;
  final String? bullet;
  final double? fontSize;
  final int? color;
}

class PptxElement {
  const PptxElement({
    required this.type,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    this.shape = 'rect',
    this.fillColor,
    this.lineColor,
    this.lineWidth = 1,
    this.paragraphs = const [],
    this.tableRows = const [],
    this.imagePath,
  });

  final String type;
  final double x;
  final double y;
  final double width;
  final double height;
  final String shape;
  final int? fillColor;
  final int? lineColor;
  final double lineWidth;
  final List<PptxTextParagraph> paragraphs;
  final List<List<String>> tableRows;
  final String? imagePath;
}

class PptxSlide {
  const PptxSlide({
    required this.index,
    required this.backgroundColor,
    required this.elements,
  });

  final int index;
  final int? backgroundColor;
  final List<PptxElement> elements;
}

abstract interface class PptxFileRepository {
  Future<PptxReadSession> open(String path);
}

abstract interface class PptxReadSession {
  PptxDeckInfo get deckInfo;
  Future<PptxSlide> readSlide(int index);
  Future<Uint8List> readImage(String path);
  Future<void> close();
}

import 'dart:typed_data';

class DocxTextRun {
  const DocxTextRun({
    required this.text,
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strikethrough = false,
    this.fontSize,
    this.color,
    this.highlight,
    this.hyperlink,
    this.imagePath,
    this.imageWidth,
    this.imageHeight,
  });

  final String text;
  final bool bold;
  final bool italic;
  final bool underline;
  final bool strikethrough;
  final double? fontSize;
  final int? color;
  final int? highlight;
  final String? hyperlink;
  final String? imagePath;
  final double? imageWidth;
  final double? imageHeight;
}

class DocxBlock {
  const DocxBlock({
    required this.type,
    this.runs = const [],
    this.tableRows = const [],
    this.tableId,
    this.tableColumnWidths = const [],
    this.tableCellSpans = const [],
    this.styleName,
    this.styleBold = false,
    this.styleItalic = false,
    this.styleUnderline = false,
    this.styleStrikethrough = false,
    this.styleFontSize,
    this.styleColor,
    this.styleHighlight,
    this.headingLevel,
    this.alignment,
    this.isRightToLeft = false,
    this.listMarker,
    this.listLevel = 0,
    this.imagePath,
    this.imageWidth,
    this.imageHeight,
    this.pageBreakBefore = false,
    this.placeholder,
    this.floatingLeft,
    this.floatingTop,
    this.floatingWidth,
    this.floatingHeight,
    this.floatingId,
    this.floatingBackground,
    this.floatingShape,
    this.floatingOutlineColor,
    this.floatingOutlineWidth,
    this.floatingRotation,
    this.paragraphSpaceBefore,
    this.paragraphSpaceAfter,
    this.paragraphLineHeight,
    this.paragraphIndentLeft,
    this.paragraphIndentRight,
    this.paragraphHangingIndent,
    this.paragraphBottomBorderColor,
    this.paragraphBottomBorderWidth,
  });

  final String type;
  final List<DocxTextRun> runs;
  final List<List<List<DocxTextRun>>> tableRows;
  final int? tableId;
  final List<double> tableColumnWidths;
  final List<int> tableCellSpans;
  final String? styleName;
  final bool styleBold;
  final bool styleItalic;
  final bool styleUnderline;
  final bool styleStrikethrough;
  final double? styleFontSize;
  final int? styleColor;
  final int? styleHighlight;
  final int? headingLevel;
  final String? alignment;
  final bool isRightToLeft;
  final String? listMarker;
  final int listLevel;
  final String? imagePath;
  final double? imageWidth;
  final double? imageHeight;
  final bool pageBreakBefore;
  final String? placeholder;
  final double? floatingLeft;
  final double? floatingTop;
  final double? floatingWidth;
  final double? floatingHeight;
  final int? floatingId;
  final int? floatingBackground;
  final String? floatingShape;
  final int? floatingOutlineColor;
  final double? floatingOutlineWidth;
  final double? floatingRotation;
  final double? paragraphSpaceBefore;
  final double? paragraphSpaceAfter;
  final double? paragraphLineHeight;
  final double? paragraphIndentLeft;
  final double? paragraphIndentRight;
  final double? paragraphHangingIndent;
  final int? paragraphBottomBorderColor;
  final double? paragraphBottomBorderWidth;
}

class DocxReadProgress {
  const DocxReadProgress({
    required this.blocks,
    required this.startIndex,
    required this.blockCount,
    required this.isComplete,
    required this.isTruncated,
  });

  final List<DocxBlock> blocks;
  final int startIndex;
  final int blockCount;
  final bool isComplete;
  final bool isTruncated;
}

abstract interface class DocxFileRepository {
  Future<DocxReadSession> open(String path);
}

abstract interface class DocxReadSession {
  Future<DocxReadProgress> readNextBlocks();
  Future<Uint8List> readImage(String path);
  Future<void> openExternalLink(String uri);
  Future<void> close();
}

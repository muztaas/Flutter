import 'dart:typed_data';

class PptxDeckInfo {
  const PptxDeckInfo({
    required this.id,
    required this.width,
    required this.height,
    required this.slideCount,
    this.embeddedFontFamilies = const [],
  });

  final String id;
  final double width;
  final double height;
  final int slideCount;
  final List<String> embeddedFontFamilies;
}

class PptxTextRun {
  const PptxTextRun({
    required this.text,
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strikethrough = false,
    this.fontSize,
    this.color,
    this.level = 0,
    this.indent = 0,
    this.spaceBefore,
    this.spaceAfter,
    this.lineSpacing,
    this.fontFamily,
    this.superscript = false,
    this.subscript = false,
    this.hyperlink,
  });

  final String text;
  final bool bold;
  final bool italic;
  final bool underline;
  final bool strikethrough;
  final double? fontSize;
  final int? color;
  final int level;
  final double indent;
  final double? spaceBefore;
  final double? spaceAfter;
  final double? lineSpacing;
  final String? fontFamily;
  final bool superscript;
  final bool subscript;
  final String? hyperlink;
}

class PptxTextParagraph {
  const PptxTextParagraph({
    required this.runs,
    this.alignment = 'left',
    this.bullet,
    this.fontSize,
    this.color,
    this.level = 0,
    this.indent = 0,
    this.spaceBefore,
    this.spaceAfter,
    this.lineSpacing,
  });

  final List<PptxTextRun> runs;
  final String alignment;
  final String? bullet;
  final double? fontSize;
  final int? color;
  final int level;
  final double indent;
  final double? spaceBefore;
  final double? spaceAfter;
  final double? lineSpacing;
}

class PptxPathCommand {
  const PptxPathCommand({required this.type, required this.points});

  final String type;
  final List<List<double>> points;
}

class PptxCustomPath {
  const PptxCustomPath({
    required this.commands,
    this.fill = true,
    this.stroke = true,
  });

  final List<PptxPathCommand> commands;
  final bool fill;
  final bool stroke;
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
    this.rotationDegrees = 0,
    this.textVerticalAlignment = 'top',
    this.textInsetLeft = 0,
    this.textInsetTop = 0,
    this.textInsetRight = 0,
    this.textInsetBottom = 0,
    this.paragraphs = const [],
    this.tableRows = const [],
    this.imagePath,
    this.chartData,
    this.customPaths = const [],
    this.flipHorizontal = false,
    this.flipVertical = false,
    this.imageCropLeft = 0,
    this.imageCropTop = 0,
    this.imageCropRight = 0,
    this.imageCropBottom = 0,
    this.fillGradientColors = const [],
    this.fillGradientStops = const [],
    this.fillGradientAngle = 0,
    this.placeholderType,
    this.placeholderIndex,
    this.hasTransform = true,
    this.textScale = 1,
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
  final double rotationDegrees;
  final String textVerticalAlignment;
  final double textInsetLeft;
  final double textInsetTop;
  final double textInsetRight;
  final double textInsetBottom;
  final List<PptxTextParagraph> paragraphs;
  final List<List<String>> tableRows;
  final String? imagePath;
  final Map<Object?, Object?>? chartData;
  final List<PptxCustomPath> customPaths;
  final bool flipHorizontal;
  final bool flipVertical;
  final double imageCropLeft;
  final double imageCropTop;
  final double imageCropRight;
  final double imageCropBottom;
  final List<int> fillGradientColors;
  final List<double> fillGradientStops;
  final double fillGradientAngle;
  final String? placeholderType;
  final int? placeholderIndex;
  final bool hasTransform;
  final double textScale;
}

class PptxSlide {
  const PptxSlide({
    required this.index,
    required this.backgroundColor,
    required this.elements,
    this.notShownFeatures = const [],
    this.backgroundGradientColors = const [],
    this.backgroundGradientStops = const [],
    this.backgroundGradientAngle = 0,
    this.backgroundImagePath,
  });

  final int index;
  final int? backgroundColor;
  final List<PptxElement> elements;
  final List<String> notShownFeatures;
  final List<int> backgroundGradientColors;
  final List<double> backgroundGradientStops;
  final double backgroundGradientAngle;
  final String? backgroundImagePath;
}

abstract interface class PptxFileRepository {
  Future<PptxReadSession> open(String path);
}

abstract interface class PptxReadSession {
  PptxDeckInfo get deckInfo;
  Future<PptxSlide> readSlide(int index);
  Future<Uint8List> readImage(String path);
  Future<Uint8List> readFont(String family);
  Future<void> close();
}

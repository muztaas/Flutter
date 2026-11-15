import 'dart:typed_data';

class PdfDocumentInfo {
  const PdfDocumentInfo({
    required this.documentId,
    required this.pageCount,
    required this.firstPageWidth,
    required this.firstPageHeight,
  });

  final String documentId;
  final int pageCount;
  final int firstPageWidth;
  final int firstPageHeight;
}

class PdfPageInfo {
  const PdfPageInfo({required this.width, required this.height});

  final int width;
  final int height;

  double get aspectRatio => width / height;
}

class PdfRenderedPage {
  const PdfRenderedPage({
    required this.bytes,
    required this.pageInfo,
    required this.imageWidth,
    required this.imageHeight,
    required this.x,
    required this.y,
    required this.fullWidth,
    required this.fullHeight,
  });

  final Uint8List bytes;
  final PdfPageInfo pageInfo;
  final int imageWidth;
  final int imageHeight;
  final int x;
  final int y;
  final int fullWidth;
  final int fullHeight;
}

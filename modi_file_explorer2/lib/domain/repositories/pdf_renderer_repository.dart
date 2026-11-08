import '../entities/pdf_document_info.dart';

abstract class PdfRendererRepository {
  Future<PdfDocumentInfo> openDocument(String path, {String? password});

  Future<PdfPageInfo> getPageInfo(String documentId, int pageIndex);

  Future<List<int>> searchText(String documentId, String query);

  Future<PdfRenderedPage> renderPage({
    required String documentId,
    required int pageIndex,
    required int width,
    required int height,
    required String requestId,
  });

  Future<void> cancelRender(String requestId);

  Future<void> closeDocument(String documentId);
}

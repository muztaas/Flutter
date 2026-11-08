import 'package:flutter/services.dart';

import '../../../domain/entities/pdf_document_info.dart';
import '../../../domain/repositories/pdf_renderer_repository.dart';

class AndroidPdfRendererRepository implements PdfRendererRepository {
  static const _channel = MethodChannel('modi_file_explorer2/pdf_renderer');

  @override
  Future<PdfDocumentInfo> openDocument(String path, {String? password}) async {
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'openDocument',
      {'path': path, 'password': password},
    );
    if (result == null) {
      throw const FormatException('PDF renderer returned no document details');
    }
    return PdfDocumentInfo(
      documentId: _requiredString(result, 'documentId'),
      pageCount: _requiredInt(result, 'pageCount'),
      firstPageWidth: _requiredInt(result, 'firstPageWidth'),
      firstPageHeight: _requiredInt(result, 'firstPageHeight'),
    );
  }

  @override
  Future<PdfPageInfo> getPageInfo(String documentId, int pageIndex) async {
    final result = await _channel.invokeMapMethod<String, dynamic>('pageInfo', {
      'documentId': documentId,
      'pageIndex': pageIndex,
    });
    if (result == null) {
      throw const FormatException('PDF renderer returned no page dimensions');
    }
    return PdfPageInfo(
      width: _requiredInt(result, 'pageWidth'),
      height: _requiredInt(result, 'pageHeight'),
    );
  }

  @override
  Future<List<int>> searchText(String documentId, String query) async {
    final result = await _channel.invokeListMethod<int>('searchText', {
      'documentId': documentId,
      'query': query,
    });
    if (result == null) {
      throw const FormatException('PDF renderer returned no search results');
    }
    return result;
  }

  @override
  Future<PdfRenderedPage> renderPage({
    required String documentId,
    required int pageIndex,
    required int width,
    required int height,
    required String requestId,
  }) async {
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'renderPage',
      {
        'documentId': documentId,
        'pageIndex': pageIndex,
        'width': width,
        'height': height,
        'requestId': requestId,
      },
    );
    if (result == null || result['bytes'] is! Uint8List) {
      throw const FormatException('PDF renderer returned no page bitmap');
    }
    return PdfRenderedPage(
      bytes: result['bytes'] as Uint8List,
      pageInfo: PdfPageInfo(
        width: _requiredInt(result, 'pageWidth'),
        height: _requiredInt(result, 'pageHeight'),
      ),
    );
  }

  @override
  Future<void> cancelRender(String requestId) async {
    await _channel.invokeMethod<void>('cancelRender', {'requestId': requestId});
  }

  @override
  Future<void> closeDocument(String documentId) async {
    await _channel.invokeMethod<void>('closeDocument', {
      'documentId': documentId,
    });
  }

  String _requiredString(Map<String, dynamic> values, String key) {
    final value = values[key];
    if (value is! String || value.isEmpty) {
      throw FormatException('PDF renderer returned invalid $key');
    }
    return value;
  }

  int _requiredInt(Map<String, dynamic> values, String key) {
    final value = values[key];
    if (value is! int || value <= 0) {
      throw FormatException('PDF renderer returned invalid $key');
    }
    return value;
  }
}

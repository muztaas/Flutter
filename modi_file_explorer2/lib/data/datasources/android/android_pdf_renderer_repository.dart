import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../../domain/entities/pdf_document_info.dart';
import '../../../domain/repositories/pdf_renderer_repository.dart';

class AndroidPdfRendererRepository implements PdfRendererRepository {
  static Future<void>? _initialization;
  static int _nextDocumentId = 0;

  final Map<String, _PdfDocumentHandle> _documents = {};

  Future<void> _ensureInitialized() async {
    final existing = _initialization;
    if (existing != null) {
      await existing;
      return;
    }

    final initialization = pdfrxFlutterInitialize();
    _initialization = initialization;
    try {
      await initialization;
    } catch (_) {
      _initialization = null;
      rethrow;
    }
  }

  @override
  Future<PdfDocumentInfo> openDocument(String path, {String? password}) async {
    await _ensureInitialized();
    PdfDocument? document;
    try {
      document = await PdfDocument.openFile(
        path,
        passwordProvider: () => password,
        firstAttemptByEmptyPassword: password == null,
        useProgressiveLoading: true,
      );
      if (document.pages.isEmpty) {
        throw PlatformException(
          code: 'EMPTY_PDF',
          message: 'This PDF contains no pages.',
        );
      }

      final firstPage = await document.pages.first.ensureLoaded();
      final firstPageWidth = firstPage.width.round();
      final firstPageHeight = firstPage.height.round();
      if (firstPageWidth <= 0 || firstPageHeight <= 0) {
        throw PlatformException(
          code: 'INVALID_PDF',
          message: 'The first PDF page has invalid dimensions.',
        );
      }

      final documentId =
          '${DateTime.now().microsecondsSinceEpoch}-${_nextDocumentId++}';
      _documents[documentId] = _PdfDocumentHandle(document);
      return PdfDocumentInfo(
        documentId: documentId,
        pageCount: document.pages.length,
        firstPageWidth: firstPageWidth,
        firstPageHeight: firstPageHeight,
      );
    } catch (error, stackTrace) {
      await document?.dispose();
      Error.throwWithStackTrace(
        _asPlatformException(error, password),
        stackTrace,
      );
    }
  }

  @override
  Future<PdfPageInfo> getPageInfo(String documentId, int pageIndex) async {
    final handle = _document(documentId);
    handle.beginOperation();
    try {
      final page = await _pageAt(handle.document, pageIndex);
      return _pageInfo(page);
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(_asPlatformException(error), stackTrace);
    } finally {
      handle.endOperation();
    }
  }

  @override
  Future<List<int>> searchText(String documentId, String query) async {
    final handle = _document(documentId);
    if (query.length > 256) {
      throw PlatformException(
        code: 'INVALID_ARGUMENT',
        message: 'Search text must be at most 256 characters.',
      );
    }
    handle.beginOperation();
    try {
      final normalizedQuery = query.toLowerCase();
      if (normalizedQuery.isEmpty) return const [];

      final matches = <int>[];
      for (var index = 0; index < handle.document.pages.length; index++) {
        final page = await _pageAt(handle.document, index);
        final text = await page.loadText();
        if (text?.fullText.toLowerCase().contains(normalizedQuery) ?? false) {
          matches.add(index);
        }
      }
      return matches;
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(_asPlatformException(error), stackTrace);
    } finally {
      handle.endOperation();
    }
  }

  @override
  Future<PdfRenderedPage> renderPage({
    required String documentId,
    required int pageIndex,
    required int fullWidth,
    required int fullHeight,
    required int x,
    required int y,
    required int width,
    required int height,
    required String requestId,
  }) async {
    final handle = _document(documentId);
    if (fullWidth <= 0 ||
        fullHeight <= 0 ||
        x < 0 ||
        y < 0 ||
        width <= 0 ||
        height <= 0 ||
        x >= fullWidth ||
        y >= fullHeight ||
        width > fullWidth - x ||
        height > fullHeight - y) {
      throw PlatformException(
        code: 'INVALID_ARGUMENT',
        message: 'The requested PDF render tile is outside the page bounds.',
      );
    }
    if (handle.requests.containsKey(requestId)) {
      throw PlatformException(
        code: 'INVALID_ARGUMENT',
        message: 'A PDF render request with this id is already active.',
      );
    }

    final request = _PdfRenderRequest();
    handle.beginOperation();
    handle.requests[requestId] = request;
    try {
      final page = await _pageAt(handle.document, pageIndex);
      if (request.cancelled) {
        throw PlatformException(
          code: 'RENDER_CANCELLED',
          message: 'PDF render request was cancelled.',
        );
      }

      final token = page.createCancellationToken();
      request.token = token;
      if (request.cancelled) token.cancel();

      final rendered = await page.render(
        x: x,
        y: y,
        width: width,
        height: height,
        fullWidth: fullWidth.toDouble(),
        fullHeight: fullHeight.toDouble(),
        cancellationToken: token,
      );
      if (rendered == null) {
        throw PlatformException(
          code: request.cancelled ? 'RENDER_CANCELLED' : 'PDF_RENDER_FAILED',
          message: request.cancelled
              ? 'PDF render request was cancelled.'
              : 'PDFium could not render this page tile.',
        );
      }

      try {
        return PdfRenderedPage(
          bytes: Uint8List.fromList(rendered.pixels),
          pageInfo: _pageInfo(page),
          imageWidth: rendered.width,
          imageHeight: rendered.height,
          x: x,
          y: y,
          fullWidth: fullWidth,
          fullHeight: fullHeight,
        );
      } finally {
        rendered.dispose();
      }
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(_asPlatformException(error), stackTrace);
    } finally {
      handle.requests.remove(requestId);
      handle.endOperation();
    }
  }

  @override
  Future<void> cancelRender(String requestId) async {
    for (final handle in _documents.values) {
      final request = handle.requests[requestId];
      if (request == null) continue;
      request.cancelled = true;
      request.token?.cancel();
      return;
    }
  }

  @override
  Future<void> closeDocument(String documentId) async {
    final handle = _documents.remove(documentId);
    if (handle == null) return;

    handle.isClosing = true;
    for (final request in handle.requests.values) {
      request.cancelled = true;
      request.token?.cancel();
    }
    await handle.waitUntilIdle();
    await handle.document.dispose();
  }

  _PdfDocumentHandle _document(String documentId) {
    final handle = _documents[documentId];
    if (handle == null || handle.isClosing) {
      throw PlatformException(
        code: 'DOCUMENT_NOT_FOUND',
        message: 'The PDF document is not open.',
      );
    }
    return handle;
  }

  Future<PdfPage> _pageAt(PdfDocument document, int pageIndex) async {
    if (pageIndex < 0 || pageIndex >= document.pages.length) {
      throw PlatformException(
        code: 'INVALID_PAGE_INDEX',
        message: 'The requested PDF page is out of range.',
      );
    }
    var page = document.pages[pageIndex];
    if (!page.isLoaded) {
      await document.reloadPages(pageNumbersToReload: [pageIndex + 1]);
      page = document.pages[pageIndex];
    }
    return page.isLoaded ? page : page.ensureLoaded();
  }

  PdfPageInfo _pageInfo(PdfPage page) =>
      PdfPageInfo(width: page.width.round(), height: page.height.round());

  PlatformException _asPlatformException(Object error, [String? password]) {
    if (error is PlatformException) return error;
    if (error is PdfPasswordException) {
      return PlatformException(
        code: password == null ? 'PASSWORD_PROTECTED' : 'WRONG_PASSWORD',
        message: password == null
            ? 'This PDF requires a password.'
            : 'The password is incorrect.',
      );
    }
    if (error is FileSystemException) {
      return PlatformException(
        code: error.osError?.errorCode == 13
            ? 'FILE_ACCESS_DENIED'
            : 'FILE_NOT_FOUND',
        message: error.message,
      );
    }
    if (error is PdfException) {
      final message = error.message.toLowerCase();
      return PlatformException(
        code: message.contains('unsupported')
            ? 'UNSUPPORTED_PDF'
            : 'DAMAGED_PDF',
        message: error.message,
      );
    }
    return PlatformException(
      code: 'PDF_RENDER_FAILED',
      message: error.toString(),
    );
  }
}

class _PdfDocumentHandle {
  _PdfDocumentHandle(this.document);

  final PdfDocument document;
  final Map<String, _PdfRenderRequest> requests = {};
  int _activeOperations = 0;
  Completer<void>? _idle;
  bool isClosing = false;

  void beginOperation() {
    if (isClosing) {
      throw PlatformException(
        code: 'DOCUMENT_NOT_FOUND',
        message: 'The PDF document is closing.',
      );
    }
    _activeOperations++;
    _idle ??= Completer<void>();
  }

  void endOperation() {
    _activeOperations--;
    if (_activeOperations == 0) {
      _idle?.complete();
      _idle = null;
    }
  }

  Future<void> waitUntilIdle() =>
      _activeOperations == 0 ? Future<void>.value() : _idle!.future;
}

class _PdfRenderRequest {
  PdfPageRenderCancellationToken? token;
  bool cancelled = false;
}

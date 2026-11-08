import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/pdf_renderer_provider.dart';
import '../../core/providers/pdf_reading_progress_provider.dart';
import '../../core/providers/file_content_provider.dart';
import '../../core/tabs/tabs_manager.dart';
import '../../domain/entities/detected_file_content.dart';
import '../../domain/entities/pdf_reading_progress.dart';
import '../../domain/entities/pdf_document_info.dart';
import '../../domain/entities/video_player_item.dart';
import '../../domain/repositories/pdf_renderer_repository.dart';
import '../common/marquee_text.dart';
import '../common/open_audio_file.dart';
import '../common/open_pdf_file.dart';
import '../common/open_video_file.dart';

const int maxPdfBitmapDimension = 4096;
const int _maxPdfCacheBytes = 64 * 1024 * 1024;
const double _pageGap = 12;

class PdfViewerTab extends ConsumerStatefulWidget {
  const PdfViewerTab({
    super.key,
    required this.path,
    required this.volumeId,
    required this.relativePath,
    this.persistReadingProgress = true,
    required this.isChromeHidden,
    required this.isSystemFullscreen,
    required this.onChromeHiddenChanged,
    required this.onSystemFullscreenChanged,
    required this.onZoomChanged,
  });

  final String path;
  final String volumeId;
  final String relativePath;
  final bool persistReadingProgress;
  final bool isChromeHidden;
  final bool isSystemFullscreen;
  final ValueChanged<bool> onChromeHiddenChanged;
  final ValueChanged<bool> onSystemFullscreenChanged;
  final ValueChanged<bool> onZoomChanged;

  @override
  ConsumerState<PdfViewerTab> createState() => PdfViewerTabState();
}

class PdfViewerTabState extends ConsumerState<PdfViewerTab>
    with WidgetsBindingObserver, AutomaticKeepAliveClientMixin {
  final ScrollController _verticalScroll = ScrollController();
  final ScrollController _horizontalScroll = ScrollController();
  final TextEditingController _passwordController = TextEditingController();
  final Map<int, _CachedPdfPage> _pageCache = {};
  final Map<int, String> _renderRequests = {};
  final Map<int, Object> _pageErrors = {};
  final Map<int, Offset> _activePointers = {};
  final Map<int, PdfPageInfo> _pageInfo = {};
  final List<double> _pageOffsets = [];

  PdfDocumentInfo? _document;
  Object? _openError;
  DetectedFileContent? _detectedContentMismatch;
  String? _documentId;
  String? _passwordError;
  String? _pdfPassword;
  bool _isVisible = false;
  bool _isOpening = false;
  bool _isDisposing = false;
  double _zoom = 1;
  double _viewportWidth = 0;
  double _viewportHeight = 0;
  double _devicePixelRatio = 1;
  int _generation = 0;
  int _requestSequence = 0;
  int _cacheSizeBytes = 0;
  int _currentPage = 0;
  int _activeRenderCount = 0;
  double? _previousPinchDistance;
  double? _pendingVerticalZoomOffset;
  double? _pendingHorizontalZoomOffset;
  bool _zoomOffsetUpdateScheduled = false;
  bool _pinchInProgress = false;
  Timer? _progressSaveTimer;
  Timer? _restoreMessageTimer;
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>?
  _restoreMessageController;
  int? _restorePageNumber;
  double _restorePageFraction = 0;
  bool _restorePositionPending = false;
  int _restoreAttempts = 0;
  String? _openVolumeId;
  String? _openRelativePath;
  int? _fileSize;
  int? _modifiedTimeMilliseconds;
  bool _progressTrackingEnabled = true;
  Future<void>? _pendingProgressSave;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _verticalScroll.addListener(_onVerticalScrollChanged);
    _horizontalScroll.addListener(_schedulePageUpdate);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      unawaited(_saveProgressAndTrack());
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _setVisible(MarqueeVisibility.isVisibleOf(context));
  }

  @override
  void didUpdateWidget(covariant PdfViewerTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path ||
        oldWidget.volumeId != widget.volumeId ||
        oldWidget.relativePath != widget.relativePath) {
      _pdfPassword = null;
      _passwordController.clear();
      _passwordError = null;
      unawaited(_releaseDocument());
      if (_isVisible) unawaited(_openDocument());
    }
    if (oldWidget.persistReadingProgress != widget.persistReadingProgress) {
      _progressTrackingEnabled = widget.persistReadingProgress;
      if (!_progressTrackingEnabled) {
        _progressSaveTimer?.cancel();
        _progressSaveTimer = null;
      }
    }
  }

  @override
  void dispose() {
    unawaited(_saveProgressAndTrack());
    WidgetsBinding.instance.removeObserver(this);
    _progressSaveTimer?.cancel();
    _clearRestoreMessage();
    _isDisposing = true;
    _isVisible = false;
    _pdfPassword = null;
    _passwordController.clear();
    unawaited(_releaseDocument());
    _verticalScroll
      ..removeListener(_onVerticalScrollChanged)
      ..dispose();
    _horizontalScroll
      ..removeListener(_schedulePageUpdate)
      ..dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _setVisible(bool visible) {
    if (_isVisible == visible) return;
    _isVisible = visible;
    if (visible) {
      if (_document == null) {
        unawaited(_openDocument());
      } else {
        _schedulePageUpdate();
      }
    } else {
      unawaited(_saveProgressAndTrack());
      _clearRestoreMessage();
      unawaited(_suspendRendering());
    }
  }

  Future<void> _suspendRendering() async {
    ++_generation;
    final requestIds = _renderRequests.values.toList(growable: false);
    _renderRequests.clear();
    _clearCache();
    final repository = ref.read(pdfRendererRepositoryProvider);
    for (final requestId in requestIds) {
      try {
        await repository.cancelRender(requestId);
      } catch (error) {
        debugPrint('Could not suspend PDF page rendering: $error');
      }
    }
  }

  void _onVerticalScrollChanged() {
    _schedulePageUpdate();
    _progressSaveTimer?.cancel();
    _progressSaveTimer = Timer(
      const Duration(seconds: 1),
      () => unawaited(saveProgressNow()),
    );
  }

  Future<void> saveProgressNow() async {
    _progressSaveTimer?.cancel();
    _progressSaveTimer = null;
    final document = _document;
    if (!_progressTrackingEnabled ||
        document == null ||
        _pageOffsets.length != document.pageCount) {
      return;
    }

    final range = _visiblePageRange();
    final pageIndex = range.current.clamp(0, document.pageCount - 1);
    final pageStart = _pageOffset(pageIndex);
    final pageHeight = _pageHeight(pageIndex);
    final pageFraction = pageHeight <= 0
        ? 0.0
        : ((_verticalScroll.hasClients ? _verticalScroll.offset : 0) -
                  pageStart) /
              pageHeight;
    final volumeId = _openVolumeId;
    final relativePath = _openRelativePath;
    final fileSize = _fileSize;
    final modifiedTimeMilliseconds = _modifiedTimeMilliseconds;
    if (volumeId == null ||
        relativePath == null ||
        fileSize == null ||
        modifiedTimeMilliseconds == null) {
      return;
    }
    final repository = ref.read(pdfReadingProgressRepositoryProvider);
    try {
      await repository.save(
        volumeId,
        relativePath,
        PdfReadingProgress(
          pageNumber: pageIndex + 1,
          pageFraction: pageFraction.clamp(0.0, 1.0),
          pageCount: document.pageCount,
          fileSize: fileSize,
          modifiedTimeMilliseconds: modifiedTimeMilliseconds,
          lastOpenedTimeMilliseconds: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    } catch (error) {
      debugPrint('Could not save PDF reading position: $error');
    }
  }

  Future<void> _saveProgressAndTrack() {
    final save = saveProgressNow();
    _pendingProgressSave = save;
    unawaited(
      save.whenComplete(() {
        if (identical(_pendingProgressSave, save)) {
          _pendingProgressSave = null;
        }
      }),
    );
    return save;
  }

  void stopProgressTracking() {
    _progressTrackingEnabled = false;
    _progressSaveTimer?.cancel();
    _progressSaveTimer = null;
  }

  Future<void> _openDocument() async {
    if (!_isVisible || _document != null || _isOpening) return;
    final generation = ++_generation;
    PdfRendererRepository? openingRepository;
    String? openingDocumentId;
    setState(() {
      _isOpening = true;
      _openError = null;
      _detectedContentMismatch = null;
      _passwordError = null;
    });
    try {
      await _pendingProgressSave;
      if (!mounted || generation != _generation || !_isVisible) return;
      final detectedContent = await ref.read(sniffFileContentProvider)(
        widget.path,
      );
      if (detectedContent.isKnown && detectedContent.category != 'Documents') {
        if (!mounted || generation != _generation || !_isVisible) return;
        setState(() {
          _isOpening = false;
          _openError = StateError('Content does not match PDF');
          _detectedContentMismatch = detectedContent;
        });
        return;
      }
      final repository = ref.read(pdfRendererRepositoryProvider);
      openingRepository = repository;
      final document = await repository.openDocument(
        widget.path,
        password: _pdfPassword,
      );
      openingDocumentId = document.documentId;
      if (document.pageCount <= 0) {
        await _closeRendererDocument(repository, document.documentId);
        openingDocumentId = null;
        throw PlatformException(
          code: 'EMPTY_PDF',
          message: 'This PDF has no pages.',
        );
      }
      if (!mounted || generation != _generation || !_isVisible) {
        unawaited(_closeRendererDocument(repository, document.documentId));
        openingDocumentId = null;
        return;
      }
      final fileStat = await File(widget.path).stat();
      final progressRepository = ref.read(pdfReadingProgressRepositoryProvider);
      PdfReadingProgress? savedProgress;
      Object? progressError;
      try {
        savedProgress = await progressRepository.get(
          widget.volumeId,
          widget.relativePath,
        );
      } catch (error) {
        progressError = error;
        debugPrint('Could not load PDF reading position: $error');
      }
      if (!mounted || generation != _generation || !_isVisible) {
        unawaited(_closeRendererDocument(repository, document.documentId));
        openingDocumentId = null;
        return;
      }
      final savedRecordMatches =
          savedProgress != null &&
          savedProgress.pageCount == document.pageCount &&
          savedProgress.fileSize == fileStat.size &&
          savedProgress.modifiedTimeMilliseconds ==
              fileStat.modified.millisecondsSinceEpoch;
      final initialProgress = savedRecordMatches
          ? savedProgress
          : PdfReadingProgress(
              pageNumber: 1,
              pageFraction: 0,
              pageCount: document.pageCount,
              fileSize: fileStat.size,
              modifiedTimeMilliseconds:
                  fileStat.modified.millisecondsSinceEpoch,
              lastOpenedTimeMilliseconds: DateTime.now().millisecondsSinceEpoch,
            );
      final pageNumber = initialProgress.pageNumber
          .clamp(1, document.pageCount)
          .toInt();
      final progressToStore = PdfReadingProgress(
        pageNumber: pageNumber,
        pageFraction: initialProgress.pageFraction.clamp(0.0, 1.0),
        pageCount: document.pageCount,
        fileSize: fileStat.size,
        modifiedTimeMilliseconds: fileStat.modified.millisecondsSinceEpoch,
        lastOpenedTimeMilliseconds: DateTime.now().millisecondsSinceEpoch,
      );
      try {
        await progressRepository.save(
          widget.volumeId,
          widget.relativePath,
          progressToStore,
        );
      } catch (error) {
        progressError = error;
        debugPrint('Could not save PDF reading position: $error');
      }
      if (!mounted || generation != _generation || !_isVisible) {
        unawaited(_closeRendererDocument(repository, document.documentId));
        openingDocumentId = null;
        return;
      }
      _document = document;
      _documentId = document.documentId;
      _passwordController.clear();
      openingDocumentId = null;
      _openVolumeId = widget.volumeId;
      _openRelativePath = widget.relativePath;
      _fileSize = fileStat.size;
      _modifiedTimeMilliseconds = fileStat.modified.millisecondsSinceEpoch;
      _restorePageNumber = savedRecordMatches ? pageNumber : null;
      _restorePageFraction = savedRecordMatches
          ? progressToStore.pageFraction
          : 0;
      _restorePositionPending = savedRecordMatches;
      _pageInfo[0] = PdfPageInfo(
        width: document.firstPageWidth,
        height: document.firstPageHeight,
      );
      _rebuildPageOffsets();
      setState(() {
        _isOpening = false;
        _currentPage = pageNumber - 1;
      });
      _applyPendingRestorePosition();
      _schedulePageUpdate();
      if (progressError != null && mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text(
              'Could not load or save this PDF reading position: $progressError',
            ),
          ),
        );
      }
    } catch (error) {
      if (openingRepository != null && openingDocumentId != null) {
        unawaited(_closeRendererDocument(openingRepository, openingDocumentId));
      }
      if (!mounted || generation != _generation) return;
      setState(() {
        _isOpening = false;
        _openError = error;
        _passwordError = _passwordErrorFor(error);
      });
    }
  }

  String? _passwordErrorFor(Object error) {
    if (error is! PlatformException) return null;
    return switch (error.code) {
      'PASSWORD_PROTECTED' => 'required',
      'WRONG_PASSWORD' => 'incorrect',
      'PASSWORD_UNSUPPORTED' => 'unsupported',
      _ => null,
    };
  }

  void _submitPassword() {
    _pdfPassword = _passwordController.text;
    unawaited(_openDocument());
  }

  Future<void> _releaseDocument() async {
    ++_generation;
    final requestIds = _renderRequests.values.toList(growable: false);
    _renderRequests.clear();
    final documentId = _documentId;
    _documentId = null;
    _document = null;
    _pageInfo.clear();
    _pageOffsets.clear();
    _pageErrors.clear();
    _restorePositionPending = false;
    _openError = null;
    _passwordError = null;
    _isOpening = false;
    _clearCache();
    if (mounted && !_isDisposing) setState(() {});
    final repository = ref.read(pdfRendererRepositoryProvider);
    for (final requestId in requestIds) {
      try {
        await repository.cancelRender(requestId);
      } catch (error) {
        debugPrint('Could not cancel PDF page rendering: $error');
      }
    }
    if (documentId != null) {
      await _closeRendererDocument(repository, documentId);
    }
    if (mounted && _isVisible && _document == null) {
      unawaited(_openDocument());
    }
  }

  Future<void> _closeRendererDocument(
    PdfRendererRepository repository,
    String documentId,
  ) async {
    try {
      await repository.closeDocument(documentId);
    } catch (error) {
      debugPrint('Could not close PDF document: $error');
    }
  }

  String _openErrorMessage(Object? error) {
    final detectedContent = _detectedContentMismatch;
    if (detectedContent != null) {
      return 'This file is ${detectedContent.description}, not a PDF.';
    }
    if (error is PlatformException) {
      switch (error.code) {
        case 'FILE_NOT_FOUND':
          return 'This PDF file is missing or no longer available.';
        case 'EMPTY_PDF':
          return 'This PDF has no pages.';
        case 'PASSWORD_PROTECTED':
          return 'This PDF is password-protected.';
        case 'WRONG_PASSWORD':
          return 'That password is incorrect. Try again.';
        case 'PASSWORD_UNSUPPORTED':
          return 'Password-protected PDFs require Android 15 or newer in the built-in viewer.';
        case 'INVALID_PDF':
          return 'This PDF is damaged or is not a supported PDF file.';
        default:
          return error.message ?? 'Could not open this PDF.';
      }
    }
    return 'Could not open this PDF: $error';
  }

  Future<void> _openWithAnotherApp() async {
    await openPdfFile(
      context,
      ref,
      path: widget.path,
      name: _fileName(widget.path),
      excludeBuiltIn: true,
      useSavedDefaultApps: false,
    );
  }

  Future<void> _openDetectedContent() async {
    final detectedContent = _detectedContentMismatch;
    if (detectedContent == null || !mounted) return;
    switch (detectedContent.category) {
      case 'Image':
        TabsManager.instance.openImageViewer(
          widget.path,
          imagePaths: [widget.path],
        );
      case 'Text':
        TabsManager.instance.openTextEditor(widget.path);
      case 'Audio':
        openAudioFile(
          ref,
          path: widget.path,
          queuePaths: [widget.path],
          allowExtensionOverride: true,
        );
      case 'Video':
        await openVideoFile(
          context,
          ref,
          path: widget.path,
          name: _fileName(widget.path),
          playlist: [
            VideoPlayerItem(path: widget.path, name: _fileName(widget.path)),
          ],
          currentIndex: 0,
          useSavedDefaultApps: false,
          allowSaveDefault: false,
          mimeTypeOverride: detectedContent.mimeType,
        );
      case 'Archives':
        TabsManager.instance.openArchiveManagerTab(widget.path);
      default:
        return;
    }
  }

  void _schedulePageUpdate() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_isVisible || _document == null) return;
      _updateVisiblePages();
    });
  }

  void _applyPendingRestorePosition() {
    if (!_restorePositionPending) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !_restorePositionPending ||
          !_verticalScroll.hasClients ||
          _document == null ||
          _viewportWidth <= 0) {
        return;
      }
      final pageIndex =
          (_restorePageNumber ?? 1).clamp(1, _document!.pageCount).toInt() - 1;
      final target =
          _pageOffset(pageIndex) +
          _restorePageFraction * _pageHeight(pageIndex);
      final position = _verticalScroll.position;
      _verticalScroll.jumpTo(
        target.clamp(position.minScrollExtent, position.maxScrollExtent),
      );
      if (target > position.maxScrollExtent + 1 && _restoreAttempts++ < 8) {
        _applyPendingRestorePosition();
        return;
      }
      _restorePositionPending = false;
      _restoreAttempts = 0;
      _schedulePageUpdate();
      _showRestoreMessage(pageIndex + 1);
    });
  }

  void _showRestoreMessage(int pageNumber) {
    _clearRestoreMessage();
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    _restoreMessageController = messenger.showSnackBar(
      SnackBar(
        content: Text('Opened at page $pageNumber'),
        duration: const Duration(seconds: 4),
        action: SnackBarAction(
          label: 'Start over',
          onPressed: () {
            _clearRestoreMessage();
            _jumpToPage(1);
            unawaited(saveProgressNow());
          },
        ),
      ),
    );
    _restoreMessageTimer = Timer(
      const Duration(seconds: 4),
      _clearRestoreMessage,
    );
  }

  void _clearRestoreMessage() {
    _restoreMessageTimer?.cancel();
    _restoreMessageTimer = null;
    _restoreMessageController?.close();
    _restoreMessageController = null;
  }

  void _jumpToPage(int pageNumber) {
    final document = _document;
    if (document == null || !_verticalScroll.hasClients) return;
    final pageIndex = (pageNumber - 1).clamp(0, document.pageCount - 1);
    final position = _verticalScroll.position;
    final target = _pageOffset(pageIndex);
    _verticalScroll.jumpTo(
      target.clamp(position.minScrollExtent, position.maxScrollExtent),
    );
    _currentPage = pageIndex;
    _schedulePageUpdate();
  }

  Future<void> _showSearchDialog() async {
    final document = _document;
    final documentId = _documentId;
    if (document == null || documentId == null) return;
    final controller = TextEditingController();
    var results = <int>[];
    var resultIndex = -1;
    var searching = false;
    String? errorMessage;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          Future<void> search() async {
            final query = controller.text.trim();
            if (query.isEmpty || searching) return;
            setDialogState(() {
              searching = true;
              errorMessage = null;
              results = [];
              resultIndex = -1;
            });
            try {
              final matches = await ref
                  .read(pdfRendererRepositoryProvider)
                  .searchText(documentId, query);
              if (!dialogContext.mounted) return;
              setDialogState(() {
                results = matches;
                resultIndex = matches.isEmpty ? -1 : 0;
              });
              if (matches.isNotEmpty) _jumpToPage(matches.first + 1);
            } on PlatformException catch (error) {
              if (!dialogContext.mounted) return;
              setDialogState(() {
                errorMessage = error.code == 'PDF_TEXT_SEARCH_UNAVAILABLE'
                    ? 'Text search requires Android 15 or newer.'
                    : error.message ?? 'Could not search this PDF.';
              });
            } catch (error) {
              if (!dialogContext.mounted) return;
              setDialogState(
                () => errorMessage = 'Could not search this PDF: $error',
              );
            } finally {
              if (dialogContext.mounted) {
                setDialogState(() => searching = false);
              }
            }
          }

          void showResult(int nextIndex) {
            if (nextIndex < 0 || nextIndex >= results.length) return;
            setDialogState(() => resultIndex = nextIndex);
            _jumpToPage(results[nextIndex] + 1);
          }

          return AlertDialog(
            title: const Text('Find in PDF'),
            content: SizedBox(
              width: 360,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: controller,
                    autofocus: true,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => search(),
                    decoration: InputDecoration(
                      labelText: 'Search text',
                      suffixIcon: IconButton(
                        tooltip: 'Search',
                        onPressed: searching ? null : search,
                        icon: const Icon(Icons.search),
                      ),
                    ),
                  ),
                  if (searching) ...[
                    const SizedBox(height: 16),
                    const LinearProgressIndicator(),
                  ],
                  if (errorMessage != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      errorMessage!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                  if (!searching &&
                      errorMessage == null &&
                      results.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(
                      'Page ${results[resultIndex] + 1} · ${resultIndex + 1} of ${results.length} matching pages',
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        TextButton.icon(
                          onPressed: resultIndex > 0
                              ? () => showResult(resultIndex - 1)
                              : null,
                          icon: const Icon(Icons.arrow_upward),
                          label: const Text('Previous'),
                        ),
                        TextButton.icon(
                          onPressed: resultIndex < results.length - 1
                              ? () => showResult(resultIndex + 1)
                              : null,
                          icon: const Icon(Icons.arrow_downward),
                          label: const Text('Next'),
                        ),
                      ],
                    ),
                  ],
                  if (!searching &&
                      errorMessage == null &&
                      controller.text.trim().isNotEmpty &&
                      results.isEmpty)
                    const Padding(
                      padding: EdgeInsets.only(top: 12),
                      child: Text('No matching pages'),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Close'),
              ),
            ],
          );
        },
      ),
    );
    controller.dispose();
  }

  Future<void> _showGoToPageDialog() async {
    final document = _document;
    if (document == null) return;
    final controller = TextEditingController();
    String? errorText;
    final pageNumber = await showDialog<int>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Go to page'),
          content: SizedBox(
            width: 280,
            child: TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: 'Page number',
                helperText: '1-${document.pageCount}',
                errorText: errorText,
              ),
              onSubmitted: (value) {
                final number = int.tryParse(value);
                if (number == null ||
                    number < 1 ||
                    number > document.pageCount) {
                  setDialogState(
                    () => errorText =
                        'Enter a page from 1 to ${document.pageCount}.',
                  );
                  return;
                }
                Navigator.pop(dialogContext, number);
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final number = int.tryParse(controller.text);
                if (number == null ||
                    number < 1 ||
                    number > document.pageCount) {
                  setDialogState(
                    () => errorText =
                        'Enter a page from 1 to ${document.pageCount}.',
                  );
                  return;
                }
                Navigator.pop(dialogContext, number);
              },
              child: const Text('Go'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    if (pageNumber != null && mounted) _jumpToPage(pageNumber);
  }

  void _onViewportLayout(double width, double height, double devicePixelRatio) {
    final oldWidth = _viewportWidth;
    if (_viewportWidth == width &&
        _viewportHeight == height &&
        _devicePixelRatio == devicePixelRatio) {
      return;
    }
    _viewportWidth = width;
    _viewportHeight = height;
    _devicePixelRatio = devicePixelRatio;
    if (oldWidth != width) {
      if (oldWidth > 0 && _verticalScroll.hasClients) {
        final oldOffset = _verticalScroll.offset;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!_verticalScroll.hasClients || oldWidth <= 0) return;
          final position = _verticalScroll.position;
          _verticalScroll.jumpTo(
            (oldOffset * width / oldWidth).clamp(
              position.minScrollExtent,
              position.maxScrollExtent,
            ),
          );
        });
      }
    }
    _applyPendingRestorePosition();
    _schedulePageUpdate();
  }

  double _aspectRatio(int pageIndex) {
    final info = _pageInfo[pageIndex];
    if (info != null && info.height > 0) return info.aspectRatio;
    final document = _document;
    if (document == null || document.firstPageHeight <= 0) return 1;
    return document.firstPageWidth / document.firstPageHeight;
  }

  double _pageHeight(int pageIndex) =>
      _viewportWidth * _zoom / _aspectRatio(pageIndex);

  double _pageOffset(int pageIndex) =>
      _pageOffsets[pageIndex] * _viewportWidth * _zoom +
      pageIndex * _pageGap;

  double _pageOffsetAtZoom(int pageIndex, double zoom) =>
      _pageOffsets[pageIndex] * _viewportWidth * zoom +
      pageIndex * _pageGap;

  double _pageHeightAtZoom(int pageIndex, double zoom) =>
      _viewportWidth * zoom / _aspectRatio(pageIndex);

  ({int pageIndex, double fraction}) _pageAnchorAt(double contentOffset) {
    final pageCount = _document?.pageCount ?? 0;
    if (pageCount <= 0) return (pageIndex: 0, fraction: 0);

    var low = 0;
    var high = pageCount;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (_pageOffset(mid) <= contentOffset) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }

    final previous = (low - 1).clamp(0, pageCount - 1).toInt();
    final next = low.clamp(0, pageCount - 1).toInt();
    final previousTop = _pageOffset(previous);
    final previousBottom = previousTop + _pageHeight(previous);
    final pageIndex = contentOffset <= previousBottom || previous == next
        ? previous
        : (contentOffset - previousBottom < _pageOffset(next) - contentOffset
              ? previous
              : next);
    final pageTop = _pageOffset(pageIndex);
    final pageHeight = _pageHeight(pageIndex);
    final fraction = pageHeight <= 0
        ? 0.0
        : ((contentOffset - pageTop) / pageHeight).clamp(0.0, 1.0);
    return (pageIndex: pageIndex, fraction: fraction);
  }

  ({int first, int last, int current}) _visiblePageRange() {
    final pageCount = _document?.pageCount ?? 0;
    if (pageCount <= 0 ||
        _viewportHeight <= 0 ||
        _viewportWidth <= 0 ||
        _pageOffsets.length != pageCount) {
      return (first: 0, last: -1, current: 0);
    }
    final top = _verticalScroll.hasClients ? _verticalScroll.offset : 0.0;
    final bottom = top + _viewportHeight;
    final center = (top + bottom) / 2;
    var low = 0;
    var high = pageCount;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      final end = _pageOffset(mid) + _pageHeight(mid);
      if (end < top) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    final first = low.clamp(0, pageCount - 1).toInt();
    low = first;
    high = pageCount;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (_pageOffset(mid) <= bottom) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    final last = (low - 1).clamp(first, pageCount - 1).toInt();
    low = first;
    high = pageCount;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      final pageCenter = _pageOffset(mid) + _pageHeight(mid) / 2;
      if (pageCenter < center) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    final current = low >= pageCount
        ? pageCount - 1
        : low > first &&
              (center - (_pageOffset(low - 1) + _pageHeight(low - 1) / 2))
                      .abs() <
                  (_pageOffset(low) + _pageHeight(low) / 2 - center).abs()
        ? low - 1
        : low;
    return (first: first, last: last, current: current);
  }

  void _rebuildPageOffsets() {
    final pageCount = _document?.pageCount ?? 0;
    _pageOffsets
      ..clear()
      ..addAll(List<double>.filled(pageCount, 0));
    var nextOffset = 0.0;
    for (var index = 0; index < pageCount; index++) {
      _pageOffsets[index] = nextOffset;
      nextOffset += 1 / _aspectRatio(index);
    }
  }

  void _updateVisiblePages() {
    final document = _document;
    if (document == null || !_isVisible) return;
    final range = _visiblePageRange();
    final pageChanged = _currentPage != range.current;
    _currentPage = range.current;
    final firstRequired = math.max(0, range.first - 1);
    final lastRequired = math.min(document.pageCount - 1, range.last + 1);
    final required = <int>{
      for (var index = firstRequired; index <= lastRequired; index++) index,
    };

    for (final entry in _renderRequests.entries.toList()) {
      if (!required.contains(entry.key)) {
        _renderRequests.remove(entry.key);
        unawaited(_cancelRequest(entry.value));
      }
    }
    _trimCache(required);
    for (final pageIndex in required) {
      final cachedPage = _pageCache[pageIndex];
      final needsHigherResolution =
          cachedPage != null &&
          !_cacheMeetsZoomTarget(pageIndex, cachedPage.image);
      if ((cachedPage == null || needsHigherResolution) &&
          !_renderRequests.containsKey(pageIndex) &&
          !_pageErrors.containsKey(pageIndex) &&
          _activeRenderCount == 0) {
        unawaited(_renderPage(pageIndex));
        break;
      }
    }
    if (pageChanged && mounted) setState(() {});
  }

  Future<void> _cancelRequest(String requestId) async {
    try {
      await ref.read(pdfRendererRepositoryProvider).cancelRender(requestId);
    } catch (error) {
      debugPrint('Could not cancel PDF page rendering: $error');
    }
  }

  Future<void> _renderPage(int pageIndex) async {
    final document = _document;
    if (document == null || !_isVisible) return;
    final requestId = '${document.documentId}:$pageIndex:${++_requestSequence}';
    final generation = _generation;
    _renderRequests[pageIndex] = requestId;
    _activeRenderCount++;
    final pixelSize = _requestedPixelSize(pageIndex);
    final requestedWidth = pixelSize.width;
    final requestedHeight = pixelSize.height;
    try {
      final rendered = await ref
          .read(pdfRendererRepositoryProvider)
          .renderPage(
            documentId: document.documentId,
            pageIndex: pageIndex,
            width: requestedWidth,
            height: requestedHeight,
            requestId: requestId,
          );
      if (!mounted ||
          generation != _generation ||
          !_isVisible ||
          _renderRequests[pageIndex] != requestId) {
        return;
      }
      _updatePageInfo(pageIndex, rendered.pageInfo);
      final codec = await ui.instantiateImageCodec(rendered.bytes);
      late final ui.Image image;
      try {
        image = (await codec.getNextFrame()).image;
      } finally {
        codec.dispose();
      }
      if (!mounted ||
          generation != _generation ||
          !_isVisible ||
          _renderRequests[pageIndex] != requestId ||
          !_visiblePageRangeContains(pageIndex)) {
        image.dispose();
        return;
      }
      _renderRequests.remove(pageIndex);
      _pageErrors.remove(pageIndex);
      _putInCache(pageIndex, image);
      setState(() {});
      _schedulePageUpdate();
    } catch (error) {
      if (generation != _generation || !_isVisible) return;
      if (_renderRequests[pageIndex] == requestId) {
        _renderRequests.remove(pageIndex);
      }
      if (error is! PlatformException || error.code != 'RENDER_CANCELLED') {
        _pageErrors[pageIndex] = error;
        if (mounted) setState(() {});
      }
    } finally {
      if (_renderRequests[pageIndex] == requestId) {
        _renderRequests.remove(pageIndex);
      }
      _activeRenderCount--;
      if (_isVisible) _schedulePageUpdate();
    }
  }

  bool _visiblePageRangeContains(int pageIndex) {
    final document = _document;
    if (document == null) return false;
    final range = _visiblePageRange();
    return pageIndex >= math.max(0, range.first - 1) &&
        pageIndex <= math.min(document.pageCount - 1, range.last + 1);
  }

  ({int width, int height}) _requestedPixelSize(int pageIndex) {
    final info =
        _pageInfo[pageIndex] ??
        PdfPageInfo(
          width: _document!.firstPageWidth,
          height: _document!.firstPageHeight,
        );
    final visible = _visiblePageRange();
    final requiredPageCount = visible.last < visible.first
        ? 1
        : (visible.last - visible.first + 3).clamp(1, 5);
    final pageMemoryLimit = math.min(
      maxPdfBitmapDimension,
      math.sqrt(_maxPdfCacheBytes / (requiredPageCount * 4)).floor(),
    );
    final desiredWidth = _viewportWidth * _zoom * _devicePixelRatio;
    final scale = math.min(
      desiredWidth / info.width,
      math.min(
        pageMemoryLimit / info.width,
        pageMemoryLimit / info.height,
      ),
    );
    return (
      width: (info.width * scale).round().clamp(1, pageMemoryLimit),
      height: (info.height * scale).round().clamp(1, pageMemoryLimit),
    );
  }

  bool _cacheMeetsZoomTarget(int pageIndex, ui.Image image) {
    final target = _requestedPixelSize(pageIndex);
    return image.width >= target.width && image.height >= target.height;
  }

  void _updatePageInfo(int pageIndex, PdfPageInfo info) {
    final oldInfo = _pageInfo[pageIndex];
    if (oldInfo?.width == info.width && oldInfo?.height == info.height) return;
    final oldHeight = _pageHeight(pageIndex);
    _pageInfo[pageIndex] = info;
    _rebuildPageOffsets();
    final heightDelta = _pageHeight(pageIndex) - oldHeight;
    if (pageIndex < _visiblePageRange().current &&
        heightDelta != 0 &&
        !_pinchInProgress &&
        !_zoomOffsetUpdateScheduled) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_pinchInProgress || _zoomOffsetUpdateScheduled) return;
        if (_verticalScroll.hasClients) {
          final position = _verticalScroll.position;
          _verticalScroll.jumpTo(
            (position.pixels + heightDelta).clamp(
              position.minScrollExtent,
              position.maxScrollExtent,
            ),
          );
        }
      });
    }
  }

  void _putInCache(int pageIndex, ui.Image image) {
    final existing = _pageCache.remove(pageIndex);
    if (existing != null) {
      _cacheSizeBytes -= existing.byteSize;
      existing.image.dispose();
    }
    final byteSize = image.width * image.height * 4;
    _pageCache[pageIndex] = _CachedPdfPage(image, byteSize);
    _cacheSizeBytes += byteSize;
    while (_cacheSizeBytes > _maxPdfCacheBytes && _pageCache.isNotEmpty) {
      final oldestKey = _pageCache.keys.first;
      final oldest = _pageCache.remove(oldestKey)!;
      _cacheSizeBytes -= oldest.byteSize;
      oldest.image.dispose();
    }
  }

  void _trimCache(Set<int> required) {
    for (final entry in _pageCache.entries.toList()) {
      if (required.contains(entry.key)) continue;
      _pageCache.remove(entry.key);
      _cacheSizeBytes -= entry.value.byteSize;
      entry.value.image.dispose();
    }
  }

  void _clearCache() {
    for (final cachedPage in _pageCache.values) {
      cachedPage.image.dispose();
    }
    _pageCache.clear();
    _cacheSizeBytes = 0;
  }

  void _handlePointerDown(PointerDownEvent event) {
    _activePointers[event.pointer] = event.localPosition;
    if (_activePointers.length == 2) {
      _pinchInProgress = true;
      if (_verticalScroll.hasClients) {
        _verticalScroll.jumpTo(_verticalScroll.offset);
      }
      if (_horizontalScroll.hasClients) {
        _horizontalScroll.jumpTo(_horizontalScroll.offset);
      }
      _previousPinchDistance = _distanceBetweenPointers();
      setState(() {});
    }
  }

  void _handlePointerMove(PointerMoveEvent event) {
    final previousDistance = _previousPinchDistance;
    if (previousDistance == null || _activePointers.length < 2) {
      _activePointers[event.pointer] = event.localPosition;
      return;
    }
    _activePointers[event.pointer] = event.localPosition;
    final nextDistance = _distanceBetweenPointers();
    if (nextDistance <= 0 || previousDistance <= 0) return;
    final focalPoint = _pointerFocalPoint();
    _previousPinchDistance = nextDistance;
    _changeZoom(_zoom * nextDistance / previousDistance, focalPoint);
  }

  void _handlePointerUp(PointerEvent event) {
    _activePointers.remove(event.pointer);
    if (_activePointers.isEmpty) _pinchInProgress = false;
    _previousPinchDistance = _activePointers.length >= 2
        ? _distanceBetweenPointers()
        : null;
    if (mounted) setState(() {});
  }

  double _distanceBetweenPointers() {
    if (_activePointers.length < 2) return 0;
    final points = _activePointers.values.take(2).toList();
    return (points[0] - points[1]).distance;
  }

  Offset _pointerFocalPoint() {
    final points = _activePointers.values.take(2).toList();
    return Offset(
      (points[0].dx + points[1].dx) / 2,
      (points[0].dy + points[1].dy) / 2,
    );
  }

  void _changeZoom(double nextZoom, Offset focalPoint) {
    final oldZoom = _zoom;
    nextZoom = nextZoom.clamp(1.0, 5.0).toDouble();
    if ((nextZoom - oldZoom).abs() < 0.001) return;
    final oldVerticalOffset =
        _pendingVerticalZoomOffset ??
        (_verticalScroll.hasClients ? _verticalScroll.offset : 0.0);
    final oldHorizontalOffset =
        _pendingHorizontalZoomOffset ??
        (_horizontalScroll.hasClients ? _horizontalScroll.offset : 0.0);
    final ratio = nextZoom / oldZoom;
    final anchor = _pageAnchorAt(oldVerticalOffset + focalPoint.dy);
    _pendingVerticalZoomOffset =
        _pageOffsetAtZoom(anchor.pageIndex, nextZoom) +
        anchor.fraction * _pageHeightAtZoom(anchor.pageIndex, nextZoom) -
        focalPoint.dy;
    _pendingHorizontalZoomOffset =
        (oldHorizontalOffset + focalPoint.dx) * ratio - focalPoint.dx;
    _pageErrors.clear();
    setState(() => _zoom = nextZoom);
    final wasZoomed = oldZoom > 1.001;
    final isZoomed = nextZoom > 1.001;
    if (wasZoomed != isZoomed) widget.onZoomChanged(isZoomed);
    if (_zoomOffsetUpdateScheduled) return;
    _zoomOffsetUpdateScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _zoomOffsetUpdateScheduled = false;
      if (!mounted) {
        _pendingVerticalZoomOffset = null;
        _pendingHorizontalZoomOffset = null;
        return;
      }
      final verticalOffset = _pendingVerticalZoomOffset;
      final horizontalOffset = _pendingHorizontalZoomOffset;
      _pendingVerticalZoomOffset = null;
      _pendingHorizontalZoomOffset = null;
      if (verticalOffset != null && _verticalScroll.hasClients) {
        final position = _verticalScroll.position;
        _verticalScroll.jumpTo(
          verticalOffset.clamp(
            position.minScrollExtent,
            position.maxScrollExtent,
          ),
        );
      }
      if (horizontalOffset != null && _horizontalScroll.hasClients) {
        final position = _horizontalScroll.position;
        _horizontalScroll.jumpTo(
          horizontalOffset.clamp(
            position.minScrollExtent,
            position.maxScrollExtent,
          ),
        );
      }
      _schedulePageUpdate();
    });
  }

  void _handleDoubleTapDown(TapDownDetails details) {
    _doubleTapPosition = details.localPosition;
  }

  Offset? _doubleTapPosition;

  void _handleDoubleTap() {
    final targetZoom = _zoom > 1.01 ? 1.0 : 2.5;
    _changeZoom(
      targetZoom,
      _doubleTapPosition ?? Offset(_viewportWidth / 2, _viewportHeight / 2),
    );
  }

  void _toggleChrome() {
    widget.onChromeHiddenChanged(!widget.isChromeHidden);
  }

  void _toggleFullscreen() {
    widget.onSystemFullscreenChanged(!widget.isSystemFullscreen);
  }

  String _fileName(String path) =>
      path
          .split(RegExp(r'[/\\]'))
          .where((part) => part.isNotEmpty)
          .lastOrNull ??
      path;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final document = _document;
    final error = _openError;
    final bottomSystemInset = MediaQuery.viewPaddingOf(context).bottom;
    return ColoredBox(
      color: Theme.of(context).colorScheme.surface,
      child: SafeArea(
        top: false,
        bottom: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
            _onViewportLayout(
              constraints.maxWidth,
              constraints.maxHeight,
              devicePixelRatio,
            );
            if (error != null) {
              return _buildErrorView(error);
            }
            if (document == null) {
              return const Center(child: CircularProgressIndicator());
            }
            if (document.pageCount <= 0) {
              return const Center(child: Text('This PDF has no pages.'));
            }
            final visibleRange = _visiblePageRange();
            return Stack(
              fit: StackFit.expand,
              children: [
                Listener(
                  onPointerDown: _handlePointerDown,
                  onPointerMove: _handlePointerMove,
                  onPointerUp: _handlePointerUp,
                  onPointerCancel: _handlePointerUp,
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: _toggleChrome,
                    onDoubleTapDown: _handleDoubleTapDown,
                    onDoubleTap: _handleDoubleTap,
                    child: SingleChildScrollView(
                      controller: _horizontalScroll,
                      scrollDirection: Axis.horizontal,
                      physics: _zoom > 1.001 && !_pinchInProgress
                          ? const ClampingScrollPhysics()
                          : const NeverScrollableScrollPhysics(),
                      child: SizedBox(
                        width: constraints.maxWidth * _zoom,
                        child: ListView.builder(
                          controller: _verticalScroll,
                          itemCount: document.pageCount,
                          physics: _pinchInProgress
                              ? const NeverScrollableScrollPhysics()
                              : const ClampingScrollPhysics(),
                          itemBuilder: (context, pageIndex) {
                            final cachedPage = _pageCache[pageIndex];
                            final pageError = _pageErrors[pageIndex];
                            final pageWidth = constraints.maxWidth * _zoom;
                            final aspect = _aspectRatio(pageIndex);
                            return Padding(
                              padding: const EdgeInsets.only(bottom: _pageGap),
                              child: SizedBox(
                                width: pageWidth,
                                height: pageWidth / aspect,
                                child: _PdfPageSurface(
                                  image: cachedPage?.image,
                                  pageNumber: pageIndex + 1,
                                  error: pageError,
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                ),
                if (!widget.isChromeHidden)
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: _buildNameLayer(context),
                  ),
                if (!widget.isChromeHidden && !widget.isSystemFullscreen)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: bottomSystemInset + 8,
                    child: Center(
                      child: GestureDetector(
                        onTap: _showGoToPageDialog,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.48),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 5,
                            ),
                            child: Text(
                              '${visibleRange.current + 1} / ${document.pageCount}',
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildNameLayer(BuildContext context) => Container(
    height: 42,
    color: Colors.grey.withValues(alpha: 0.62),
    child: Row(
      children: [
        const SizedBox(width: 12),
        Expanded(
          child: MarqueeText(
            _fileName(widget.path),
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(color: Colors.white),
          ),
        ),
        IconButton(
          tooltip: 'Search in PDF',
          onPressed: _showSearchDialog,
          icon: const Icon(Icons.search, color: Colors.white),
        ),
        IconButton(
          tooltip: widget.isSystemFullscreen
              ? 'Exit full screen'
              : 'Full screen',
          onPressed: _toggleFullscreen,
          icon: Icon(
            widget.isSystemFullscreen
                ? Icons.fullscreen_exit
                : Icons.fullscreen,
            color: Colors.white,
          ),
        ),
      ],
    ),
  );

  Widget _buildErrorView(Object error) {
    final needsPassword =
        _passwordError == 'required' || _passwordError == 'incorrect';
    final canUseAnotherApp = _passwordError != null;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_openErrorMessage(error), textAlign: TextAlign.center),
            if (_detectedContentMismatch?.category != null) ...[
              const SizedBox(height: 12),
              FilledButton.tonal(
                onPressed: _openDetectedContent,
                child: Text('Open as ${_detectedContentMismatch!.name}'),
              ),
            ],
            if (needsPassword) ...[
              const SizedBox(height: 16),
              TextField(
                controller: _passwordController,
                autofocus: true,
                obscureText: true,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _submitPassword(),
                decoration: const InputDecoration(
                  labelText: 'PDF password',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _isOpening ? null : _submitPassword,
                child: const Text('Unlock PDF'),
              ),
            ],
            if (canUseAnotherApp) ...[
              const SizedBox(height: 12),
              FilledButton.tonal(
                onPressed: _openWithAnotherApp,
                child: const Text('Open with another app'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PdfPageSurface extends StatelessWidget {
  const _PdfPageSurface({
    required this.image,
    required this.pageNumber,
    required this.error,
  });

  final ui.Image? image;
  final int pageNumber;
  final Object? error;

  @override
  Widget build(BuildContext context) {
    const surface = Colors.white;
    if (error != null) {
      return ColoredBox(
        color: surface,
        child: Center(
          child: Text(
            'Could not render page $pageNumber',
            style: const TextStyle(color: Colors.black54),
          ),
        ),
      );
    }
    return ColoredBox(
      color: surface,
      child: image == null
          ? null
          : RawImage(
              image: image,
              fit: BoxFit.fill,
              filterQuality: FilterQuality.medium,
            ),
    );
  }
}

class _CachedPdfPage {
  const _CachedPdfPage(this.image, this.byteSize);

  final ui.Image image;
  final int byteSize;
}

extension on Iterable<String> {
  String? get lastOrNull {
    if (isEmpty) return null;
    return last;
  }
}

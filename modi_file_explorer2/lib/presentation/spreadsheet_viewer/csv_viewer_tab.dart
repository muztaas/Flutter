import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/csv_file_provider.dart';
import '../../core/tabs/tabs_manager.dart';
import '../../domain/repositories/csv_file_repository.dart';
import '../common/built_in_viewer_shell.dart';
import '../common/marquee_text.dart';
import '../common/open_spreadsheet_file.dart';
import 'spreadsheet_grid.dart';

class CsvViewerTab extends ConsumerStatefulWidget {
  const CsvViewerTab({
    super.key,
    required this.path,
    required this.isChromeHidden,
    required this.onChromeHiddenChanged,
    required this.onZoomChanged,
  });

  final String path;
  final bool isChromeHidden;
  final ValueChanged<bool> onChromeHiddenChanged;
  final ValueChanged<bool> onZoomChanged;

  @override
  ConsumerState<CsvViewerTab> createState() => _CsvViewerTabState();
}

class _CsvViewerTabState extends ConsumerState<CsvViewerTab>
    with AutomaticKeepAliveClientMixin {
  CsvSpreadsheetGridSource? _source;
  Object? _loadError;
  int _loadGeneration = 0;
  bool _isVisible = false;
  bool _isOpening = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _setVisible(MarqueeVisibility.isVisibleOf(context));
  }

  @override
  void didUpdateWidget(covariant CsvViewerTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) {
      _closeSource();
      _loadError = null;
      if (_isVisible) unawaited(_openFile());
    }
  }

  @override
  void dispose() {
    _isVisible = false;
    _closeSource();
    super.dispose();
  }

  void _setVisible(bool visible) {
    if (_isVisible == visible) return;
    _isVisible = visible;
    if (visible) {
      if (_source == null && !_isOpening) unawaited(_openFile());
    } else {
      _closeSource();
    }
  }

  void _closeSource() {
    ++_loadGeneration;
    final source = _source;
    _source = null;
    _isOpening = false;
    if (source != null) unawaited(source.close());
  }

  Future<void> _openFile() async {
    if (!_isVisible || _isOpening) return;
    final generation = ++_loadGeneration;
    setState(() {
      _isOpening = true;
      _loadError = null;
    });
    try {
      final session = await ref.read(csvFileRepositoryProvider).open(widget.path);
      if (!mounted || !_isVisible || generation != _loadGeneration) {
        await session.close();
        return;
      }
      final source = CsvSpreadsheetGridSource(session);
      setState(() {
        _source = source;
        _isOpening = false;
      });
    } catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _loadError = error;
        _isOpening = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final source = _source;
    return BuiltInViewerShell(
      name: widget.path.split(RegExp(r'[/\\]')).last,
      isChromeHidden: widget.isChromeHidden,
      onChromeHiddenChanged: widget.onChromeHiddenChanged,
      onOpenWithAnother: () => openSpreadsheetFile(
        context,
        ref,
        path: widget.path,
        name: widget.path.split(RegExp(r'[/\\]')).last,
        excludeBuiltIn: true,
        useSavedDefaultApps: false,
        allowSaveDefault: false,
      ),
      actions: [
        IconButton(
          tooltip: 'Edit as text',
          onPressed: () => TabsManager.instance.openTextEditor(widget.path),
          icon: const Icon(Icons.edit_note),
        ),
      ],
      child: source != null
          ? SpreadsheetGrid(source: source, onZoomChanged: widget.onZoomChanged)
          : Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_loadError == null)
                      const CircularProgressIndicator()
                    else
                      const Icon(Icons.insert_drive_file_outlined, size: 40),
                    const SizedBox(height: 12),
                    Text(
                      _loadError == null
                          ? 'Loading rows...'
                          : 'Could not open this CSV or TSV file: $_loadError',
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}

class CsvSpreadsheetGridSource extends SpreadsheetGridDataSource {
  static const int _maxCachedRows = 64;

  CsvSpreadsheetGridSource(this._session)
    : _progress = _session.currentProgress {
    _progressSubscription = _session.progress.listen(
      (progress) {
        _progress = progress;
        notifyListeners();
      },
      onError: (Object error) {
        _warningMessage = 'CSV reading stopped: $error';
        notifyListeners();
      },
    );
  }

  final CsvReadSession _session;
  late final StreamSubscription<CsvIndexProgress> _progressSubscription;
  final Map<int, Future<SpreadsheetRowData>> _rowCache = {};
  CsvIndexProgress _progress;
  String? _warningMessage;
  bool _isClosed = false;
  bool _isDisposed = false;

  @override
  int get rowCount => _progress.rowCount;

  @override
  int get columnCount => _progress.columnCount;

  @override
  bool get isIndexing => !_progress.isComplete;

  @override
  bool get isTruncated => _progress.isTruncated;

  @override
  String get truncationMessage =>
      'Showing the first ${_progress.rowCount} rows ($maxCsvRows-row limit)';

  @override
  String? get warningMessage => _warningMessage;

  @override
  Future<SpreadsheetRowData> loadRow(int rowIndex) {
    if (_isClosed) {
      return Future.error(StateError('CSV grid is closed'));
    }
    final cached = _rowCache.remove(rowIndex);
    if (cached != null) {
      _rowCache[rowIndex] = cached;
      return cached;
    }
    final result = _session.readRow(rowIndex).then((row) {
      if (row.isTruncated && !_isClosed) {
        _warningMessage =
            'Some rows or cells were truncated to stay within viewer limits.';
        notifyListeners();
      }
      return row;
    });
    _rowCache[rowIndex] = result;
    while (_rowCache.length > _maxCachedRows) {
      _rowCache.remove(_rowCache.keys.first);
    }
    return result;
  }

  Future<void> close() async {
    if (_isClosed) return;
    _isClosed = true;
    _rowCache.clear();
    await _progressSubscription.cancel();
    await _session.close();
    if (!_isDisposed) {
      _isDisposed = true;
      super.dispose();
    }
  }

  @override
  void dispose() {
    if (!_isClosed) unawaited(close());
    if (!_isDisposed) {
      _isDisposed = true;
      super.dispose();
    }
  }
}

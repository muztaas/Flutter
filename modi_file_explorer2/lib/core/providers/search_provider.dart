import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/search_query.dart';
import '../../domain/entities/search_folder_candidate.dart';
import '../../domain/entities/search_result.dart';
import '../../domain/entities/search_scope.dart';
import '../../domain/usecases/search_files.dart';
import '../utils/file_name_comparator.dart';
import 'settings_provider.dart';
import 'search_files_provider.dart';

class SearchOverlayState {
  const SearchOverlayState({
    this.scope,
    this.query = '',
    this.criteria,
    this.filtersExpanded = false,
    this.results = const [],
    this.isSearching = false,
    this.hasSearched = false,
    this.limitReached = false,
    this.error,
    this.validationMessage,
    this.folderCandidates = const [],
    this.folderCandidatesLoading = false,
    this.folderCandidatesError,
    this.blacklistExpanded = false,
    this.whitelistExpanded = false,
    this.onResultSelected,
  });

  final SearchScope? scope;
  final String query;
  final SearchQuery? criteria;
  final bool filtersExpanded;
  final List<SearchResult> results;
  final bool isSearching;
  final bool hasSearched;
  final bool limitReached;
  final Object? error;
  final String? validationMessage;
  final List<SearchFolderCandidate> folderCandidates;
  final bool folderCandidatesLoading;
  final Object? folderCandidatesError;
  final bool blacklistExpanded;
  final bool whitelistExpanded;
  final Future<void> Function(SearchResult result)? onResultSelected;

  SearchQuery get searchQuery => criteria ?? SearchQuery(text: query);
  bool get isOpen => scope != null;
  int get activeFilterCount {
    final filters = searchQuery;
    return (filters.type != SearchItemType.filesAndFolders ? 1 : 0) +
        (filters.extensions.isNotEmpty ? 1 : 0) +
        (filters.modifiedFrom != null || filters.modifiedTo != null ? 1 : 0) +
        (filters.caseSensitive ? 1 : 0) +
        (filters.minimumSize != null || filters.maximumSize != null ? 1 : 0) +
        (filters.excludedFolders.isNotEmpty ? 1 : 0) +
        (filters.includedFolders.isNotEmpty ? 1 : 0);
  }

  String get statusText {
    String text;
    if (error != null) {
      text = 'Search failed: $error';
    } else if (validationMessage != null) {
      text = validationMessage!;
    } else if (query.trim().isEmpty && !searchQuery.hasActiveFilters) {
      text = 'Type to search';
    } else if (isSearching) {
      text = 'Searching... ${results.length} found';
    } else if (!hasSearched) {
      text = 'Type to search';
    } else if (results.isEmpty) {
      text = query.trim().isEmpty
          ? 'No results'
          : 'No results for "${query.trim()}"';
    } else {
      text = limitReached
          ? 'Showing first ${results.length} - refine your search'
          : '${results.length} results';
    }
    return activeFilterCount == 0 ? text : '$text - $activeFilterCount filters';
  }

  SearchOverlayState copyWith({
    SearchScope? scope,
    String? query,
    SearchQuery? criteria,
    bool? filtersExpanded,
    List<SearchResult>? results,
    bool? isSearching,
    bool? hasSearched,
    bool? limitReached,
    Object? error,
    bool clearError = false,
    String? validationMessage,
    bool clearValidationMessage = false,
    List<SearchFolderCandidate>? folderCandidates,
    bool? folderCandidatesLoading,
    Object? folderCandidatesError,
    bool clearFolderCandidatesError = false,
    bool? blacklistExpanded,
    bool? whitelistExpanded,
    Future<void> Function(SearchResult result)? onResultSelected,
  }) => SearchOverlayState(
    scope: scope ?? this.scope,
    query: query ?? this.query,
    criteria: criteria ?? this.criteria,
    filtersExpanded: filtersExpanded ?? this.filtersExpanded,
    results: results ?? this.results,
    isSearching: isSearching ?? this.isSearching,
    hasSearched: hasSearched ?? this.hasSearched,
    limitReached: limitReached ?? this.limitReached,
    error: clearError ? null : error ?? this.error,
    validationMessage: clearValidationMessage
        ? null
        : validationMessage ?? this.validationMessage,
    folderCandidates: folderCandidates ?? this.folderCandidates,
    folderCandidatesLoading:
        folderCandidatesLoading ?? this.folderCandidatesLoading,
    folderCandidatesError: clearFolderCandidatesError
        ? null
        : folderCandidatesError ?? this.folderCandidatesError,
    blacklistExpanded: blacklistExpanded ?? this.blacklistExpanded,
    whitelistExpanded: whitelistExpanded ?? this.whitelistExpanded,
    onResultSelected: onResultSelected ?? this.onResultSelected,
  );
}

class FileSearchController extends StateNotifier<SearchOverlayState> {
  FileSearchController(this._searchFiles, this._foldersFirst)
    : super(const SearchOverlayState());

  final SearchFiles _searchFiles;
  final bool Function() _foldersFirst;
  Timer? _debounce;
  StreamSubscription<SearchResultBatch>? _subscription;
  int _generation = 0;
  int _candidateGeneration = 0;

  void open(
    SearchScope scope, {
    Future<void> Function(SearchResult result)? onResultSelected,
  }) {
    _cancel();
    final candidateGeneration = ++_candidateGeneration;
    state = SearchOverlayState(
      scope: scope,
      criteria: SearchQuery(text: '', foldersFirst: _foldersFirst()),
      folderCandidatesLoading: true,
      onResultSelected: onResultSelected,
    );
    unawaited(_loadFolderCandidates(scope, candidateGeneration));
  }

  Future<void> _loadFolderCandidates(
    SearchScope scope,
    int generation,
  ) async {
    try {
      final candidates = await _searchFiles.listFilterFolders(scope);
      if (generation != _candidateGeneration || !state.isOpen) return;
      state = state.copyWith(
        folderCandidates: candidates,
        folderCandidatesLoading: false,
      );
    } catch (error) {
      if (generation != _candidateGeneration || !state.isOpen) return;
      state = state.copyWith(
        folderCandidatesLoading: false,
        folderCandidatesError: error,
      );
    }
  }

  void close() {
    _cancel();
    _candidateGeneration++;
    state = const SearchOverlayState();
  }

  void onTextChanged(String text) {
    if (!state.isOpen) return;
    final query = state.searchQuery.copyWith(text: text);
    state = state.copyWith(
      query: text,
      criteria: query,
      results: const [],
      isSearching: false,
      hasSearched: false,
      limitReached: false,
      clearError: true,
    );
    _scheduleSearch();
  }

  void clearText() => onTextChanged('');

  void updateFilters(SearchQuery criteria, {String? validationMessage}) {
    if (!state.isOpen) return;
    final next = criteria.copyWith(text: state.query);
    final invalidDateRange =
        next.modifiedFrom != null &&
        next.modifiedTo != null &&
        next.modifiedFrom!.isAfter(next.modifiedTo!);
    final message = validationMessage ??
        (invalidDateRange ? 'From date must be on or before To date.' : null);
    if (message != null) {
      _cancel();
      state = state.copyWith(
        criteria: next,
        validationMessage: message,
        isSearching: false,
      );
      return;
    }
    final sortOnly = _sameExceptSort(state.searchQuery, next);
    if (sortOnly && !state.limitReached && state.hasSearched) {
      final sorted = [...state.results]
        ..sort(
          (left, right) => compareSearchResultItems(
            left,
            right,
            next.sortField,
            next.sortDirection,
            foldersFirst: next.foldersFirst,
          ),
        );
      state = state.copyWith(
        criteria: next,
        results: sorted,
        clearValidationMessage: true,
      );
      return;
    }
    state = state.copyWith(
      criteria: next,
      results: const [],
      isSearching: false,
      hasSearched: false,
      limitReached: false,
      clearError: true,
      clearValidationMessage: true,
    );
    _scheduleSearch();
  }

  void resetFilters() {
    updateFilters(
      SearchQuery(text: state.query, foldersFirst: _foldersFirst()),
    );
  }

  void toggleFolderSelection(String folderId, {required bool blacklist}) {
    if (!state.isOpen) return;
    final current = state.searchQuery;
    final selected = blacklist
        ? {...current.excludedFolders}
        : {...current.includedFolders};
    if (!selected.add(folderId)) selected.remove(folderId);
    updateFilters(
      blacklist
          ? current.copyWith(excludedFolders: selected)
          : current.copyWith(includedFolders: selected),
    );
  }

  void toggleFolderList({required bool blacklist}) {
    if (!state.isOpen) return;
    state = state.copyWith(
      blacklistExpanded: blacklist
          ? !state.blacklistExpanded
          : state.blacklistExpanded,
      whitelistExpanded: blacklist
          ? state.whitelistExpanded
          : !state.whitelistExpanded,
    );
  }

  void updateFoldersFirst(bool value) {
    if (!state.isOpen || state.searchQuery.foldersFirst == value) return;
    updateFilters(state.searchQuery.copyWith(foldersFirst: value));
  }

  void toggleFilters() {
    if (!state.isOpen) return;
    state = state.copyWith(filtersExpanded: !state.filtersExpanded);
  }

  void submit() {
    _debounce?.cancel();
    _debounce = null;
    unawaited(_startSearch());
  }

  void removeResult(SearchResult result) {
    state = state.copyWith(
      results: state.results
          .where((candidate) => candidate.path != result.path)
          .toList(),
    );
  }

  Future<bool> openResult(SearchResult result) async {
    final available = await _searchFiles.isResultAvailable(result.path);
    if (!available) {
      removeResult(result);
      return false;
    }
    final onResultSelected = state.onResultSelected;
    close();
    await onResultSelected?.call(result);
    return true;
  }

  void _scheduleSearch() {
    _cancel();
    if (state.validationMessage != null) return;
    final query = state.searchQuery;
    if (_hasInvalidDateRange(query)) {
      state = state.copyWith(
        validationMessage: 'From date must be on or before To date.',
      );
      return;
    }
    if (query.text.isEmpty && !query.hasActiveFilters) return;
    _debounce = Timer(const Duration(milliseconds: 350), () {
      unawaited(_startSearch());
    });
  }

  Future<void> _startSearch() async {
    final scope = state.scope;
    final criteria = state.searchQuery;
    if (state.validationMessage != null || _hasInvalidDateRange(criteria)) {
      return;
    }
    if (scope == null ||
        (criteria.text.isEmpty && !criteria.hasActiveFilters)) {
      _cancel();
      state = state.copyWith(
        results: const [],
        isSearching: false,
        hasSearched: false,
      );
      return;
    }
    final generation = ++_generation;
    _debounce?.cancel();
    _debounce = null;
    final previous = _subscription;
    _subscription = null;
    await previous?.cancel();
    if (generation != _generation || !state.isOpen) return;

    state = state.copyWith(
      results: const [],
      isSearching: true,
      hasSearched: true,
      limitReached: false,
      clearError: true,
    );
    try {
      _subscription = _searchFiles(scope, criteria).listen(
        (batch) {
          if (generation != _generation) return;
          final activeQuery = state.searchQuery;
          final results = batch.replacesResults
              ? [...batch.results]
              : [...state.results, ...batch.results];
          results.sort(
            (left, right) => compareSearchResultItems(
              left,
              right,
              activeQuery.sortField,
              activeQuery.sortDirection,
              foldersFirst: activeQuery.foldersFirst,
            ),
          );
          state = state.copyWith(
            results: results,
            isSearching: !batch.isComplete,
            hasSearched: true,
            limitReached: batch.limitReached,
          );
          if (batch.limitReached &&
              (activeQuery.sortField != criteria.sortField ||
                  activeQuery.sortDirection != criteria.sortDirection ||
                  activeQuery.foldersFirst != criteria.foldersFirst)) {
            unawaited(_startSearch());
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          if (generation != _generation) return;
          state = state.copyWith(
            isSearching: false,
            hasSearched: true,
            error: error,
          );
        },
      );
    } catch (error) {
      if (generation != _generation) return;
      state = state.copyWith(
        isSearching: false,
        hasSearched: true,
        error: error,
      );
    }
  }

  bool _sameExceptSort(SearchQuery left, SearchQuery right) =>
      left.text == right.text &&
      left.caseSensitive == right.caseSensitive &&
      left.type == right.type &&
      _setEquals(left.extensions, right.extensions) &&
      left.modifiedFrom == right.modifiedFrom &&
      left.modifiedTo == right.modifiedTo &&
      left.minimumSize == right.minimumSize &&
      left.maximumSize == right.maximumSize &&
      _setEquals(left.excludedFolders, right.excludedFolders) &&
      _setEquals(left.includedFolders, right.includedFolders);

  bool _hasInvalidDateRange(SearchQuery query) =>
      query.modifiedFrom != null &&
      query.modifiedTo != null &&
      query.modifiedFrom!.isAfter(query.modifiedTo!);

  bool _setEquals(Set<String> left, Set<String> right) =>
      left.length == right.length && left.containsAll(right);

  void _cancel() {
    _generation++;
    _debounce?.cancel();
    _debounce = null;
    final subscription = _subscription;
    _subscription = null;
    if (subscription != null) unawaited(subscription.cancel());
  }

  @override
  void dispose() {
    _cancel();
    super.dispose();
  }
}

final fileSearchProvider = StateNotifierProvider.autoDispose
    .family<FileSearchController, SearchOverlayState, String>(
      (ref, _) => FileSearchController(
        ref.watch(searchFilesProvider),
        () => ref.read(foldersFirstProvider),
      ),
    );

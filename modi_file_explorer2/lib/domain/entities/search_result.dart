class SearchResult {
  const SearchResult({
    required this.path,
    required this.name,
    required this.containingPath,
    required this.isDirectory,
    this.size,
    this.modified,
    this.itemCount,
  });

  final String path;
  final String name;
  final String containingPath;
  final bool isDirectory;
  final int? size;
  final DateTime? modified;
  final int? itemCount;
}

class SearchResultBatch {
  const SearchResultBatch({
    required this.results,
    this.isComplete = false,
    this.limitReached = false,
    this.replacesResults = false,
  });

  final List<SearchResult> results;
  final bool isComplete;
  final bool limitReached;
  final bool replacesResults;
}

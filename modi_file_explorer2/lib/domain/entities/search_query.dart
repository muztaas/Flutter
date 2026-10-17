enum SearchItemType { filesAndFolders, filesOnly, foldersOnly }

enum SearchSortField { name, modified, size }

enum SearchSortDirection { ascending, descending }

class SearchQuery {
  SearchQuery({
    required String text,
    this.caseSensitive = false,
    this.type = SearchItemType.filesAndFolders,
    Set<String> extensions = const {},
    this.modifiedFrom,
    this.modifiedTo,
    this.minimumSize,
    this.maximumSize,
    this.sortField = SearchSortField.name,
    this.sortDirection = SearchSortDirection.ascending,
    this.foldersFirst = true,
    Set<String> excludedFolders = const {},
    Set<String> includedFolders = const {},
  }) : text = text.trim(),
       extensions = Set.unmodifiable(
         extensions.map((extension) => extension.toLowerCase()),
       ),
       excludedFolders = Set.unmodifiable(excludedFolders),
       includedFolders = Set.unmodifiable(includedFolders);

  final String text;
  final bool caseSensitive;
  final SearchItemType type;
  final Set<String> extensions;
  final DateTime? modifiedFrom;
  final DateTime? modifiedTo;
  final int? minimumSize;
  final int? maximumSize;
  final SearchSortField sortField;
  final SearchSortDirection sortDirection;
  final bool foldersFirst;
  final Set<String> excludedFolders;
  final Set<String> includedFolders;

  bool get hasActiveFilters =>
      type != SearchItemType.filesAndFolders ||
      extensions.isNotEmpty ||
      modifiedFrom != null ||
      modifiedTo != null ||
      caseSensitive ||
      minimumSize != null ||
      maximumSize != null;

  SearchQuery copyWith({
    String? text,
    bool? caseSensitive,
    SearchItemType? type,
    Set<String>? extensions,
    DateTime? modifiedFrom,
    bool clearModifiedFrom = false,
    DateTime? modifiedTo,
    bool clearModifiedTo = false,
    int? minimumSize,
    bool clearMinimumSize = false,
    int? maximumSize,
    bool clearMaximumSize = false,
    SearchSortField? sortField,
    SearchSortDirection? sortDirection,
    bool? foldersFirst,
    Set<String>? excludedFolders,
    Set<String>? includedFolders,
  }) => SearchQuery(
    text: text ?? this.text,
    caseSensitive: caseSensitive ?? this.caseSensitive,
    type: type ?? this.type,
    extensions: extensions ?? this.extensions,
    modifiedFrom: clearModifiedFrom ? null : modifiedFrom ?? this.modifiedFrom,
    modifiedTo: clearModifiedTo ? null : modifiedTo ?? this.modifiedTo,
    minimumSize: clearMinimumSize ? null : minimumSize ?? this.minimumSize,
    maximumSize: clearMaximumSize ? null : maximumSize ?? this.maximumSize,
    sortField: sortField ?? this.sortField,
    sortDirection: sortDirection ?? this.sortDirection,
    foldersFirst: foldersFirst ?? this.foldersFirst,
    excludedFolders: excludedFolders ?? this.excludedFolders,
    includedFolders: includedFolders ?? this.includedFolders,
  );
}

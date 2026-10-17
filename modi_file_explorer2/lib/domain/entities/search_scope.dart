enum SearchCategory { images, documents }

class SearchScope {
  const SearchScope._({
    required this.driveId,
    required this.relativePath,
    required this.category,
    required this.hintText,
  });

  const SearchScope.allStorage()
    : this._(
        driveId: null,
        relativePath: '',
        category: null,
        hintText: 'Search all storage',
      );

  factory SearchScope.forLocation({
    required String driveId,
    required String relativePath,
    required String driveName,
    required String folderName,
    SearchCategory? category,
  }) {
    final isDriveRoot = relativePath.isEmpty;
    final hintText = switch (category) {
      SearchCategory.images =>
        isDriveRoot ? 'Search images' : 'Search images in $folderName',
      SearchCategory.documents =>
        isDriveRoot ? 'Search documents' : 'Search documents in $folderName',
      null => isDriveRoot ? 'Search in $driveName' : 'Search in $folderName',
    };
    return SearchScope._(
      driveId: driveId,
      relativePath: relativePath,
      category: category,
      hintText: hintText,
    );
  }

  final String? driveId;
  final String relativePath;
  final SearchCategory? category;
  final String hintText;
}

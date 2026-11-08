abstract final class FileVisibility {
  static bool shouldShow({
    required String path,
    required bool isDirectory,
    required bool showHiddenFiles,
    required List<String> blacklistedPaths,
    required List<String> whitelistedPaths,
  }) {
    final normalizedPath = _normalize(path);
    final blacklisted = _effectivePaths(blacklistedPaths, whitelistedPaths);
    final whitelisted = _effectivePaths(whitelistedPaths, blacklistedPaths);
    final matchingWhitelist = whitelisted
        .where(
          (candidate) =>
              normalizedPath == candidate ||
              normalizedPath.startsWith('$candidate/'),
        )
        .toList(growable: false);
    final hasWhitelistedDescendant =
        isDirectory &&
        whitelisted.any(
          (candidate) => candidate.startsWith('$normalizedPath/'),
        );
    final matchingBlacklist = blacklisted
        .where(
          (candidate) =>
              normalizedPath == candidate ||
              normalizedPath.startsWith('$candidate/'),
        )
        .toList(growable: false);
    final longestWhitelist = matchingWhitelist.isEmpty
        ? 0
        : matchingWhitelist
              .map((path) => path.length)
              .reduce((left, right) => left > right ? left : right);
    final longestBlacklist = matchingBlacklist.isEmpty
        ? 0
        : matchingBlacklist
              .map((path) => path.length)
              .reduce((left, right) => left > right ? left : right);
    final isWhitelisted = longestWhitelist > longestBlacklist;
    if (matchingBlacklist.isNotEmpty &&
        !isWhitelisted &&
        !hasWhitelistedDescendant) {
      return false;
    }

    final hasHiddenSegment = normalizedPath
        .split('/')
        .any((segment) => segment.startsWith('.'));
    if (!showHiddenFiles &&
        hasHiddenSegment &&
        !isWhitelisted &&
        !hasWhitelistedDescendant) {
      return false;
    }
    return true;
  }

  static List<String> _effectivePaths(
    List<String> paths,
    List<String> opposingPaths,
  ) {
    final opposing = opposingPaths.map(_normalize).toSet();
    return [
      for (final path in paths)
        if (!opposing.contains(_normalize(path))) _normalize(path),
    ];
  }

  static String _normalize(String path) =>
      path.replaceAll('\\', '/').replaceFirst(RegExp(r'/+$'), '');
}

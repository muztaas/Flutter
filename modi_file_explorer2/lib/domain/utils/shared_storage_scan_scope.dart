abstract final class SharedStorageScanScope {
  static bool isInsideAndroidFolder(String relativePath) => _segments(
    relativePath,
  ).any((segment) => segment.toLowerCase() == 'android');

  static bool shouldIncludeRelativePath(String relativePath) {
    final segments = _segments(relativePath);
    if (segments.isEmpty || segments.first.toLowerCase() != 'android') {
      return true;
    }
    return segments.length > 1 && segments[1].toLowerCase() == 'media';
  }

  static bool shouldDescendIntoRelativePath(String relativePath) {
    final segments = _segments(relativePath);
    return (segments.length == 1 &&
            segments.first.toLowerCase() == 'android') ||
        shouldIncludeRelativePath(relativePath);
  }

  static List<String> _segments(String path) => path
      .replaceAll('\\', '/')
      .split('/')
      .where((segment) => segment.isNotEmpty)
      .toList(growable: false);
}

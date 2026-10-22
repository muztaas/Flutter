String displayFileName(
  String name, {
  required bool showExtension,
  required bool isDirectory,
}) {
  if (showExtension || isDirectory) return name;
  final dot = name.lastIndexOf('.');
  if (dot <= 0) return name;
  return name.substring(0, dot);
}

String displayFilePath(
  String path, {
  required bool showExtension,
  required bool isDirectory,
}) {
  if (showExtension || isDirectory) return path;
  final normalizedPath = path.replaceAll('\\', '/');
  final separator = normalizedPath.lastIndexOf('/');
  final name = separator < 0
      ? normalizedPath
      : normalizedPath.substring(separator + 1);
  final displayName = displayFileName(
    name,
    showExtension: false,
    isDirectory: false,
  );
  return separator < 0
      ? displayName
      : '${normalizedPath.substring(0, separator + 1)}$displayName';
}

class ArchiveOperationResult {
  const ArchiveOperationResult({
    required this.completed,
    required this.skipped,
    required this.failed,
    required this.cancelled,
    this.messages = const [],
    this.outputPath,
    this.outputSize,
  });

  final int completed;
  final int skipped;
  final int failed;
  final bool cancelled;
  final List<String> messages;
  final String? outputPath;
  final int? outputSize;
}

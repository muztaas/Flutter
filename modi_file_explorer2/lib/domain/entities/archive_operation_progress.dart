class ArchiveOperationProgress {
  const ArchiveOperationProgress({
    required this.operationId,
    required this.completedBytes,
    required this.totalBytes,
    required this.completedEntries,
    required this.totalEntries,
    this.currentEntry,
  });

  final String operationId;
  final int completedBytes;
  final int totalBytes;
  final int completedEntries;
  final int totalEntries;
  final String? currentEntry;

  double get fraction {
    if (totalBytes > 0) {
      return (completedBytes / totalBytes).clamp(0, 1).toDouble();
    }
    if (totalEntries > 0) {
      return (completedEntries / totalEntries).clamp(0, 1).toDouble();
    }
    return 0;
  }
}

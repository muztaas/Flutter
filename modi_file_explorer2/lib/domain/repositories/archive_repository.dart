import '../entities/archive_entry.dart';
import '../entities/archive_operation_progress.dart';
import '../entities/archive_operation_result.dart';

abstract class ArchiveRepository {
  Stream<ArchiveOperationProgress> get progress;

  Future<List<ArchiveEntry>> listEntries({
    required String archivePath,
    String? password,
  });

  Future<int> availableBytes(String path);

  Future<bool> pathExists(String path);

  Future<bool> pathIsDirectory(String path);

  Future<int> estimateCreateBytes({
    required String archivePath,
    required List<String> sourcePaths,
    required bool excludeOutputPath,
  });

  Future<ArchiveOperationResult> extract({
    required String operationId,
    required String archivePath,
    required String destinationPath,
    List<String>? selectedEntries,
    String? password,
    Map<String, String> conflictActions = const {},
  });

  Future<ArchiveOperationResult> create({
    required String operationId,
    required String archivePath,
    required String format,
    required List<String> sourcePaths,
    required String compressionLevel,
    required String conflictAction,
    String? password,
  });

  Future<void> cancel(String operationId);
}

import '../entities/pdf_reading_progress.dart';

abstract class PdfReadingProgressRepository {
  Future<PdfReadingProgress?> get(String volumeId, String relativePath);

  Future<void> save(
    String volumeId,
    String relativePath,
    PdfReadingProgress progress,
  );

  Future<void> remove(String volumeId, String relativePath);

  Future<void> removeTree(String volumeId, String relativePath);

  Future<void> moveTree({
    required String oldVolumeId,
    required String oldRelativePath,
    required String newVolumeId,
    required String newRelativePath,
  });
}

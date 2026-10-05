abstract interface class TextFileRepository {
  Future<String> readText(String path);
  Future<void> writeText(String path, String contents);
}

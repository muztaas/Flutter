import '../entities/detected_file_content.dart';
import '../repositories/file_content_repository.dart';
import '../utils/file_content_sniffer.dart';

class SniffFileContent {
  const SniffFileContent(this._repository);

  static const _prefixLength = 4096;
  final FileContentRepository _repository;

  Future<DetectedFileContent> call(String path) async {
    final prefix = await _repository.readPrefix(path, maxBytes: _prefixLength);
    return const FileContentSniffer().sniff(prefix);
  }
}

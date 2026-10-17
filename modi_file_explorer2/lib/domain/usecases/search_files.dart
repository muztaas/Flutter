import '../entities/search_query.dart';
import '../entities/search_result.dart';
import '../entities/search_scope.dart';
import '../entities/search_folder_candidate.dart';
import '../repositories/search_repository.dart';

class SearchFiles {
  const SearchFiles(this._repository);

  final SearchRepository _repository;

  Stream<SearchResultBatch> call(SearchScope scope, SearchQuery query) =>
      _repository.search(scope, query);

  Future<bool> isResultAvailable(String path) =>
      _repository.isResultAvailable(path);

  Future<List<SearchFolderCandidate>> listFilterFolders(SearchScope scope) =>
      _repository.listFilterFolders(scope);
}

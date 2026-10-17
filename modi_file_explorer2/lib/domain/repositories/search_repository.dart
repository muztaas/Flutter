import '../entities/search_query.dart';
import '../entities/search_result.dart';
import '../entities/search_scope.dart';
import '../entities/search_folder_candidate.dart';

abstract interface class SearchRepository {
  Stream<SearchResultBatch> search(SearchScope scope, SearchQuery query);
  Future<bool> isResultAvailable(String path);
  Future<List<SearchFolderCandidate>> listFilterFolders(SearchScope scope);
}

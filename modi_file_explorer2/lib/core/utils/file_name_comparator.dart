import '../../domain/entities/search_query.dart';
import '../../domain/entities/search_result.dart';

int compareStorageNames(String left, String right) {
  final normalizedLeft = left.toLowerCase();
  final normalizedRight = right.toLowerCase();
  var leftIndex = 0;
  var rightIndex = 0;
  while (leftIndex < normalizedLeft.length &&
      rightIndex < normalizedRight.length) {
    final leftUnit = normalizedLeft.codeUnitAt(leftIndex);
    final rightUnit = normalizedRight.codeUnitAt(rightIndex);
    if (_isDigit(leftUnit) && _isDigit(rightUnit)) {
      var leftEnd = leftIndex;
      var rightEnd = rightIndex;
      while (leftEnd < normalizedLeft.length &&
          _isDigit(normalizedLeft.codeUnitAt(leftEnd))) {
        leftEnd++;
      }
      while (rightEnd < normalizedRight.length &&
          _isDigit(normalizedRight.codeUnitAt(rightEnd))) {
        rightEnd++;
      }
      var leftSignificant = leftIndex;
      var rightSignificant = rightIndex;
      while (leftSignificant < leftEnd &&
          normalizedLeft.codeUnitAt(leftSignificant) == 48) {
        leftSignificant++;
      }
      while (rightSignificant < rightEnd &&
          normalizedRight.codeUnitAt(rightSignificant) == 48) {
        rightSignificant++;
      }
      final leftLength = leftEnd - leftSignificant;
      final rightLength = rightEnd - rightSignificant;
      if (leftLength != rightLength) return leftLength.compareTo(rightLength);
      for (var offset = 0; offset < leftLength; offset++) {
        final digitComparison = normalizedLeft
            .codeUnitAt(leftSignificant + offset)
            .compareTo(normalizedRight.codeUnitAt(rightSignificant + offset));
        if (digitComparison != 0) return digitComparison;
      }
      final runLengthComparison = (leftEnd - leftIndex).compareTo(
        rightEnd - rightIndex,
      );
      if (runLengthComparison != 0) return runLengthComparison;
      leftIndex = leftEnd;
      rightIndex = rightEnd;
      continue;
    }
    if (leftUnit != rightUnit) return leftUnit.compareTo(rightUnit);
    leftIndex++;
    rightIndex++;
  }
  return (normalizedLeft.length - leftIndex).compareTo(
    normalizedRight.length - rightIndex,
  );
}

bool _isDigit(int value) => value >= 48 && value <= 57;

int compareSearchResults(
  String leftName,
  bool leftIsDirectory,
  String rightName,
  bool rightIsDirectory,
) {
  if (leftIsDirectory != rightIsDirectory) {
    return leftIsDirectory ? -1 : 1;
  }
  final byName = compareStorageNames(leftName, rightName);
  return byName != 0 ? byName : leftName.compareTo(rightName);
}

int compareSearchResultItems(
  SearchResult left,
  SearchResult right,
  SearchSortField sortField,
  SearchSortDirection sortDirection, {
  bool foldersFirst = true,
}) {
  if (foldersFirst && left.isDirectory != right.isDirectory) {
    return left.isDirectory ? -1 : 1;
  }
  var comparison = switch (sortField) {
    SearchSortField.name => compareStorageNames(left.name, right.name),
    SearchSortField.modified =>
      (left.modified?.millisecondsSinceEpoch ?? -1).compareTo(
        right.modified?.millisecondsSinceEpoch ?? -1,
      ),
    SearchSortField.size => (left.size ?? -1).compareTo(right.size ?? -1),
  };
  if (comparison == 0) comparison = compareStorageNames(left.name, right.name);
  if (comparison == 0) comparison = left.path.compareTo(right.path);
  return sortDirection == SearchSortDirection.ascending
      ? comparison
      : -comparison;
}

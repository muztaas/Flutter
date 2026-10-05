import '../entities/sort_rule.dart';

SortRule? resolveEffectiveSortRule({
  required Iterable<SortRule> rules,
  required String drivePath,
  required String folderPath,
}) {
  final normalizedDrive = normalizeSortPath(drivePath);
  final normalizedFolder = normalizeSortPath(folderPath);
  final folderRules =
      rules.where((rule) {
        if (rule.scope != SortScope.folder || rule.targetPath == null) {
          return false;
        }
        final target = normalizeSortPath(rule.targetPath!);
        return normalizedFolder == target ||
            (rule.recursive && normalizedFolder.startsWith('$target/'));
      }).toList()..sort(
        (left, right) => normalizeSortPath(
          right.targetPath!,
        ).length.compareTo(normalizeSortPath(left.targetPath!).length),
      );
  if (folderRules.isNotEmpty) return folderRules.first;

  for (final rule in rules) {
    if (rule.scope == SortScope.drive &&
        rule.targetPath != null &&
        normalizeSortPath(rule.targetPath!) == normalizedDrive) {
      return rule;
    }
  }
  for (final rule in rules) {
    if (rule.scope == SortScope.all) return rule;
  }
  return null;
}

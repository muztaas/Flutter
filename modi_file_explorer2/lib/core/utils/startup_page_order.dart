import 'file_name_comparator.dart';
import '../../domain/entities/storage_device.dart';

List<(String, String)> startupPageChoices(
  List<StorageDevice> devices, {
  bool includeDefaultAndHome = true,
}) {
  final externalDevices = devices
      .where((device) => device.id != 'internal')
      .toList()
    ..sort((left, right) => compareStorageNames(left.name, right.name));
  const cardPages = <(String, String)>[
    ('apps', 'Apps'),
    ('archives', 'Archives'),
    ('audio', 'Audio'),
    ('documents', 'Documents'),
    ('downloads', 'Downloads'),
    ('images', 'Images'),
    ('video', 'Videos'),
  ];
  return [
    if (includeDefaultAndHome) ('default', 'Default'),
    if (includeDefaultAndHome) ('home', 'Home'),
    ('internal', 'Internal Storage'),
    for (final device in externalDevices)
      ('drive:${device.id}', device.name),
    ...cardPages,
  ];
}

List<String> orderStartupPages(
  Iterable<String> pageIds,
  List<StorageDevice> devices,
) {
  final order = startupPageChoices(
    devices,
    includeDefaultAndHome: false,
  ).map((choice) => choice.$1).toList();
  final rank = {for (var index = 0; index < order.length; index++) order[index]: index};
  final pages = pageIds.toSet().toList();
  pages.sort((left, right) {
    final leftRank = rank[left];
    final rightRank = rank[right];
    if (leftRank != null && rightRank != null) {
      return leftRank.compareTo(rightRank);
    }
    if (leftRank != null) return -1;
    if (rightRank != null) return 1;
    return compareStorageNames(left, right);
  });
  return pages;
}

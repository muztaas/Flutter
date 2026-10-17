import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/utils/file_name_comparator.dart';
import '../../../domain/entities/file_type_category.dart';
import '../../../domain/entities/search_query.dart';
import '../../../domain/entities/search_folder_candidate.dart';
import '../../../domain/entities/search_result.dart';
import '../../../domain/entities/search_scope.dart';
import '../../../domain/entities/storage_device.dart';
import '../../../domain/repositories/file_type_categories_repository.dart';
import '../../../domain/repositories/search_repository.dart';
import '../../../domain/repositories/storage_repository.dart';

const int maximumSearchResults = 1000;

class AndroidSearchRepository implements SearchRepository {
  AndroidSearchRepository(this._storageRepository, this._categoriesRepository);

  final StorageRepository _storageRepository;
  final FileTypeCategoriesRepository _categoriesRepository;

  @override
  Future<bool> isResultAvailable(String path) async {
    final type = await FileSystemEntity.type(path, followLinks: false);
    return type == FileSystemEntityType.file ||
        type == FileSystemEntityType.directory;
  }

  @override
  Future<List<SearchFolderCandidate>> listFilterFolders(
    SearchScope scope,
  ) async {
    final devices = await _storageRepository.listStorageDevices();
    if (scope.driveId == null) {
      final candidates = <SearchFolderCandidate>[];
      for (final device in devices) {
        try {
          if (await FileSystemEntity.type(device.path, followLinks: false) !=
              FileSystemEntityType.directory) {
            continue;
          }
        } on FileSystemException {
          continue;
        }
        candidates.add(
          SearchFolderCandidate(
            id: device.id,
            name: device.name,
            path: device.path,
          ),
        );
      }
      candidates.sort(
        (left, right) => compareStorageNames(left.name, right.name),
      );
      return candidates;
    }

    final device = devices
        .where((candidate) => candidate.id == scope.driveId)
        .firstOrNull;
    if (device == null) return const [];
    final relativeSegments = _relativeSegments(scope.relativePath);
    if (relativeSegments == null) return const [];
    final currentPath = _joinPath(device.path, relativeSegments);
    final preferences = await _getPreferences();
    if (!preferences['showNomediaFiles']! &&
        (await File('$currentPath${Platform.pathSeparator}.nomedia').exists() ||
            await _hasNoMediaAncestor(currentPath, device.path))) {
      return const [];
    }

    final categories =
        await _categoriesRepository.load() ?? FileTypeCategory.defaults;
    final categoryExtensions = switch (scope.category) {
      SearchCategory.images => _extensionsFor('Image', categories).toSet(),
      SearchCategory.documents => _extensionsFor(
        'Documents',
        categories,
      ).toSet(),
      null => const <String>{},
    };
    final candidates = <SearchFolderCandidate>[];
    await for (final entity in Directory(
      currentPath,
    ).list(followLinks: false)) {
      if (entity is! Directory) continue;
      final name = _searchEntryName(entity.path);
      if (name.startsWith('.') && !preferences['showHiddenFiles']!) {
        continue;
      }
      if (scope.category != null &&
          !await _containsCategoryFile(
            entity,
            categoryExtensions,
            showHiddenFiles: preferences['showHiddenFiles']!,
            showNomediaFiles: preferences['showNomediaFiles']!,
          )) {
        continue;
      }
      final relative = _relativeSegmentsFromRoot(
        device.path,
        entity.path,
      ).join('/');
      candidates.add(
        SearchFolderCandidate(
          id: _folderIdentifier(device.id, relative),
          name: name,
          path: entity.path,
        ),
      );
    }
    candidates.sort(
      (left, right) => compareStorageNames(left.name, right.name),
    );
    return candidates;
  }

  @override
  Stream<SearchResultBatch> search(
    SearchScope scope,
    SearchQuery query,
  ) async* {
    if (query.text.isEmpty && !query.hasActiveFilters) {
      yield const SearchResultBatch(results: [], isComplete: true);
      return;
    }
    final devices = await _storageRepository.listStorageDevices();
    final preferences = await _getPreferences();
    final roots = await _rootsForScope(scope, devices, query);
    if (roots.isEmpty) {
      if (query.includedFolders.isNotEmpty ||
          (scope.driveId == null && query.excludedFolders.isNotEmpty)) {
        yield const SearchResultBatch(results: [], isComplete: true);
        return;
      }
      throw StateError('The storage location for this search is unavailable.');
    }
    final categories =
        await _categoriesRepository.load() ?? FileTypeCategory.defaults;
    final extensions = switch (scope.category) {
      SearchCategory.images => _extensionsFor('Image', categories),
      SearchCategory.documents => _extensionsFor('Documents', categories),
      null => const <String>[],
    };
    yield* _searchInIsolate({
      'roots': roots,
      'query': query.text,
      'caseSensitive': query.caseSensitive,
      'type': query.type.index,
      'extensions': query.extensions.toList(),
      'modifiedFrom': query.modifiedFrom?.millisecondsSinceEpoch,
      'modifiedTo': query.modifiedTo == null
          ? null
          : DateTime(
                  query.modifiedTo!.year,
                  query.modifiedTo!.month,
                  query.modifiedTo!.day + 1,
                ).millisecondsSinceEpoch -
                1,
      'minimumSize': query.minimumSize,
      'maximumSize': query.maximumSize,
      'sortField': query.sortField.index,
      'sortDirection': query.sortDirection.index,
      'foldersFirst': query.foldersFirst,
      'excludedFolders': query.excludedFolders.toList(),
      'includedFolders': query.includedFolders.toList(),
      'categoryExtensions': extensions,
      'categoryOnly': scope.category != null,
      'showHiddenFiles': preferences['showHiddenFiles'],
      'showNomediaFiles': preferences['showNomediaFiles'],
      'showFolderItemCount': preferences['showFolderItemCount'],
      'showFileSize': preferences['showFileSize'],
      'showModifiedDate': preferences['showModifiedDate'],
      'showModifiedTime': preferences['showModifiedTime'],
      'maximumResults': maximumSearchResults,
    });
  }

  Future<List<Map<String, String>>> _rootsForScope(
    SearchScope scope,
    List<StorageDevice> devices,
    SearchQuery query,
  ) async {
    if (scope.driveId == null) {
      return devices
          .where((device) => !query.excludedFolders.contains(device.id))
          .where(
            (device) =>
                query.includedFolders.isEmpty ||
                query.includedFolders.contains(device.id),
          )
          .map(
            (device) => {
              'root': device.path,
              'start': device.path,
              'driveId': device.id,
              'relativeStart': '',
            },
          )
          .toList();
    }
    final device = devices
        .where((candidate) => candidate.id == scope.driveId)
        .firstOrNull;
    if (device == null) return const [];
    final relativeSegments = _relativeSegments(scope.relativePath);
    if (relativeSegments == null) return const [];
    final start = _joinPath(device.path, relativeSegments);
    final normalizedRoot = _normalizeSearchPath(device.path);
    final normalizedStart = _normalizeSearchPath(start);
    if (normalizedStart != normalizedRoot &&
        !normalizedStart.startsWith('$normalizedRoot/')) {
      return const [];
    }
    if (query.includedFolders.isNotEmpty) {
      final candidates = await listFilterFolders(scope);
      return candidates
          .where((candidate) => query.includedFolders.contains(candidate.id))
          .where((candidate) => !query.excludedFolders.contains(candidate.id))
          .map(
            (candidate) => {
              'root': device.path,
              'start': candidate.path,
              'driveId': device.id,
              'relativeStart': _relativeSegmentsFromRoot(
                device.path,
                candidate.path,
              ).join('/'),
            },
          )
          .toList();
    }
    return [
      {
        'root': device.path,
        'start': start,
        'driveId': device.id,
        'relativeStart': relativeSegments.join('/'),
      },
    ];
  }

  List<String>? _relativeSegments(String path) {
    final segments = path
        .replaceAll('\\', '/')
        .split('/')
        .where((part) => part.isNotEmpty)
        .toList();
    return segments.any((part) => part == '.' || part == '..')
        ? null
        : segments;
  }

  List<String> _relativeSegmentsFromRoot(String root, String path) {
    final normalizedRoot = _normalizeSearchPath(root);
    final normalizedPath = _normalizeSearchPath(path);
    if (normalizedPath == normalizedRoot) return const [];
    if (!normalizedPath.startsWith('$normalizedRoot/')) return const [];
    return normalizedPath
        .substring(normalizedRoot.length + 1)
        .split('/')
        .where((part) => part.isNotEmpty)
        .toList();
  }

  String _joinPath(String root, List<String> segments) => segments.isEmpty
      ? root
      : '$root${Platform.pathSeparator}${segments.join(Platform.pathSeparator)}';

  String _folderIdentifier(String driveId, String relativePath) {
    final relative = relativePath
        .replaceAll('\\', '/')
        .replaceAll(RegExp(r'^/+|/+$'), '');
    return relative.isEmpty ? driveId : '$driveId|$relative';
  }

  Future<bool> _containsCategoryFile(
    Directory directory,
    Set<String> extensions, {
    required bool showHiddenFiles,
    required bool showNomediaFiles,
  }) async {
    final pending = <Directory>[directory];
    while (pending.isNotEmpty) {
      final current = pending.removeLast();
      if (!showNomediaFiles &&
          await File(
            '${current.path}${Platform.pathSeparator}.nomedia',
          ).exists()) {
        continue;
      }
      try {
        await for (final entity in current.list(followLinks: false)) {
          if (entity is Link) continue;
          final name = _searchEntryName(entity.path);
          if (name.startsWith('.') && !showHiddenFiles) continue;
          if (entity is File && extensions.contains(_searchExtension(name))) {
            return true;
          }
          if (entity is Directory) pending.add(entity);
        }
      } on FileSystemException {
        continue;
      }
    }
    return false;
  }

  List<String> _extensionsFor(
    String categoryName,
    List<FileTypeCategory> categories,
  ) {
    return categories
            .where((category) => category.name == categoryName)
            .firstOrNull
            ?.extensions
            .map((extension) => FileTypeCategory.normalizeExtension(extension))
            .where((extension) => extension.isNotEmpty)
            .toList() ??
        const [];
  }

  Future<Map<String, bool>> _getPreferences() async {
    final preferences = await SharedPreferences.getInstance();
    return {
      'showHiddenFiles':
          preferences.getBool('settings.showHiddenFiles') ?? false,
      'showNomediaFiles':
          preferences.getBool('settings.showNomediaFiles') ?? true,
      'showFolderItemCount':
          preferences.getBool('settings.showFolderItemCount') ?? false,
      'showFileSize': preferences.getBool('settings.showFileSize') ?? false,
      'showModifiedDate':
          preferences.getBool('settings.showModifiedDate') ?? false,
      'showModifiedTime':
          preferences.getBool('settings.showModifiedTime') ?? false,
    };
  }
}

Stream<SearchResultBatch> _searchInIsolate(Map<String, Object?> arguments) {
  late final StreamController<SearchResultBatch> controller;
  Isolate? isolate;
  ReceivePort? messages;
  ReceivePort? exits;
  ReceivePort? errors;
  StreamSubscription<Object?>? messageSubscription;
  StreamSubscription<Object?>? exitSubscription;
  StreamSubscription<Object?>? errorSubscription;
  var completed = false;
  var failureSent = false;
  var cancelled = false;

  Future<void> closePorts() async {
    await messageSubscription?.cancel();
    await exitSubscription?.cancel();
    await errorSubscription?.cancel();
    messages?.close();
    exits?.close();
    errors?.close();
  }

  controller = StreamController<SearchResultBatch>(
    onListen: () async {
      messages = ReceivePort();
      exits = ReceivePort();
      errors = ReceivePort();
      messageSubscription = messages!.listen((message) {
        if (message is! Map) return;
        if (message['error'] is String) {
          failureSent = true;
          controller.addError(StateError(message['error'] as String));
          return;
        }
        final rawResults = message['results'];
        final results = rawResults is List
            ? rawResults
                  .whereType<Map>()
                  .map(
                    (item) => SearchResult(
                      path: item['path'] as String,
                      name: item['name'] as String,
                      containingPath: item['containingPath'] as String,
                      isDirectory: item['isDirectory'] as bool,
                      size: item['size'] as int?,
                      itemCount: item['itemCount'] as int?,
                      modified: item['modified'] == null
                          ? null
                          : DateTime.fromMillisecondsSinceEpoch(
                              item['modified'] as int,
                            ),
                    ),
                  )
                  .toList()
            : const <SearchResult>[];
        completed = message['isComplete'] == true;
        controller.add(
          SearchResultBatch(
            results: results,
            isComplete: completed,
            limitReached: message['limitReached'] == true,
            replacesResults: message['replacesResults'] == true,
          ),
        );
        if (completed) {
          controller.close();
        }
      });
      exitSubscription = exits!.listen((_) {
        if (!completed && !failureSent && !controller.isClosed) {
          controller.addError(
            StateError('The search worker stopped before completing.'),
          );
          controller.close();
        }
        unawaited(closePorts());
      });
      errorSubscription = errors!.listen((error) {
        if (controller.isClosed) return;
        failureSent = true;
        controller.addError(
          StateError('The search worker failed: ${error.toString()}'),
        );
        controller.close();
      });
      arguments['sendPort'] = messages!.sendPort;
      try {
        isolate = await Isolate.spawn<Map<String, Object?>>(
          _searchWorker,
          arguments,
          onExit: exits!.sendPort,
          onError: errors!.sendPort,
        );
        if (cancelled) isolate?.kill(priority: Isolate.immediate);
      } catch (error, stackTrace) {
        if (!controller.isClosed) {
          controller.addError(error, stackTrace);
          await controller.close();
        }
        await closePorts();
      }
    },
    onCancel: () async {
      cancelled = true;
      isolate?.kill(priority: Isolate.immediate);
      await closePorts();
    },
  );
  return controller.stream;
}

@pragma('vm:entry-point')
Future<void> _searchWorker(Map<String, Object?> arguments) async {
  final sendPort = arguments['sendPort']! as SendPort;
  final roots = (arguments['roots']! as List)
      .whereType<Map>()
      .map(
        (root) => (
          root: root['root']! as String,
          start: root['start']! as String,
          driveId: root['driveId']! as String,
          relativeStart: root['relativeStart']! as String,
        ),
      )
      .toList();
  final rawQuery = arguments['query']! as String;
  final caseSensitive = arguments['caseSensitive']! as bool;
  final query = caseSensitive ? rawQuery : rawQuery.toLowerCase();
  final itemType = arguments['type']! as int;
  final userExtensions = (arguments['extensions']! as List)
      .whereType<String>()
      .toSet();
  final modifiedFrom = arguments['modifiedFrom'] as int?;
  final modifiedTo = arguments['modifiedTo'] as int?;
  final minimumSize = arguments['minimumSize'] as int?;
  final maximumSize = arguments['maximumSize'] as int?;
  final sortField = arguments['sortField']! as int;
  final sortDirection = arguments['sortDirection']! as int;
  final foldersFirst = arguments['foldersFirst']! as bool;
  final excludedFolders = (arguments['excludedFolders']! as List)
      .whereType<String>()
      .toSet();
  final extensions = (arguments['categoryExtensions']! as List)
      .whereType<String>()
      .toSet();
  final categoryOnly = arguments['categoryOnly']! as bool;
  final showHiddenFiles = arguments['showHiddenFiles']! as bool;
  final showNomediaFiles = arguments['showNomediaFiles']! as bool;
  final showFolderItemCount = arguments['showFolderItemCount']! as bool;
  final showFileSize = arguments['showFileSize']! as bool;
  final showModifiedDate = arguments['showModifiedDate']! as bool;
  final showModifiedTime = arguments['showModifiedTime']! as bool;
  final maximumResults = arguments['maximumResults']! as int;
  final pending =
      <
        ({
          String root,
          String driveId,
          String relativeStart,
          Directory directory,
          bool insideNoMedia,
        })
      >[];
  for (final root in roots) {
    final insideNoMedia =
        !showNomediaFiles && await _hasNoMediaAncestor(root.start, root.root);
    pending.add((
      root: root.root,
      driveId: root.driveId,
      relativeStart: root.relativeStart,
      directory: Directory(root.start),
      insideNoMedia: insideNoMedia,
    ));
  }
  final matches = <Map<String, Object?>>[];
  final visitedPaths = <String>{};
  final stopwatch = Stopwatch()..start();
  var resultCount = 0;
  var lastFlushedCount = 0;
  var limitReached = false;

  void flush({bool isComplete = false}) {
    if (matches.isEmpty && !isComplete) return;
    matches.sort(
      (left, right) => _compareWorkerResults(
        left,
        right,
        sortField,
        sortDirection,
        foldersFirst,
      ),
    );
    sendPort.send({
      'results': List<Map<String, Object?>>.of(matches),
      'isComplete': isComplete,
      'limitReached': limitReached,
      'replacesResults': true,
    });
    stopwatch
      ..reset()
      ..start();
    lastFlushedCount = resultCount;
  }

  try {
    while (pending.isNotEmpty) {
      final current = pending.removeLast();
      final normalizedCurrent = _normalizeSearchPath(current.directory.path);
      if (!visitedPaths.add(normalizedCurrent)) continue;
      if (current.insideNoMedia ||
          (!showNomediaFiles &&
              await File(
                '${current.directory.path}${Platform.pathSeparator}.nomedia',
              ).exists())) {
        continue;
      }

      try {
        if (await FileSystemEntity.type(
              current.directory.path,
              followLinks: false,
            ) !=
            FileSystemEntityType.directory) {
          continue;
        }
        await for (final entity in current.directory.list(followLinks: false)) {
          if (entity is Link) continue;
          final name = _searchEntryName(entity.path);
          if (name.isEmpty) continue;
          final isDirectory = entity is Directory;
          if (isDirectory &&
              excludedFolders.contains(
                _folderIdentifier(
                  current.driveId,
                  _relativeSegmentsFromRoot(
                    current.root,
                    entity.path,
                  ).join('/'),
                ),
              )) {
            continue;
          }
          if (name.startsWith('.') && !showHiddenFiles) {
            continue;
          }
          if (isDirectory && itemType == SearchItemType.filesOnly.index) {
            pending.add((
              root: current.root,
              driveId: current.driveId,
              relativeStart: current.relativeStart,
              directory: entity,
              insideNoMedia: false,
            ));
            continue;
          }
          if (!isDirectory && itemType == SearchItemType.foldersOnly.index) {
            continue;
          }
          if (categoryOnly && isDirectory) {
            pending.add((
              root: current.root,
              driveId: current.driveId,
              relativeStart: current.relativeStart,
              directory: entity,
              insideNoMedia: false,
            ));
            continue;
          }
          if (isDirectory &&
              (userExtensions.isNotEmpty ||
                  minimumSize != null ||
                  maximumSize != null)) {
            pending.add((
              root: current.root,
              driveId: current.driveId,
              relativeStart: current.relativeStart,
              directory: entity,
              insideNoMedia: false,
            ));
            continue;
          }
          if (entity is File &&
              categoryOnly &&
              !extensions.contains(_searchExtension(name))) {
            continue;
          }
          if (entity is File &&
              userExtensions.isNotEmpty &&
              !userExtensions.contains(_searchExtension(name))) {
            continue;
          }
          if (!_matchesSearch(name, query, caseSensitive)) {
            if (entity is Directory) {
              pending.add((
                root: current.root,
                driveId: current.driveId,
                relativeStart: current.relativeStart,
                directory: entity,
                insideNoMedia: false,
              ));
            }
            continue;
          }
          if (entity is Directory) {
            final needsModified =
                modifiedFrom != null ||
                modifiedTo != null ||
                sortField == SearchSortField.modified.index ||
                showModifiedDate ||
                showModifiedTime;
            int? modified;
            if (needsModified) {
              try {
                modified =
                    (await entity.stat()).modified.millisecondsSinceEpoch;
              } on FileSystemException {
                modified = null;
              }
            }
            final dateMatches =
                (modifiedFrom == null ||
                    (modified != null && modified >= modifiedFrom)) &&
                (modifiedTo == null ||
                    (modified != null && modified <= modifiedTo));
            if (dateMatches) {
              final itemCount = showFolderItemCount
                  ? await _visibleChildCount(
                      entity,
                      showHiddenFiles: showHiddenFiles,
                      showNomediaFiles: showNomediaFiles,
                    )
                  : null;
              _retainSearchMatch(
                matches,
                {
                  'path': entity.path,
                  'name': name,
                  'containingPath': current.directory.path,
                  'isDirectory': true,
                  'itemCount': itemCount,
                  'modified': modified,
                },
                maximumResults,
                sortField,
                sortDirection,
                foldersFirst,
              );
              resultCount++;
            }
            pending.add((
              root: current.root,
              driveId: current.driveId,
              relativeStart: current.relativeStart,
              directory: entity,
              insideNoMedia: false,
            ));
          } else if (entity is File) {
            try {
              final needsModified =
                  modifiedFrom != null ||
                  modifiedTo != null ||
                  sortField == SearchSortField.modified.index ||
                  showModifiedDate ||
                  showModifiedTime;
              final needsSize =
                  minimumSize != null ||
                  maximumSize != null ||
                  sortField == SearchSortField.size.index ||
                  showFileSize;
              FileStat? stat;
              if (needsModified || needsSize) {
                try {
                  stat = await entity.stat();
                } on FileSystemException {
                  stat = null;
                }
              }
              final modified = needsModified
                  ? stat?.modified.millisecondsSinceEpoch
                  : null;
              final size = needsSize ? stat?.size : null;
              final dateMatches =
                  (modifiedFrom == null ||
                      (modified != null && modified >= modifiedFrom)) &&
                  (modifiedTo == null ||
                      (modified != null && modified <= modifiedTo));
              final sizeMatches =
                  (minimumSize == null ||
                      (size != null && size >= minimumSize)) &&
                  (maximumSize == null ||
                      (size != null && size <= maximumSize));
              if (!dateMatches || !sizeMatches) continue;
              _retainSearchMatch(
                matches,
                {
                  'path': entity.path,
                  'name': name,
                  'containingPath': current.directory.path,
                  'isDirectory': false,
                  'size': ?size,
                  'modified': ?modified,
                },
                maximumResults,
                sortField,
                sortDirection,
                foldersFirst,
              );
            } on FileSystemException {
              continue;
            }
            resultCount++;
          }
          if (resultCount >= maximumResults) {
            limitReached = true;
          }
          if (resultCount - lastFlushedCount >= 50 ||
              (stopwatch.elapsedMilliseconds >= 200 &&
                  resultCount > lastFlushedCount)) {
            flush();
          }
        }
      } on FileSystemException {
        // Unreadable folders are skipped; their siblings continue to be scanned.
      }
    }
    flush(isComplete: true);
  } catch (error) {
    sendPort.send({'error': error.toString()});
  }
}

bool _matchesSearch(String name, String query, bool caseSensitive) {
  if (query.isEmpty) return true;
  final candidate = caseSensitive ? name : name.toLowerCase();
  return candidate.contains(query);
}

void _retainSearchMatch(
  List<Map<String, Object?>> matches,
  Map<String, Object?> candidate,
  int maximumResults,
  int sortField,
  int sortDirection,
  bool foldersFirst,
) {
  var low = 0;
  var high = matches.length;
  while (low < high) {
    final middle = (low + high) ~/ 2;
    final comparison = _compareWorkerResults(
      candidate,
      matches[middle],
      sortField,
      sortDirection,
      foldersFirst,
    );
    if (comparison < 0) {
      high = middle;
    } else {
      low = middle + 1;
    }
  }
  if (low >= maximumResults) return;
  matches.insert(low, candidate);
  if (matches.length > maximumResults) matches.removeLast();
}

int _compareWorkerResults(
  Map<String, Object?> left,
  Map<String, Object?> right,
  int sortField,
  int sortDirection,
  bool foldersFirst,
) {
  final leftDirectory = left['isDirectory']! as bool;
  final rightDirectory = right['isDirectory']! as bool;
  if (foldersFirst && leftDirectory != rightDirectory) {
    return leftDirectory ? -1 : 1;
  }
  final leftName = left['name']! as String;
  final rightName = right['name']! as String;
  final leftDate = left['modified'] as int?;
  final rightDate = right['modified'] as int?;
  final leftSize = left['size'] as int?;
  final rightSize = right['size'] as int?;
  var comparison = switch (sortField) {
    1 => (leftDate ?? -1).compareTo(rightDate ?? -1),
    2 => (leftSize ?? -1).compareTo(rightSize ?? -1),
    _ => compareStorageNames(leftName, rightName),
  };
  if (comparison == 0) comparison = compareStorageNames(leftName, rightName);
  if (comparison == 0) {
    comparison = (left['path']! as String).compareTo(right['path']! as String);
  }
  return sortDirection == SearchSortDirection.descending.index
      ? -comparison
      : comparison;
}

String _searchEntryName(String path) {
  final normalized = path
      .replaceAll('\\', '/')
      .replaceFirst(RegExp(r'/+$'), '');
  return normalized.substring(normalized.lastIndexOf('/') + 1);
}

String _searchExtension(String name) {
  final index = name.lastIndexOf('.');
  return index < 0 ? '' : name.substring(index).toLowerCase();
}

Future<int> _visibleChildCount(
  Directory directory, {
  required bool showHiddenFiles,
  required bool showNomediaFiles,
}) async {
  var count = 0;
  try {
    await for (final child in directory.list(followLinks: false)) {
      final name = _searchEntryName(child.path);
      if (!showHiddenFiles && name.startsWith('.')) {
        continue;
      }
      count++;
    }
  } on FileSystemException {
    return 0;
  }
  return count;
}

String _normalizeSearchPath(String path) =>
    path.replaceAll('\\', '/').replaceFirst(RegExp(r'/+$'), '');

List<String> _relativeSegmentsFromRoot(String root, String path) {
  final normalizedRoot = _normalizeSearchPath(root);
  final normalizedPath = _normalizeSearchPath(path);
  if (normalizedPath == normalizedRoot) return const [];
  if (!normalizedPath.startsWith('$normalizedRoot/')) return const [];
  return normalizedPath
      .substring(normalizedRoot.length + 1)
      .split('/')
      .where((part) => part.isNotEmpty)
      .toList();
}

String _folderIdentifier(String driveId, String relativePath) {
  final relative = relativePath
      .replaceAll('\\', '/')
      .replaceAll(RegExp(r'^/+|/+$'), '');
  return relative.isEmpty ? driveId : '$driveId|$relative';
}

Future<bool> _hasNoMediaAncestor(String path, String root) async {
  final normalizedRoot = _normalizeSearchPath(root);
  if (_normalizeSearchPath(path) == normalizedRoot) return false;
  var current = Directory(path).parent;
  while (true) {
    if (await File(
      '${current.path}${Platform.pathSeparator}.nomedia',
    ).exists()) {
      return true;
    }
    if (_normalizeSearchPath(current.path) == normalizedRoot) return false;
    final parent = current.parent;
    if (_normalizeSearchPath(parent.path) ==
        _normalizeSearchPath(current.path)) {
      return false;
    }
    current = parent;
  }
}

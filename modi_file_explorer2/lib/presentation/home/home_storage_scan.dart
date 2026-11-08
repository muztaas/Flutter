import 'dart:io';

import '../../domain/utils/file_visibility.dart';
import '../../domain/utils/shared_storage_scan_scope.dart';
import '../../domain/utils/storage_display_name.dart';

Future<Map<String, Object?>> scanHomeStorageDrive(
  Map<String, Object?> arguments,
) async {
  final driveId = arguments['driveId']! as String;
  final root = Directory(arguments['rootPath']! as String);
  final refreshRecent = arguments['refreshRecent']! as bool;
  final showHiddenFiles = arguments['showHiddenFiles']! as bool;
  final showNomediaFiles = arguments['showNomediaFiles']! as bool;
  final hideAndroidFolders = arguments['hideAndroidFolders']! as bool;
  final blacklistedPaths = (arguments['blacklistedPaths'] as List).cast<String>();
  final whitelistedPaths = (arguments['whitelistedPaths'] as List).cast<String>();
  final rawExtensions = arguments['extensions']! as Map;
  Set<String> extensionsFor(String category) =>
      ((rawExtensions[category] as List?) ?? const <String>[])
          .cast<String>()
          .toSet();

  final documentExtensions = extensionsFor('Documents');
  final imageExtensions = extensionsFor('Image');
  final archiveExtensions = extensionsFor('Archives');
  final videoExtensions = extensionsFor('Video');
  final audioExtensions = extensionsFor('Audio');
  final categoryBytes = <String, int?>{
    'Downloads': null,
    'Documents': 0,
    'Images': 0,
    'Videos': 0,
    'Audio': 0,
    'Archives': 0,
  };
  final weeklyRecent = <Map<String, Object?>>[];
  final overallRecent = <Map<String, Object?>>[];
  final directoryModifiedMilliseconds = <String, int>{};
  var directoryStampsComplete = true;
  String? downloadsRelativePath;
  var downloadsBytes = 0;
  final cutoff = DateTime.now().subtract(const Duration(days: 7));
  final pending =
      <({
        Directory directory,
        String relative,
        bool categoryNoMedia,
        bool insideNomedia,
        bool categoryVisible,
      })>[
        (
          directory: root,
          relative: '',
          categoryNoMedia: false,
          insideNomedia: false,
          categoryVisible: true,
        ),
      ];

  void insertRecent(List<Map<String, Object?>> files, Map<String, Object?> item) {
    final modified = item['modified']! as int;
    var low = 0;
    var high = files.length;
    while (low < high) {
      final middle = (low + high) ~/ 2;
      if ((files[middle]['modified']! as int) < modified) {
        high = middle;
      } else {
        low = middle + 1;
      }
    }
    files.insert(low, item);
    if (files.length > 1000) files.removeLast();
  }

  while (pending.isNotEmpty) {
    final current = pending.removeLast();
    try {
      if (directoryModifiedMilliseconds.length < 5000) {
        directoryModifiedMilliseconds[current.directory.path] =
            (await current.directory.stat()).modified.millisecondsSinceEpoch;
      } else {
        directoryStampsComplete = false;
      }
    } on FileSystemException {
      directoryStampsComplete = false;
    }

    List<FileSystemEntity> entries;
    try {
      entries = await current.directory.list(followLinks: false).toList();
    } on FileSystemException {
      directoryStampsComplete = false;
      continue;
    }

    if (current.relative.isEmpty) {
      final downloadFolders = entries.whereType<Directory>().where((entry) {
        final name = storageDisplayName(path: entry.path).toLowerCase();
        return name == 'download' || name == 'downloads';
      }).toList();
      downloadFolders.sort((left, right) {
        final leftName = storageDisplayName(path: left.path).toLowerCase();
        final rightName = storageDisplayName(path: right.path).toLowerCase();
        if (leftName == 'download' && rightName != 'download') return -1;
        if (rightName == 'download' && leftName != 'download') return 1;
        return 0;
      });
      if (downloadFolders.isNotEmpty) {
        downloadsRelativePath = storageDisplayName(
          path: downloadFolders.first.path,
        );
        categoryBytes['Downloads'] = 0;
      }
    }

    for (final entry in entries) {
      final name = storageDisplayName(path: entry.path);
      final relative = current.relative.isEmpty
          ? name
          : '${current.relative}/$name';
      if (entry is Directory) {
        if (!SharedStorageScanScope.shouldDescendIntoRelativePath(relative) ||
            !FileVisibility.shouldShow(
              path: entry.path,
              isDirectory: true,
              showHiddenFiles: showHiddenFiles,
              blacklistedPaths: blacklistedPaths,
              whitelistedPaths: whitelistedPaths,
            )) {
          continue;
        }
        final hasNoMedia = await File(
          '${entry.path}${Platform.pathSeparator}.nomedia',
        ).exists();
        pending.add((
          directory: entry,
          relative: relative,
          categoryNoMedia:
              !showNomediaFiles && (current.categoryNoMedia || hasNoMedia),
          insideNomedia: current.insideNomedia || hasNoMedia,
          categoryVisible: current.categoryVisible,
        ));
        continue;
      }
      if (entry is! File ||
          !SharedStorageScanScope.shouldIncludeRelativePath(relative)) {
        continue;
      }

      FileStat stat;
      try {
        stat = await entry.stat();
      } on FileSystemException {
        continue;
      }
      final extension = _extension(name);
      final inAndroidFolder =
          SharedStorageScanScope.isInsideAndroidFolder(relative);
      final allowedByLists = FileVisibility.shouldShow(
        path: entry.path,
        isDirectory: false,
        showHiddenFiles: showHiddenFiles,
        blacklistedPaths: blacklistedPaths,
        whitelistedPaths: whitelistedPaths,
      );
      final includeCategoryFile =
          current.categoryVisible &&
          allowedByLists &&
          !current.categoryNoMedia &&
          (!hideAndroidFolders || !inAndroidFolder);

      if (downloadsRelativePath != null &&
          FileVisibility.shouldShow(
            path: entry.path,
            isDirectory: false,
            showHiddenFiles: true,
            blacklistedPaths: blacklistedPaths,
            whitelistedPaths: whitelistedPaths,
          ) &&
          (relative.startsWith('$downloadsRelativePath/') ||
              relative == downloadsRelativePath)) {
        downloadsBytes += stat.size;
        categoryBytes['Downloads'] = downloadsBytes;
      }
      if (includeCategoryFile && documentExtensions.contains(extension)) {
        categoryBytes['Documents'] = categoryBytes['Documents']! + stat.size;
      }
      if (includeCategoryFile && imageExtensions.contains(extension)) {
        categoryBytes['Images'] = categoryBytes['Images']! + stat.size;
      }
      if (includeCategoryFile && videoExtensions.contains(extension)) {
        categoryBytes['Videos'] = categoryBytes['Videos']! + stat.size;
      }
      if (includeCategoryFile && audioExtensions.contains(extension)) {
        categoryBytes['Audio'] = categoryBytes['Audio']! + stat.size;
      }
      if (includeCategoryFile && archiveExtensions.contains(extension)) {
        categoryBytes['Archives'] = categoryBytes['Archives']! + stat.size;
      }

      final isHidden = relative.split('/').any((segment) => segment.startsWith('.'));
      final modified = stat.modified.millisecondsSinceEpoch;
      final video = videoExtensions.contains(extension)
          ? {
              'driveId': driveId,
              'relativePath': relative,
              'name': name,
              'extension': extension,
              'size': stat.size,
              'modified': modified,
              'isHidden': isHidden,
              'isInsideNomedia': current.insideNomedia,
            }
          : null;
      final recent = <String, Object?>{
        'path': entry.path,
        'name': name,
        'driveId': driveId,
        'modified': modified,
        'relativePath': relative,
        'video': video,
        'isHidden': isHidden,
        'isInsideNomedia': current.insideNomedia,
        'isInsideAndroidFolder': inAndroidFolder,
      };
      if (refreshRecent) {
        insertRecent(overallRecent, recent);
        if (!stat.modified.isBefore(cutoff)) {
          insertRecent(weeklyRecent, recent);
        }
      }
    }
  }

  return {
    'weeklyRecent': weeklyRecent,
    'overallRecent': overallRecent,
    'categoryBytes': categoryBytes,
    'directoryModifiedMilliseconds': directoryModifiedMilliseconds,
    'directoryStampsComplete': directoryStampsComplete,
  };
}

Future<Map<String, Object?>> validateHomeDirectoryStamps(
  Map<String, Object?> arguments,
) async {
  final stamps = Map<String, int>.from(
    (arguments['stamps']! as Map).cast<String, int>(),
  );
  final changed = <String>[];
  final missing = <String>[];
  for (final entry in stamps.entries) {
    try {
      final modified = (await Directory(entry.key).stat())
          .modified
          .millisecondsSinceEpoch;
      if (modified != entry.value) changed.add(entry.key);
    } on FileSystemException {
      missing.add(entry.key);
    }
  }
  return {'changed': changed, 'missing': missing};
}

String _extension(String name) {
  final dot = name.lastIndexOf('.');
  return dot <= 0 ? '' : name.substring(dot).toLowerCase();
}

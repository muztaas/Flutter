import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'file_change_notifier.dart';

class CachedListingEntry {
  const CachedListingEntry({
    required this.path,
    required this.isDirectory,
    required this.size,
    required this.modifiedMilliseconds,
  });

  final String path;
  final bool isDirectory;
  final int size;
  final int modifiedMilliseconds;

  Map<String, Object?> toJson() => {
    'path': path,
    'directory': isDirectory,
    'size': size,
    'modified': modifiedMilliseconds,
  };

  factory CachedListingEntry.fromJson(Map raw) => CachedListingEntry(
    path: raw['path']! as String,
    isDirectory: raw['directory']! as bool,
    size: raw['size'] as int? ?? 0,
    modifiedMilliseconds: raw['modified'] as int? ?? 0,
  );
}

class CachedFolderListing {
  const CachedFolderListing({
    required this.volumeId,
    required this.path,
    required this.directoryModifiedMilliseconds,
    required this.entries,
    required this.isStale,
    required this.isComplete,
  });

  final String volumeId;
  final String path;
  final int directoryModifiedMilliseconds;
  final List<CachedListingEntry> entries;
  final bool isStale;
  final bool isComplete;
}

class FilesystemCache {
  FilesystemCache._() {
    FileChangeNotifier.instance.changes.listen(
      (event) => unawaited(applyFileChanges(event)),
    );
  }

  static final FilesystemCache instance = FilesystemCache._();
  static const int _formatVersion = 1;
  static const int _maximumFolders = 500;
  static const int _maximumEntriesPerFolder = 2000;
  static const int _maximumEntriesInMemory = 80000;
  static const int _maximumDiskBytes = 12 * 1024 * 1024;
  static const int _maximumGenericValueBytes = 2 * 1024 * 1024;
  static const int _maximumGenericValues = 32;
  static const int _maximumGenericValuesMemoryBytes = 12 * 1024 * 1024;
  static const int _maximumCategoryValueBytes = 10 * 1024 * 1024;
  static const Duration _writeDelay = Duration(milliseconds: 300);
  static const Duration unusedCacheRetention = Duration(days: 30);

  final LinkedHashMap<String, Map<String, Object?>> _folders =
      LinkedHashMap<String, Map<String, Object?>>();
  final LinkedHashMap<String, Map<String, Object?>> _values =
      LinkedHashMap<String, Map<String, Object?>>();
  final Map<String, int> _valueSizes = {};
  final LinkedHashSet<String> _openedCategoryPages = LinkedHashSet();
  Future<void>? _loading;
  Future<void> _writeTail = Future<void>.value();
  Timer? _writeTimer;
  File? _file;
  bool _dirty = false;

  Future<void> get ready => _loading ??= _load();

  String _folderKey(String volumeId, String path) =>
      '$volumeId|${_normalize(path)}';

  String _normalize(String path) =>
      path.replaceAll('\\', '/').replaceFirst(RegExp(r'/+$'), '');

  Future<Map<String, Object?>?> loadValue(
    String key, {
    bool markUsed = false,
  }) async {
    await ready;
    final value = _values[key];
    if (value == null) return null;
    if (markUsed) {
      _markValueUsed(key, value);
    }
    return Map<String, Object?>.from(value);
  }

  Future<void> saveValue(String key, Map<String, Object?> value) async {
    await ready;
    final serialized =
        key.startsWith('category:') || key.startsWith('homeDrive:')
        ? await compute<Map<String, Object?>, int>(_jsonByteLength, value)
        : utf8.encode(jsonEncode(value)).length;
    final maximumValueBytes = key.startsWith('category:')
        ? _maximumCategoryValueBytes
        : _maximumGenericValueBytes;
    if (serialized + 128 > maximumValueBytes) {
      _removeValue(key);
      _markDirty();
      debugPrint('[FilesystemCache] Skipping oversized value "$key".');
      return;
    }
    final oldValue = _values[key];
    final savedValue = Map<String, Object?>.from(value)
      ..['savedAtMilliseconds'] = DateTime.now().millisecondsSinceEpoch
      ..['lastUsedMilliseconds'] = oldValue?['lastUsedMilliseconds'];
    _values.remove(key);
    _values[key] = savedValue;
    _valueSizes[key] = serialized + 128;
    _trimMemory();
    _markDirty();
  }

  Future<CachedFolderListing?> loadFolder(
    String volumeId,
    String path, {
    bool markUsed = false,
  }) async {
    await ready;
    final key = _folderKey(volumeId, path);
    final record = _folders[key];
    if (record == null) return null;
    if (markUsed) {
      _markFolderUsed(record);
      _folders.remove(key);
      _folders[key] = record;
    }
    return _decodeFolder(record);
  }

  Future<void> saveFolder({
    required String volumeId,
    required String path,
    required int directoryModifiedMilliseconds,
    required Iterable<CachedListingEntry> entries,
    bool isComplete = true,
  }) async {
    await ready;
    final allEntries = entries.take(_maximumEntriesPerFolder + 1).toList();
    final complete =
        isComplete && allEntries.length <= _maximumEntriesPerFolder;
    final boundedEntries = allEntries.take(_maximumEntriesPerFolder).toList();
    final key = _folderKey(volumeId, path);
    final oldRecord = _folders[key];
    _folders[key] = {
      'volumeId': volumeId,
      'path': path,
      'directoryModified': directoryModifiedMilliseconds,
      'savedAtMilliseconds': DateTime.now().millisecondsSinceEpoch,
      'lastUsedMilliseconds': oldRecord?['lastUsedMilliseconds'],
      'complete': complete,
      'stale': !complete,
      'entries': boundedEntries.map((entry) => entry.toJson()).toList(),
    };
    final savedRecord = _folders.remove(key)!;
    _folders[key] = savedRecord;
    _trimMemory();
    _markDirty();
  }

  Future<void> markFolderStale(String volumeId, String path) async {
    await ready;
    final record = _folders[_folderKey(volumeId, path)];
    if (record == null || record['stale'] == true) return;
    record['stale'] = true;
    _markDirty();
  }

  Future<void> markFolderUsed(String volumeId, String path) async {
    await ready;
    final record = _folders[_folderKey(volumeId, path)];
    if (record == null) return;
    _markFolderUsed(record);
  }

  Future<void> markValueUsed(String key) async {
    await ready;
    final value = _values[key];
    if (value == null) return;
    _markValueUsed(key, value);
  }

  Future<void> markCategoryPageOpened(String cacheKey) async {
    await ready;
    final changed =
        !_openedCategoryPages.contains(cacheKey) ||
        _openedCategoryPages.last != cacheKey;
    _openedCategoryPages.remove(cacheKey);
    _openedCategoryPages.add(cacheKey);
    while (_openedCategoryPages.length > _maximumGenericValues) {
      _openedCategoryPages.remove(_openedCategoryPages.first);
    }
    final value = _values[cacheKey];
    if (value != null) _markValueUsed(cacheKey, value);
    if (changed) _markDirty();
  }

  Future<void> expireUnused({
    required Set<String> openFolderPaths,
    required Set<String> openCategoryCacheKeys,
  }) async {
    await ready;
    final cutoff = DateTime.now()
        .subtract(unusedCacheRetention)
        .millisecondsSinceEpoch;
    final normalizedOpenPaths = openFolderPaths.map(_normalize).toSet();
    final expiredFolderKeys = <String>[];
    for (final entry in _folders.entries) {
      final record = entry.value;
      final path = _normalize(record['path']! as String);
      if (normalizedOpenPaths.contains(path)) continue;
      final lastUsed = record['lastUsedMilliseconds'] as int? ?? 0;
      if (lastUsed < cutoff) expiredFolderKeys.add(entry.key);
    }
    for (final key in expiredFolderKeys) {
      _folders.remove(key);
    }

    const neverExpireKeys = {
      'homeAppsTotal',
      'homeCategoryTotals',
      'availableStorage',
    };
    final expiredValueKeys = <String>[];
    for (final entry in _values.entries) {
      if (neverExpireKeys.contains(entry.key) ||
          openCategoryCacheKeys.contains(entry.key)) {
        continue;
      }
      if (entry.key.startsWith('category:') &&
          !_openedCategoryPages.contains(entry.key)) {
        expiredValueKeys.add(entry.key);
        continue;
      }
      final lastUsed = entry.value['lastUsedMilliseconds'] as int? ?? 0;
      if (lastUsed < cutoff) expiredValueKeys.add(entry.key);
    }
    for (final key in expiredValueKeys) {
      _removeValue(key);
    }
    if (expiredFolderKeys.isNotEmpty || expiredValueKeys.isNotEmpty) {
      _markDirty();
    }
  }

  Future<void> removeVolume(String volumeId) async {
    await ready;
    _folders.removeWhere((_, record) => record['volumeId'] == volumeId);
    _values.removeWhere(
      (key, value) =>
          key == 'homeDrive:$volumeId' || value['volumeId'] == volumeId,
    );
    _valueSizes.removeWhere((key, _) => !_values.containsKey(key));
    _openedCategoryPages.removeWhere(
      (key) => key.startsWith('category:$volumeId:'),
    );
    for (final value in _values.values) {
      final totalsByVolume = value['totalsByVolume'];
      if (totalsByVolume is Map) {
        value['totalsByVolume'] = Map.from(totalsByVolume)..remove(volumeId);
      }
      final volumeIds = value['volumeIds'];
      if (volumeIds is List) {
        value['volumeIds'] = volumeIds
            .where((id) => id != volumeId)
            .toList(growable: false);
      }
    }
    _markDirty();
  }

  Future<void> removeVolumesNotPresent(Set<String> volumeIds) async {
    await ready;
    final cachedIds = <String>{
      for (final record in _folders.values)
        if (record['volumeId'] is String) record['volumeId']! as String,
      for (final value in _values.values)
        if (value['volumeId'] is String) value['volumeId']! as String,
      for (final value in _values.values)
        if (value['volumeIds'] is List)
          ...(value['volumeIds'] as List).whereType<String>(),
    };
    final removedIds = cachedIds.difference(volumeIds);
    for (final cachedId in removedIds) {
      _folders.removeWhere((_, record) => record['volumeId'] == cachedId);
      _values.removeWhere(
        (key, value) =>
            key == 'homeDrive:$cachedId' || value['volumeId'] == cachedId,
      );
      _valueSizes.removeWhere((key, _) => !_values.containsKey(key));
      _openedCategoryPages.removeWhere(
        (key) => key.startsWith('category:$cachedId:'),
      );
    }
    _openedCategoryPages.removeWhere(
      (key) => !volumeIds.any((id) => key.startsWith('category:$id:')),
    );
    for (final value in _values.values) {
      final cachedVolumeIds = value['volumeIds'];
      if (cachedVolumeIds is! List) continue;
      value['volumeIds'] = cachedVolumeIds
          .where((id) => !removedIds.contains(id))
          .toList(growable: false);
      final devices = value['devices'];
      if (devices is List) {
        value['devices'] = devices
            .where(
              (device) => device is Map && !removedIds.contains(device['id']),
            )
            .toList(growable: false);
      }
      final totalsByVolume = value['totalsByVolume'];
      if (totalsByVolume is Map) {
        value['totalsByVolume'] = Map.from(totalsByVolume)
          ..removeWhere((id, _) => removedIds.contains(id));
      }
    }
    if (removedIds.isNotEmpty) _markDirty();
  }

  Future<void> clear() async {
    await ready;
    _folders.clear();
    _values.clear();
    _valueSizes.clear();
    _openedCategoryPages.clear();
    _markDirty();
  }

  Future<void> applyFileChanges(FileChangeEvent event) async {
    await ready;
    final affected = event.affectedFolders.map(_normalize).toSet();
    for (final record in _folders.values) {
      final cachedPath = _normalize(record['path']! as String);
      final relevant = affected.any(
        (path) => path == cachedPath || path.startsWith('$cachedPath/'),
      );
      if (!relevant) continue;
      record['stale'] = true;
      final entries = (record['entries'] as List).cast<Map>();
      for (final change in event.changes) {
        if (change.kind == FileChangeKind.deleted && change.path != null) {
          entries.removeWhere(
            (entry) =>
                _normalize(entry['path']! as String) ==
                    _normalize(change.path!) ||
                _normalize(
                  entry['path']! as String,
                ).startsWith('${_normalize(change.path!)}/'),
          );
        } else if (change.kind == FileChangeKind.renamed &&
            change.oldPath != null &&
            change.newPath != null) {
          for (final entry in entries) {
            final itemPath = _normalize(entry['path']! as String);
            final oldPath = _normalize(change.oldPath!);
            if (itemPath == oldPath || itemPath.startsWith('$oldPath/')) {
              entry['path'] =
                  '${change.newPath!}${itemPath.substring(oldPath.length)}';
            }
          }
        }
      }
    }
    for (final value in _values.values) {
      final rootPath = value['rootPath'];
      if (rootPath is! String) continue;
      final normalizedRoot = _normalize(rootPath);
      if (affected.any(
        (path) =>
            path == normalizedRoot ||
            path.startsWith('$normalizedRoot/') ||
            normalizedRoot.startsWith('$path/'),
      )) {
        value['stale'] = true;
      }
    }
    _markDirty();
  }

  CachedFolderListing _decodeFolder(Map<String, Object?> record) =>
      CachedFolderListing(
        volumeId: record['volumeId']! as String,
        path: record['path']! as String,
        directoryModifiedMilliseconds: record['directoryModified'] as int? ?? 0,
        isStale: record['stale'] == true,
        isComplete: record['complete'] == true,
        entries: (record['entries'] as List)
            .whereType<Map>()
            .map(CachedListingEntry.fromJson)
            .toList(growable: false),
      );

  Future<void> _load() async {
    try {
      final directory = await getApplicationSupportDirectory();
      _file = File(
        '${directory.path}${Platform.pathSeparator}filesystem_cache.json',
      );
      if (!await _file!.exists()) return;
      final decodedResult = await compute<String, Map<String, Object?>>(
        _decodeCacheJson,
        await _file!.readAsString(),
      );
      final decoded = decodedResult['data'];
      if (decodedResult['malformed'] == true) {
        debugPrint(
          '[FilesystemCache] Discarding malformed cache: '
          '${decodedResult['error'] ?? 'invalid JSON root'}',
        );
        await _file!.delete();
        return;
      }
      if (decoded is! Map || decoded['version'] != _formatVersion) {
        await _file!.delete();
        return;
      }
      final folders = decoded['folders'];
      if (folders is List) {
        for (final raw in folders.whereType<Map>()) {
          final record = Map<String, Object?>.from(raw);
          if (record['volumeId'] is! String ||
              record['path'] is! String ||
              record['entries'] is! List) {
            continue;
          }
          if (record['lastUsedMilliseconds'] is! int) {
            record['lastUsedMilliseconds'] =
                record['savedAtMilliseconds'] as int? ??
                record['savedAt'] as int? ??
                DateTime.now().millisecondsSinceEpoch;
            _dirty = true;
          }
          _folders[_folderKey(
                record['volumeId']! as String,
                record['path']! as String,
              )] =
              record;
        }
      }
      final values = decoded['values'];
      if (values is Map) {
        for (final entry in values.entries) {
          if (entry.key is String && entry.value is Map) {
            final key = entry.key as String;
            final value = Map<String, Object?>.from(entry.value as Map);
            if (key.startsWith('category:') && value['rawHomeScan'] == true) {
              _dirty = true;
              continue;
            }
            if (key.startsWith('category:')) {
              _openedCategoryPages.add(key);
            }
            if (!value.containsKey('savedAtMilliseconds') ||
                !value.containsKey('lastUsedMilliseconds')) {
              _dirty = true;
            }
            value.putIfAbsent(
              'savedAtMilliseconds',
              () => DateTime.now().millisecondsSinceEpoch,
            );
            value.putIfAbsent(
              'lastUsedMilliseconds',
              () => value['savedAtMilliseconds'],
            );
            _values[key] = value;
          }
        }
      }
      final measuredSizes =
          await compute<Map<String, Object?>, Map<String, Object?>>(
            _measureCacheValueSizes,
            _values,
          );
      _valueSizes
        ..clear()
        ..addAll(measuredSizes.cast<String, int>());
      final openedPages = decoded['openedCategoryPages'];
      if (openedPages is List) {
        _openedCategoryPages.addAll(openedPages.whereType<String>());
      }
      _openedCategoryPages.removeWhere((key) => !_values.containsKey(key));
      while (_openedCategoryPages.length > _maximumGenericValues) {
        _openedCategoryPages.remove(_openedCategoryPages.first);
        _dirty = true;
      }
      _trimMemory();
      if (_dirty) _markDirty();
    } on FileSystemException catch (error) {
      debugPrint('[FilesystemCache] Could not read cache: $error');
    } on FormatException catch (error) {
      debugPrint('[FilesystemCache] Discarding malformed cache: $error');
      final file = _file;
      if (file != null && await file.exists()) await file.delete();
    }
  }

  void _trimMemory() {
    var evicted = false;
    while (_folders.length > _maximumFolders ||
        _folders.values.fold<int>(
              0,
              (total, record) => total + (record['entries'] as List).length,
            ) >
            _maximumEntriesInMemory) {
      if (_folders.isEmpty) break;
      _folders.remove(_folders.keys.first);
      evicted = true;
    }
    int genericBytes() =>
        _valueSizes.values.fold<int>(0, (total, bytes) => total + bytes);
    while (_values.length > _maximumGenericValues ||
        genericBytes() > _maximumGenericValuesMemoryBytes) {
      if (_values.isEmpty) break;
      final oldestKey = _values.keys.first;
      _removeValue(oldestKey);
      evicted = true;
    }
    if (evicted) _dirty = true;
  }

  void _removeValue(String key) {
    _values.remove(key);
    _valueSizes.remove(key);
    _openedCategoryPages.remove(key);
  }

  void _markDirty() {
    _dirty = true;
    _writeTimer?.cancel();
    _writeTimer = Timer(_writeDelay, () => unawaited(_persist()));
  }

  void _markFolderUsed(Map<String, Object?> record) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final previous = record['lastUsedMilliseconds'] as int? ?? 0;
    record['lastUsedMilliseconds'] = now;
    if (now - previous >= const Duration(hours: 12).inMilliseconds) {
      _markDirty();
    }
  }

  void _markValueUsed(String key, Map<String, Object?> value) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final previous = value['lastUsedMilliseconds'] as int? ?? 0;
    value['lastUsedMilliseconds'] = now;
    _values.remove(key);
    _values[key] = value;
    if (now - previous >= const Duration(hours: 12).inMilliseconds) {
      _markDirty();
    }
  }

  Future<void> _persist() async {
    _writeTimer?.cancel();
    _writeTimer = null;
    if (!_dirty) return;
    _dirty = false;
    final file = _file;
    if (file == null) {
      await ready;
      if (_file == null) return;
      return _persist();
    }
    _trimMemory();
    final data = {
      'version': _formatVersion,
      'folders': _folders.values.toList(growable: false),
      'values': _values,
      'openedCategoryPages': _openedCategoryPages.toList(growable: false),
    };
    var encoded = await compute<Map<String, Object?>, Map<String, Object?>>(
      _encodeJsonWithByteLength,
      data,
    );
    while ((encoded['byteLength']! as int) > _maximumDiskBytes &&
        (_folders.isNotEmpty || _values.isNotEmpty)) {
      if (_folders.isNotEmpty) {
        _folders.remove(_folders.keys.first);
      } else {
        _removeValue(_values.keys.first);
      }
      encoded = await compute<Map<String, Object?>, Map<String, Object?>>(
        _encodeJsonWithByteLength,
        {
          'version': _formatVersion,
          'folders': _folders.values.toList(growable: false),
          'values': _values,
          'openedCategoryPages': _openedCategoryPages.toList(growable: false),
        },
      );
    }
    if ((encoded['byteLength']! as int) > _maximumDiskBytes) {
      debugPrint('[FilesystemCache] Generic cached values exceed disk limit.');
      _dirty = true;
      return;
    }
    _writeTail = _writeTail
        .then((_) async {
          final temporary = File('${file.path}.tmp');
          await temporary.writeAsString(
            encoded['json']! as String,
            flush: true,
          );
          await temporary.rename(file.path);
        })
        .catchError((Object error, StackTrace stackTrace) {
          _dirty = true;
          debugPrint('[FilesystemCache] Could not persist cache: $error');
        });
    await _writeTail;
    if (_dirty) _markDirty();
  }
}

int _jsonByteLength(Map<String, Object?> value) =>
    utf8.encode(jsonEncode(value)).length;

Map<String, Object?> _measureCacheValueSizes(Map<String, Object?> values) => {
  for (final entry in values.entries)
    entry.key: utf8.encode(jsonEncode(entry.value)).length,
};

Map<String, Object?> _encodeJsonWithByteLength(Map<String, Object?> value) {
  final json = jsonEncode(value);
  return {'json': json, 'byteLength': utf8.encode(json).length};
}

Map<String, Object?> _decodeCacheJson(String value) {
  try {
    final decoded = jsonDecode(value);
    if (decoded is! Map) return {'malformed': true};
    return {'data': Map<String, Object?>.from(decoded)};
  } on FormatException catch (error) {
    return {'malformed': true, 'error': error.message};
  }
}

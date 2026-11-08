import 'dart:convert';
import 'dart:io';

import 'package:hive/hive.dart';
import 'package:path_provider/path_provider.dart';

import '../../../domain/entities/pdf_reading_progress.dart';
import '../../../domain/repositories/pdf_reading_progress_repository.dart';

class HivePdfReadingProgressRepository implements PdfReadingProgressRepository {
  static const _boxName = 'pdf.reading.positions';
  static const _maxRecords = 500;

  final Future<Directory> Function() _supportDirectoryProvider;
  Future<Box<Map>>? _boxFuture;
  Future<void> _writeQueue = Future<void>.value();

  HivePdfReadingProgressRepository({
    Future<Directory> Function()? supportDirectoryProvider,
  }) : _supportDirectoryProvider =
           supportDirectoryProvider ?? getApplicationSupportDirectory;

  Future<Box<Map>> _box() async {
    try {
      return await (_boxFuture ??= _openBox());
    } catch (_) {
      _boxFuture = null;
      rethrow;
    }
  }

  Future<Box<Map>> _openBox() async {
    final directory = await _supportDirectoryProvider();
    if (!Hive.isBoxOpen(_boxName)) Hive.init(directory.path);
    return Hive.openBox<Map>(_boxName);
  }

  String _key(String volumeId, String relativePath) =>
      jsonEncode([volumeId, _normalize(relativePath)]);

  String _normalize(String path) => path
      .replaceAll('\\', '/')
      .replaceFirst(RegExp(r'^/+'), '')
      .replaceFirst(RegExp(r'/+$'), '');

  @override
  Future<PdfReadingProgress?> get(String volumeId, String relativePath) async {
    final box = await _box();
    final raw = box.get(_key(volumeId, relativePath));
    if (raw == null) return null;
    try {
      return PdfReadingProgress.fromJson(raw);
    } on FormatException {
      await box.delete(_key(volumeId, relativePath));
      return null;
    } on TypeError {
      await box.delete(_key(volumeId, relativePath));
      return null;
    } on ArgumentError {
      await box.delete(_key(volumeId, relativePath));
      return null;
    }
  }

  @override
  Future<void> save(
    String volumeId,
    String relativePath,
    PdfReadingProgress progress,
  ) {
    return _enqueue(() async {
      final box = await _box();
      await box.put(_key(volumeId, relativePath), {
        'volumeId': volumeId,
        'relativePath': _normalize(relativePath),
        ...progress.toJson(),
      });
      if (box.length <= _maxRecords) return;
      final entries = box.toMap().entries.toList()
        ..sort((left, right) {
          final leftOpened =
              (left.value['lastOpenedTimeMilliseconds'] as int?) ?? 0;
          final rightOpened =
              (right.value['lastOpenedTimeMilliseconds'] as int?) ?? 0;
          return leftOpened.compareTo(rightOpened);
        });
      final excess = entries.length - _maxRecords;
      for (final entry in entries.take(excess)) {
        await box.delete(entry.key);
      }
    });
  }

  @override
  Future<void> remove(String volumeId, String relativePath) =>
      _enqueue(() async {
        final box = await _box();
        await box.delete(_key(volumeId, relativePath));
      });

  @override
  Future<void> removeTree(String volumeId, String relativePath) =>
      _enqueue(() async {
        final box = await _box();
        final prefix = _normalize(relativePath);
        final keys = box
            .toMap()
            .entries
            .where((entry) {
              if (entry.value['volumeId'] != volumeId) return false;
              final candidate = entry.value['relativePath'] as String?;
              return candidate != null &&
                  (candidate == prefix ||
                      (prefix.isEmpty || candidate.startsWith('$prefix/')));
            })
            .map((entry) => entry.key)
            .toList(growable: false);
        await box.deleteAll(keys);
      });

  @override
  Future<void> moveTree({
    required String oldVolumeId,
    required String oldRelativePath,
    required String newVolumeId,
    required String newRelativePath,
  }) => _enqueue(() async {
    final box = await _box();
    final oldPrefix = _normalize(oldRelativePath);
    final newPrefix = _normalize(newRelativePath);
    final moves = <(dynamic, String, Map)>[];
    for (final entry in box.toMap().entries) {
      if (entry.value['volumeId'] != oldVolumeId) continue;
      final candidate = entry.value['relativePath'] as String?;
      if (candidate == null ||
          !(candidate == oldPrefix ||
              (oldPrefix.isEmpty || candidate.startsWith('$oldPrefix/')))) {
        continue;
      }
      final suffix = candidate == oldPrefix
          ? ''
          : oldPrefix.isEmpty
          ? candidate
          : candidate.substring(oldPrefix.length + 1);
      final targetPath = suffix.isEmpty
          ? newPrefix
          : newPrefix.isEmpty
          ? suffix
          : '$newPrefix/$suffix';
      moves.add((
        entry.key,
        _key(newVolumeId, targetPath),
        {...entry.value, 'volumeId': newVolumeId, 'relativePath': targetPath},
      ));
    }
    for (final move in moves) {
      await box.put(move.$2, move.$3);
      if (move.$2 != move.$1) await box.delete(move.$1);
    }
  });

  Future<void> _enqueue(Future<void> Function() operation) {
    final next = _writeQueue.then(
      (_) => operation(),
      onError: (Object _, StackTrace _) => operation(),
    );
    _writeQueue = next;
    return next;
  }
}

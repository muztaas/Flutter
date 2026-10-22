import 'package:flutter/services.dart';

import '../../../domain/entities/archive_entry.dart';
import '../../../domain/entities/archive_operation_progress.dart';
import '../../../domain/entities/archive_operation_result.dart';
import '../../../domain/repositories/archive_repository.dart';

class AndroidArchiveRepository implements ArchiveRepository {
  static const _methodChannel = MethodChannel(
    'modi_file_explorer2/archive',
  );
  static const _eventChannel = EventChannel(
    'modi_file_explorer2/archive/events',
  );

  @override
  Stream<ArchiveOperationProgress> get progress =>
      _eventChannel.receiveBroadcastStream().map((raw) {
        final value = Map<Object?, Object?>.from(raw as Map);
        return ArchiveOperationProgress(
          operationId: value['operationId'] as String? ?? '',
          completedBytes: (value['completedBytes'] as num?)?.toInt() ?? 0,
          totalBytes: (value['totalBytes'] as num?)?.toInt() ?? 0,
          completedEntries: (value['completedEntries'] as num?)?.toInt() ?? 0,
          totalEntries: (value['totalEntries'] as num?)?.toInt() ?? 0,
          currentEntry: value['currentEntry'] as String?,
        );
      });

  @override
  Future<List<ArchiveEntry>> listEntries({
    required String archivePath,
    String? password,
  }) async {
    final result = await _methodChannel.invokeMethod<List<dynamic>>(
      'listEntries',
      {'archivePath': archivePath, 'password': password},
    );
    return (result ?? const <dynamic>[])
        .map((raw) {
          final value = Map<Object?, Object?>.from(raw as Map);
          final modified = (value['modifiedMillis'] as num?)?.toInt();
          return ArchiveEntry(
            path: value['path'] as String? ?? '',
            name: value['name'] as String? ?? '',
            isDirectory: value['isDirectory'] as bool? ?? false,
            size: (value['size'] as num?)?.toInt() ?? 0,
            modifiedTime: modified == null || modified <= 0
                ? null
                : DateTime.fromMillisecondsSinceEpoch(modified),
            isEncrypted: value['isEncrypted'] as bool? ?? false,
          );
        })
        .where((entry) => entry.path.isNotEmpty)
        .toList(growable: false);
  }

  @override
  Future<int> availableBytes(String path) async {
    final result = await _methodChannel.invokeMethod<num>(
      'availableBytes',
      {'path': path},
    );
    return result?.toInt() ?? 0;
  }

  @override
  Future<bool> pathExists(String path) async {
    final result = await _methodChannel.invokeMethod<bool>(
      'pathExists',
      {'path': path},
    );
    return result ?? false;
  }

  @override
  Future<bool> pathIsDirectory(String path) async {
    final result = await _methodChannel.invokeMethod<bool>(
      'pathIsDirectory',
      {'path': path},
    );
    return result ?? false;
  }

  @override
  Future<int> estimateCreateBytes({
    required String archivePath,
    required List<String> sourcePaths,
    required bool excludeOutputPath,
  }) async {
    final result = await _methodChannel.invokeMethod<num>(
      'estimateCreateBytes',
      {
        'archivePath': archivePath,
        'sourcePaths': sourcePaths,
        'excludeOutputPath': excludeOutputPath,
      },
    );
    return result?.toInt() ?? 0;
  }

  @override
  Future<ArchiveOperationResult> extract({
    required String operationId,
    required String archivePath,
    required String destinationPath,
    List<String>? selectedEntries,
    String? password,
    Map<String, String> conflictActions = const {},
  }) async {
    final result = await _methodChannel.invokeMethod<Map<dynamic, dynamic>>(
      'extract',
      {
        'operationId': operationId,
        'archivePath': archivePath,
        'destinationPath': destinationPath,
        'selectedEntries': selectedEntries,
        'password': password,
        'conflictActions': conflictActions,
      },
    );
    return _decodeResult(result);
  }

  @override
  Future<ArchiveOperationResult> create({
    required String operationId,
    required String archivePath,
    required String format,
    required List<String> sourcePaths,
    required String compressionLevel,
    required String conflictAction,
    String? password,
  }) async {
    final result = await _methodChannel.invokeMethod<Map<dynamic, dynamic>>(
      'create',
      {
        'operationId': operationId,
        'archivePath': archivePath,
        'format': format,
        'sourcePaths': sourcePaths,
        'compressionLevel': compressionLevel,
        'conflictAction': conflictAction,
        'password': password,
      },
    );
    return _decodeResult(result);
  }

  @override
  Future<void> cancel(String operationId) =>
      _methodChannel.invokeMethod<void>(
        'cancel',
        {'operationId': operationId},
      );

  ArchiveOperationResult _decodeResult(Map<dynamic, dynamic>? result) {
    final value = result ?? const <dynamic, dynamic>{};
    return ArchiveOperationResult(
      completed: (value['completed'] as num?)?.toInt() ?? 0,
      skipped: (value['skipped'] as num?)?.toInt() ?? 0,
      failed: (value['failed'] as num?)?.toInt() ?? 0,
      cancelled: value['cancelled'] as bool? ?? false,
      messages: (value['messages'] as List<dynamic>? ?? const [])
          .whereType<String>()
          .toList(growable: false),
      outputPath: value['outputPath'] as String?,
      outputSize: (value['outputSize'] as num?)?.toInt(),
    );
  }
}

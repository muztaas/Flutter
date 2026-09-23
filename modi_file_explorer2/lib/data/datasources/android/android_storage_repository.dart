import 'dart:async';
import 'dart:io';

import 'package:disk_space_2/disk_space_2.dart';
import 'package:flutter/services.dart';

import '../../../domain/entities/storage_device.dart';
import '../../../domain/entities/file_system_entry.dart';
import '../../../domain/repositories/storage_repository.dart';

class AndroidStorageRepositoryImpl implements StorageRepository {
  AndroidStorageRepositoryImpl();
  static const _storageChannel = MethodChannel('modi_file_explorer2/storage_volumes');

  Future<StorageDevice> _deviceForPath({required String id, required String name, required String path}) async {
    final freeForPath = await DiskSpace.getFreeDiskSpaceForPath(path);
    final totalMb = await DiskSpace.getTotalDiskSpace;
    final totalBytes = ((totalMb ?? 0) * 1024 * 1024).round();
    final usedBytes = totalBytes - ((freeForPath ?? 0) * 1024 * 1024).round();
    return StorageDevice(
      id: id,
      name: name,
      path: path,
      usedBytes: usedBytes,
      totalBytes: totalBytes,
    );
  }

  @override
  Future<List<StorageDevice>> listStorageDevices() async {
    final List<StorageDevice> devices = [];

    try {
      if (Platform.isAndroid) {
        final rawVolumes = await _storageChannel.invokeMethod<List<dynamic>>('listStorageVolumes') ?? [];
        var externalIndex = 0;
        for (final raw in rawVolumes) {
          final volume = Map<String, dynamic>.from(raw as Map);
          final path = volume['path'] as String?;
          if (path == null || path.isEmpty) continue;
          final isPrimary = volume['isPrimary'] == true;
          final isRemovable = volume['isRemovable'] == true;
          if (!isPrimary && !isRemovable) continue;

              final currentExternalIndex = isPrimary ? null : externalIndex++;
              final name = isPrimary
                ? 'Internal Storage'
                : ((volume['description'] as String?)?.trim().isNotEmpty == true
                  ? volume['description'] as String
                  : 'USB Drive ${(currentExternalIndex ?? 0) + 1}');
              final id = isPrimary ? 'internal' : 'external_${currentExternalIndex ?? 0}';
          try {
            devices.add(await _deviceForPath(id: id, name: name, path: path));
          } catch (_) {
            devices.add(StorageDevice(id: id, name: name, path: path));
          }
        }

        // Keep a minimal fallback for devices whose StorageManager API does
        // not expose a directory, but never replace a discovered volume.
        if (devices.isEmpty) {
          final internal = Directory('/storage/emulated/0');
          if (await internal.exists()) {
            devices.add(StorageDevice(id: 'internal', name: 'Internal Storage', path: internal.path));
          }
        }
      }
    } catch (e) {
      // ignore and return what we have
    }

    return devices;
  }

  @override
  Future<List<FileSystemEntry>> listDirectory(String path) async {
    final dir = Directory(path);
    if (!await dir.exists()) return [];
    final children = <FileSystemEntry>[];
    try {
      await for (var entity in dir.list()) {
        final stat = await entity.stat();
        children.add(FileSystemEntry(
          name: entity.uri.pathSegments.isNotEmpty ? entity.uri.pathSegments.last : entity.path,
          path: entity.path,
          isDirectory: stat.type == FileSystemEntityType.directory,
          size: stat.size,
          modified: stat.modified,
        ));
      }
    } catch (e) {
      // ignore
    }
    return children;
  }

  @override
  Stream<List<FileSystemEntry>> watchDirectory(String path) async* {
    // Simple implementation: poll every 2s
    while (true) {
      yield await listDirectory(path);
      await Future.delayed(const Duration(seconds: 2));
    }
  }
}

import 'dart:developer' as developer;

import '../entities/storage_device.dart';

String storageDisplayName({
  required String path,
  StorageDevice? drive,
  bool isDriveRoot = false,
  String? fallback,
}) {
  final isDrivePath = drive != null && _samePath(path, drive.path);
  if (isDrivePath) {
    final driveName = drive.name.trim();
    if (driveName.isNotEmpty && !_isNumericLabel(driveName)) {
      return driveName;
    }
  }

  if (!isDriveRoot && !isDrivePath) {
    final normalizedPath = path
        .replaceAll('\\', '/')
        .replaceFirst(RegExp(r'/+$'), '');
    final name = normalizedPath
        .split('/')
        .where((part) => part.isNotEmpty)
        .lastOrNull;
    if (name != null) return name;
  }

  final savedFallback = fallback?.trim();
  if (savedFallback != null &&
      savedFallback.isNotEmpty &&
      !_isNumericLabel(savedFallback)) {
    developer.log(
      'Using saved fallback "$savedFallback" for "$path".',
      name: 'StorageDisplayName',
    );
    return savedFallback;
  }

  developer.log(
    'Using generic fallback for "$path" '
    '(drive name unavailable: ${drive?.name}).',
    name: 'StorageDisplayName',
  );
  return 'Storage';
}

bool _samePath(String left, String right) =>
    left.replaceAll('\\', '/').replaceFirst(RegExp(r'/+$'), '').toLowerCase() ==
    right.replaceAll('\\', '/').replaceFirst(RegExp(r'/+$'), '').toLowerCase();

bool _isNumericLabel(String value) => RegExp(r'^\d+$').hasMatch(value);

String formatBytes(int? bytes) {
  if (bytes == null) return 'Unavailable';
  if (bytes < 0) return 'Unavailable';
  if (bytes < 1024) return '$bytes B';

  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unitIndex = -1;
  do {
    value /= 1024;
    unitIndex++;
  } while (value >= 1024 && unitIndex < units.length - 1);

  return '${value.toStringAsFixed(1)} ${units[unitIndex]}';
}

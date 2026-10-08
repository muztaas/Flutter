import 'dart:typed_data';

class OpenWithApp {
  const OpenWithApp({
    required this.name,
    required this.packageName,
    required this.mimeType,
    this.applicationName,
    this.activityName,
    this.iconBytes,
  });

  final String name;
  final String packageName;
  final String mimeType;
  final String? applicationName;
  final String? activityName;
  final Uint8List? iconBytes;
}

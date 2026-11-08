class DetectedFileContent {
  const DetectedFileContent({
    required this.name,
    required this.category,
    required this.mimeType,
  });

  static const unknown = DetectedFileContent(
    name: 'unknown content',
    category: null,
    mimeType: null,
  );

  final String name;
  final String? category;
  final String? mimeType;

  bool get isKnown => category != null;

  bool get isText =>
      category == 'Text' || mimeType?.startsWith('text/') == true;

  String get description {
    if (name.isEmpty) return name;
    final first = name[0].toLowerCase();
    return '${'aeiou'.contains(first) ? 'an' : 'a'} $name';
  }
}

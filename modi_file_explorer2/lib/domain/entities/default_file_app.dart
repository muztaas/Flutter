class DefaultFileApp {
  const DefaultFileApp({
    required this.extension,
    required this.handlerId,
    required this.category,
    required this.mimeType,
    this.packageName,
    this.displayName,
  });

  static const textEditorHandlerId = 'textEditor';

  final String extension;
  final String handlerId;
  final String category;
  final String mimeType;
  final String? packageName;
  final String? displayName;

  bool get isTextEditor => handlerId == textEditorHandlerId;

  Map<String, Object?> toJson() => {
    'handlerId': handlerId,
    'category': category,
    'mimeType': mimeType,
    'packageName': packageName,
    'displayName': displayName,
  };

  factory DefaultFileApp.fromJson(String extension, Map<String, dynamic> json) {
    return DefaultFileApp(
      extension: extension,
      handlerId: json['handlerId'] as String,
      category: json['category'] as String,
      mimeType: json['mimeType'] as String,
      packageName: json['packageName'] as String?,
      displayName: json['displayName'] as String?,
    );
  }
}

import 'file_type_category.dart';

class DefaultFileApp {
  const DefaultFileApp({
    required this.extension,
    required this.handlerId,
    required this.category,
    required this.mimeType,
    this.packageName,
    this.displayName,
    this.activityName,
    this.extensionSpecific = false,
    this.extensions = const [],
  });

  static const textEditorHandlerId = 'textEditor';
  static const imageViewerHandlerId = 'imageViewer';
  static const videoPlayerHandlerId = 'videoPlayer';
  static const audioPlayerHandlerId = 'audioPlayer';
  static const archiveManagerHandlerId = 'archiveManager';
  static const pdfViewerHandlerId = 'pdfViewer';
  static const spreadsheetViewerHandlerId = 'spreadsheetViewer';
  static const documentViewerHandlerId = 'documentViewer';
  static const presentationViewerHandlerId = 'presentationViewer';

  final String extension;
  final String handlerId;
  final String category;
  final String mimeType;
  final String? packageName;
  final String? displayName;
  final String? activityName;
  final bool extensionSpecific;
  final List<String> extensions;

  List<String> get matchedExtensions =>
      (extensions.isNotEmpty ? extensions : [extension])
          .map(FileTypeCategory.normalizeExtension)
          .where((value) => value.isNotEmpty)
          .toList(growable: false);

  bool get isTextEditor => handlerId == textEditorHandlerId;
  bool get isImageViewer => handlerId == imageViewerHandlerId;
  bool get isVideoPlayer => handlerId == videoPlayerHandlerId;
  bool get isAudioPlayer => handlerId == audioPlayerHandlerId;
  bool get isArchiveManager => handlerId == archiveManagerHandlerId;
  bool get isPdfViewer => handlerId == pdfViewerHandlerId;
  bool get isSpreadsheetViewer => handlerId == spreadsheetViewerHandlerId;
  bool get isDocumentViewer => handlerId == documentViewerHandlerId;
  bool get isPresentationViewer => handlerId == presentationViewerHandlerId;

  Map<String, Object?> toJson() => {
    'extension': extension,
    'handlerId': handlerId,
    'category': category,
    'mimeType': mimeType,
    'packageName': packageName,
    'displayName': displayName,
    'activityName': activityName,
    'extensionSpecific': extensionSpecific,
    'extensions': extensions,
  };

  factory DefaultFileApp.fromJson(String extension, Map<String, dynamic> json) {
    return DefaultFileApp(
      extension: extension,
      handlerId: json['handlerId'] as String,
      category: json['category'] as String,
      mimeType: json['mimeType'] as String,
      packageName: json['packageName'] as String?,
      displayName: json['displayName'] as String?,
      activityName: json['activityName'] as String?,
      extensionSpecific: json['extensionSpecific'] as bool? ?? false,
      extensions: (json['extensions'] as List<dynamic>? ?? const [])
          .whereType<String>()
          .toList(),
    );
  }
}

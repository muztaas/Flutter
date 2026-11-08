import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/file_content_provider.dart';
import '../../core/tabs/tabs_manager.dart';
import '../../domain/entities/detected_file_content.dart';
import '../../domain/entities/video_player_item.dart';
import 'open_audio_file.dart';
import 'open_docx_file.dart';
import 'open_pdf_file.dart';
import 'open_pptx_file.dart';
import 'open_spreadsheet_file.dart';
import 'open_video_file.dart';

class DetectedContentRecoveryAction extends ConsumerStatefulWidget {
  const DetectedContentRecoveryAction({
    super.key,
    required this.path,
    required this.currentCategory,
    this.detectedContent,
  });

  final String path;
  final String currentCategory;
  final DetectedFileContent? detectedContent;

  @override
  ConsumerState<DetectedContentRecoveryAction> createState() =>
      _DetectedContentRecoveryActionState();
}

class _DetectedContentRecoveryActionState
    extends ConsumerState<DetectedContentRecoveryAction> {
  late Future<DetectedFileContent> _detectedContentFuture;

  @override
  void initState() {
    super.initState();
    _detectedContentFuture = _detectContent();
  }

  @override
  void didUpdateWidget(covariant DetectedContentRecoveryAction oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) {
      _detectedContentFuture = _detectContent();
    }
  }

  Future<DetectedFileContent> _detectContent() => widget.detectedContent != null
      ? Future.value(widget.detectedContent)
      : ref.read(sniffFileContentProvider)(widget.path);

  @override
  Widget build(BuildContext context) => FutureBuilder<DetectedFileContent>(
    future: _detectedContentFuture,
    builder: (context, snapshot) {
      final detected = snapshot.data;
      if (detected == null ||
          !detected.isKnown ||
          detected.category == widget.currentCategory) {
        return const SizedBox.shrink();
      }
      return TextButton.icon(
        onPressed: () =>
            openDetectedContent(context, ref, widget.path, detected),
        icon: const Icon(Icons.open_in_new),
        label: Text('Open as ${detected.name}'),
      );
    },
  );
}

Future<void> openDetectedContent(
  BuildContext context,
  WidgetRef ref,
  String path,
  DetectedFileContent detected,
) async {
  switch (detected.category) {
    case 'Image':
      TabsManager.instance.openImageViewer(path, imagePaths: [path]);
    case 'Text':
      TabsManager.instance.openTextEditor(path);
    case 'Audio':
      openAudioFile(
        ref,
        path: path,
        queuePaths: [path],
        allowExtensionOverride: true,
      );
    case 'Video':
      await openVideoFile(
        context,
        ref,
        path: path,
        name: _fileName(path),
        playlist: [VideoPlayerItem(path: path, name: _fileName(path))],
        currentIndex: 0,
        useSavedDefaultApps: false,
        mimeTypeOverride: detected.mimeType,
        allowSaveDefault: false,
      );
    case 'Archives':
      TabsManager.instance.openArchiveManagerTab(path);
    case 'Documents':
      if (detected.mimeType == docxMimeType) {
        await openDocxFile(
          context,
          ref,
          path: path,
          name: _fileName(path),
          useSavedDefaultApps: false,
          mimeTypeOverride: detected.mimeType,
          allowSaveDefault: false,
        );
      } else if (detected.mimeType == pptxMimeType) {
        await openPptxFile(
          context,
          ref,
          path: path,
          name: _fileName(path),
          useSavedDefaultApps: false,
          mimeTypeOverride: detected.mimeType,
          allowSaveDefault: false,
        );
      } else if (detected.mimeType == 'text/csv' ||
          detected.mimeType == 'text/tab-separated-values' ||
          detected.mimeType ==
              'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet') {
        await openSpreadsheetFile(
          context,
          ref,
          path: path,
          name: _fileName(path),
          useSavedDefaultApps: false,
          mimeTypeOverride: detected.mimeType,
          allowSaveDefault: false,
        );
      } else {
        await openPdfFile(
          context,
          ref,
          path: path,
          name: _fileName(path),
          useSavedDefaultApps: false,
          mimeTypeOverride: detected.mimeType,
          allowSaveDefault: false,
        );
      }
    default:
      return;
  }
}

String _fileName(String path) =>
    path.split(RegExp(r'[/\\]')).where((part) => part.isNotEmpty).lastOrNull ??
    path;

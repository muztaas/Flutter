import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/branding.dart';
import '../../core/providers/default_file_apps_provider.dart';
import '../../core/providers/open_with_providers.dart';
import '../../core/providers/settings_provider.dart';
import '../../core/tabs/tabs_manager.dart';
import '../../domain/entities/default_file_app.dart';
import '../../domain/entities/open_with_app.dart';
import '../common/open_with_app_option.dart';

Future<bool> openPdfFile(
  BuildContext context,
  WidgetRef ref, {
  required String path,
  required String name,
  bool excludeBuiltIn = false,
  bool? useSavedDefaultApps,
  String? mimeTypeOverride,
  bool allowSaveDefault = true,
}) async {
  final repository = ref.read(openWithRepositoryProvider);
  if (!excludeBuiltIn &&
      (useSavedDefaultApps ??
          ref.read(appSettingsProvider).useSavedDefaultApps)) {
    try {
      final saved = await ref
          .read(defaultFileAppsProvider.notifier)
          .find('.pdf', category: 'Documents');
      if (!context.mounted) return false;
      if (saved?.isPdfViewer == true) {
        TabsManager.instance.openPdfViewerTab(path);
        return true;
      }
      if (saved != null && !saved.isPdfViewer) {
        final apps = await repository.listApps(
          path: path,
          category: 'Documents',
          mimeType: mimeTypeOverride,
        );
        if (!context.mounted) return false;
        final app = apps
            .where(
              (candidate) =>
                  candidate.packageName == saved.packageName &&
                  (saved.activityName == null ||
                      candidate.activityName == saved.activityName),
            )
            .firstOrNull;
        if (app != null) {
          await repository.openFile(
            path: path,
            category: 'Documents',
            packageName: app.packageName,
            activityName: app.activityName,
            mimeType: mimeTypeOverride ?? app.mimeType,
          );
          return true;
        }
        await ref
            .read(defaultFileAppsProvider.notifier)
            .delete(saved.extension);
        if (context.mounted) {
          _showMessage(context, 'The saved app for .pdf files is unavailable.');
        }
      }
    } catch (error) {
      if (context.mounted) {
        _showMessage(context, 'Could not open the saved PDF app: $error');
      }
      return false;
    }
  }

  final List<OpenWithApp> apps;
  try {
    apps = await repository.listApps(
      path: path,
      category: 'Documents',
      mimeType: mimeTypeOverride,
    );
  } catch (error) {
    if (context.mounted) {
      _showMessage(context, 'Could not load PDF apps: $error');
    }
    return false;
  }
  if (!context.mounted) return false;
  if (excludeBuiltIn && apps.isEmpty) {
    _showMessage(context, 'No other installed app can open this PDF.');
    return false;
  }

  final builtIn = const OpenWithApp(
    name: 'PDF Viewer (built-in)',
    packageName: DefaultFileApp.pdfViewerHandlerId,
    mimeType: 'application/pdf',
  );
  final selection = await showDialog<_PdfAppSelection>(
    context: context,
    builder: (dialogContext) {
      var saveAsDefault = false;
      return StatefulBuilder(
        builder: (context, setDialogState) => SimpleDialog(
          title: Text('Open $name with'),
          children: [
            if (!excludeBuiltIn)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(
                  dialogContext,
                  _PdfAppSelection(app: builtIn, saveAsDefault: saveAsDefault),
                ),
                child: Row(
                  children: [
                    Image.asset(
                      Branding.logoPng,
                      width: 28,
                      height: 28,
                      fit: BoxFit.contain,
                    ),
                    const SizedBox(width: 12),
                    const Text('PDF Viewer (built-in)'),
                  ],
                ),
              ),
            for (final app in apps)
              OpenWithAppOption(
                app: mimeTypeOverride == null
                    ? app
                    : OpenWithApp(
                        name: app.name,
                        packageName: app.packageName,
                        mimeType: mimeTypeOverride,
                        applicationName: app.applicationName,
                        activityName: app.activityName,
                        iconBytes: app.iconBytes,
                      ),
                onTap: () => Navigator.pop(
                  dialogContext,
                  _PdfAppSelection(app: app, saveAsDefault: saveAsDefault),
                ),
              ),
            if (!excludeBuiltIn && allowSaveDefault)
              CheckboxListTile(
                title: const Text('Always use this app for .pdf files'),
                value: saveAsDefault,
                onChanged: (value) =>
                    setDialogState(() => saveAsDefault = value ?? false),
              ),
          ],
        ),
      );
    },
  );
  if (selection == null || !context.mounted) return false;

  final isBuiltIn =
      selection.app.packageName == DefaultFileApp.pdfViewerHandlerId;
  if (selection.saveAsDefault && !excludeBuiltIn && allowSaveDefault) {
    try {
      await ref
          .read(defaultFileAppsProvider.notifier)
          .save(
            DefaultFileApp(
              extension: '.pdf',
              handlerId: isBuiltIn
                  ? DefaultFileApp.pdfViewerHandlerId
                  : 'external',
              category: 'Documents',
              mimeType: selection.app.mimeType,
              packageName: isBuiltIn ? null : selection.app.packageName,
              displayName: isBuiltIn ? null : selection.app.name,
              activityName: isBuiltIn ? null : selection.app.activityName,
              extensionSpecific: true,
              extensions: const ['.pdf'],
            ),
          );
    } catch (error) {
      if (context.mounted) {
        _showMessage(context, 'Could not save the PDF default app: $error');
      }
    }
  }

  if (!context.mounted) return false;
  if (isBuiltIn) {
    TabsManager.instance.openPdfViewerTab(path);
    return true;
  }
  try {
    await repository.openFile(
      path: path,
      category: 'Documents',
      packageName: selection.app.packageName,
      activityName: selection.app.activityName,
      mimeType: mimeTypeOverride ?? selection.app.mimeType,
    );
    return true;
  } catch (error) {
    if (context.mounted) _showMessage(context, 'Could not open PDF: $error');
    return false;
  }
}

void _showMessage(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

class _PdfAppSelection {
  const _PdfAppSelection({required this.app, required this.saveAsDefault});

  final OpenWithApp app;
  final bool saveAsDefault;
}

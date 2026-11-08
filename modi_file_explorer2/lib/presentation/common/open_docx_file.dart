import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/branding.dart';
import '../../core/providers/default_file_apps_provider.dart';
import '../../core/providers/open_with_providers.dart';
import '../../core/providers/settings_provider.dart';
import '../../core/tabs/tabs_manager.dart';
import '../../domain/entities/default_file_app.dart';
import '../../domain/entities/open_with_app.dart';
import 'open_with_app_option.dart';

const docxMimeType =
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document';

Future<bool> openDocxFile(
  BuildContext context,
  WidgetRef ref, {
  required String path,
  required String name,
  bool excludeBuiltIn = false,
  bool? useSavedDefaultApps,
  String? mimeTypeOverride,
  bool allowSaveDefault = true,
}) async {
  final mimeType = mimeTypeOverride ?? docxMimeType;
  final repository = ref.read(openWithRepositoryProvider);
  if (!excludeBuiltIn &&
      (useSavedDefaultApps ??
          ref.read(appSettingsProvider).useSavedDefaultApps)) {
    try {
      final saved = await ref
          .read(defaultFileAppsProvider.notifier)
          .find('.docx', category: 'Documents');
      if (!context.mounted) return false;
      if (saved?.isDocumentViewer == true) {
        TabsManager.instance.openDocxViewerTab(path);
        return true;
      }
      if (saved != null && !saved.isDocumentViewer) {
        final apps = await repository.listApps(
          path: path,
          category: 'Documents',
          mimeType: mimeType,
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
            mimeType: mimeType,
          );
          return true;
        }
        await ref
            .read(defaultFileAppsProvider.notifier)
            .delete(saved.extension);
        if (context.mounted) {
          _showMessage(context, 'The saved app for .docx files is unavailable.');
        }
      }
    } catch (error) {
      if (context.mounted) {
        _showMessage(context, 'Could not open the saved document app: $error');
      }
      return false;
    }
  }

  final List<OpenWithApp> apps;
  try {
    apps = await repository.listApps(
      path: path,
      category: 'Documents',
      mimeType: mimeType,
    );
  } catch (error) {
    if (context.mounted) {
      _showMessage(context, 'Could not load document apps: $error');
    }
    return false;
  }
  if (!context.mounted) return false;
  if (excludeBuiltIn && apps.isEmpty) {
    _showMessage(context, 'No other installed app can open this document.');
    return false;
  }

  const builtIn = OpenWithApp(
    name: 'Document Viewer (built-in)',
    packageName: DefaultFileApp.documentViewerHandlerId,
    mimeType: docxMimeType,
  );
  final selection = await showDialog<_DocxSelection>(
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
                  _DocxSelection(builtIn, saveAsDefault),
                ),
                child: Row(
                  children: [
                    Image.asset(
                      Branding.logoPng,
                      width: 32,
                      height: 32,
                      fit: BoxFit.contain,
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Text(
                        'Document Viewer (built-in)',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            for (final app in apps)
              OpenWithAppOption(
                app: OpenWithApp(
                  name: app.name,
                  packageName: app.packageName,
                  mimeType: mimeType,
                  applicationName: app.applicationName,
                  activityName: app.activityName,
                  iconBytes: app.iconBytes,
                ),
                onTap: () => Navigator.pop(
                  dialogContext,
                  _DocxSelection(app, saveAsDefault),
                ),
              ),
            if (!excludeBuiltIn && allowSaveDefault)
              CheckboxListTile(
                title: const Text('Always use this app for .docx files'),
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
  final app = selection.app;
  if (selection.saveAsDefault && allowSaveDefault && !excludeBuiltIn) {
    try {
      await ref
          .read(defaultFileAppsProvider.notifier)
          .save(
            DefaultFileApp(
              extension: '.docx',
              handlerId: app.packageName ==
                      DefaultFileApp.documentViewerHandlerId
                  ? DefaultFileApp.documentViewerHandlerId
                  : 'external',
              category: 'Documents',
              mimeType: mimeType,
              packageName: app.packageName ==
                      DefaultFileApp.documentViewerHandlerId
                  ? null
                  : app.packageName,
              displayName: app.packageName ==
                      DefaultFileApp.documentViewerHandlerId
                  ? null
                  : app.name,
              activityName: app.packageName ==
                      DefaultFileApp.documentViewerHandlerId
                  ? null
                  : app.activityName,
              extensionSpecific: true,
              extensions: const ['.docx'],
            ),
          );
    } catch (error) {
      if (context.mounted) {
        _showMessage(context, 'Could not save the DOCX default app: $error');
      }
    }
  }
  if (!context.mounted) return false;
  if (app.packageName == DefaultFileApp.documentViewerHandlerId) {
    TabsManager.instance.openDocxViewerTab(path);
    return true;
  }
  try {
    await repository.openFile(
      path: path,
      category: 'Documents',
      packageName: app.packageName,
      activityName: app.activityName,
      mimeType: mimeType,
    );
    return true;
  } catch (error) {
    if (context.mounted) _showMessage(context, 'Could not open $name: $error');
    return false;
  }
}

void _showMessage(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

class _DocxSelection {
  const _DocxSelection(this.app, this.saveAsDefault);

  final OpenWithApp app;
  final bool saveAsDefault;
}

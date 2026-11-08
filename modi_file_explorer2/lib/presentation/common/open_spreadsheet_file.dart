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

Future<bool> openSpreadsheetFile(
  BuildContext context,
  WidgetRef ref, {
  required String path,
  required String name,
  bool excludeBuiltIn = false,
  bool? useSavedDefaultApps,
  String? mimeTypeOverride,
  bool allowSaveDefault = true,
}) async {
  final extension = _fileExtension(path);
  const xlsxMimeType =
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
  final isXlsx = extension == '.xlsx' || mimeTypeOverride == xlsxMimeType;
  final mimeType =
      mimeTypeOverride ??
      (isXlsx
          ? xlsxMimeType
          : extension == '.tsv'
          ? 'text/tab-separated-values'
          : 'text/csv');
  final repository = ref.read(openWithRepositoryProvider);
  if (!excludeBuiltIn &&
      (useSavedDefaultApps ??
          ref.read(appSettingsProvider).useSavedDefaultApps)) {
    try {
      final saved = await ref
          .read(defaultFileAppsProvider.notifier)
          .find(extension, category: 'Documents');
      if (!context.mounted) return false;
      if (saved?.isSpreadsheetViewer == true) {
        _openBuiltInSpreadsheet(path, isXlsx: isXlsx);
        return true;
      }
      if (saved?.isTextEditor == true) {
        TabsManager.instance.openTextEditor(path);
        return true;
      }
      if (saved != null && !saved.isSpreadsheetViewer && !saved.isTextEditor) {
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
          _showMessage(
            context,
            'The saved app for $extension files is unavailable.',
          );
        }
      }
    } catch (error) {
      if (context.mounted) {
        _showMessage(
          context,
          'Could not open the saved spreadsheet app: $error',
        );
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
      _showMessage(context, 'Could not load spreadsheet apps: $error');
    }
    return false;
  }
  if (!context.mounted) return false;
  if (excludeBuiltIn && apps.isEmpty) {
    _showMessage(context, 'No other installed app can open this file.');
    return false;
  }

  final builtInSpreadsheet = OpenWithApp(
    name: 'Spreadsheet Viewer (built-in)',
    packageName: DefaultFileApp.spreadsheetViewerHandlerId,
    mimeType: mimeType,
  );
  final builtInTextEditor = const OpenWithApp(
    name: 'Text Editor (built-in)',
    packageName: DefaultFileApp.textEditorHandlerId,
    mimeType: 'text/plain',
  );
  final selection = await showDialog<_SpreadsheetAppSelection>(
    context: context,
    builder: (dialogContext) {
      var saveAsDefault = false;
      return StatefulBuilder(
        builder: (context, setDialogState) => SimpleDialog(
          title: Text('Open $name with'),
          children: [
            if (!excludeBuiltIn)
              _builtInOption(
                app: builtInSpreadsheet,
                onTap: () => Navigator.pop(
                  dialogContext,
                  _SpreadsheetAppSelection(
                    app: builtInSpreadsheet,
                    saveAsDefault: saveAsDefault,
                  ),
                ),
              ),
            if (!excludeBuiltIn && !isXlsx)
              _builtInOption(
                app: builtInTextEditor,
                onTap: () => Navigator.pop(
                  dialogContext,
                  _SpreadsheetAppSelection(
                    app: builtInTextEditor,
                    saveAsDefault: saveAsDefault,
                  ),
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
                  _SpreadsheetAppSelection(
                    app: app,
                    saveAsDefault: saveAsDefault,
                  ),
                ),
              ),
            if (!excludeBuiltIn &&
                allowSaveDefault &&
                (extension == '.csv' ||
                    extension == '.tsv' ||
                    extension == '.xlsx'))
              CheckboxListTile(
                title: Text('Always use this app for $extension files'),
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

  final isSpreadsheetViewer =
      selection.app.packageName == DefaultFileApp.spreadsheetViewerHandlerId;
  final isTextEditor =
      selection.app.packageName == DefaultFileApp.textEditorHandlerId;
  if (selection.saveAsDefault &&
      !excludeBuiltIn &&
      allowSaveDefault &&
      (extension == '.csv' || extension == '.tsv' || extension == '.xlsx')) {
    try {
      await ref
          .read(defaultFileAppsProvider.notifier)
          .save(
            DefaultFileApp(
              extension: extension,
              handlerId: isSpreadsheetViewer
                  ? DefaultFileApp.spreadsheetViewerHandlerId
                  : isTextEditor
                  ? DefaultFileApp.textEditorHandlerId
                  : 'external',
              category: 'Documents',
              mimeType: mimeType,
              packageName: isSpreadsheetViewer || isTextEditor
                  ? null
                  : selection.app.packageName,
              displayName: isSpreadsheetViewer || isTextEditor
                  ? null
                  : selection.app.name,
              activityName: isSpreadsheetViewer || isTextEditor
                  ? null
                  : selection.app.activityName,
              extensionSpecific: true,
              extensions: [extension],
            ),
          );
    } catch (error) {
      if (context.mounted) {
        _showMessage(
          context,
          'Could not save the spreadsheet default app: $error',
        );
      }
    }
  }

  if (!context.mounted) return false;
  if (isSpreadsheetViewer) {
    _openBuiltInSpreadsheet(path, isXlsx: isXlsx);
    return true;
  }
  if (isTextEditor) {
    TabsManager.instance.openTextEditor(path);
    return true;
  }
  try {
    await repository.openFile(
      path: path,
      category: 'Documents',
      packageName: selection.app.packageName,
      activityName: selection.app.activityName,
      mimeType: mimeType,
    );
    return true;
  } catch (error) {
    if (context.mounted) _showMessage(context, 'Could not open $name: $error');
    return false;
  }
}

void _openBuiltInSpreadsheet(String path, {required bool isXlsx}) {
  if (isXlsx) {
    TabsManager.instance.openXlsxViewerTab(path);
  } else {
    TabsManager.instance.openCsvViewerTab(path);
  }
}

Widget _builtInOption({
  required OpenWithApp app,
  required VoidCallback onTap,
}) => SimpleDialogOption(
  onPressed: onTap,
  child: Row(
    children: [
      Image.asset(Branding.logoPng, width: 32, height: 32, fit: BoxFit.contain),
      const SizedBox(width: 12),
      Expanded(child: Text(app.name, maxLines: 2, overflow: TextOverflow.ellipsis)),
    ],
  ),
);

String _fileExtension(String path) {
  final name = path.split(RegExp(r'[/\\]')).last.toLowerCase();
  final dotIndex = name.lastIndexOf('.');
  return dotIndex <= 0 ? '' : name.substring(dotIndex);
}

void _showMessage(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

class _SpreadsheetAppSelection {
  const _SpreadsheetAppSelection({
    required this.app,
    required this.saveAsDefault,
  });

  final OpenWithApp app;
  final bool saveAsDefault;
}

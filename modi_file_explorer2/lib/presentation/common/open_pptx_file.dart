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

const pptxMimeType =
    'application/vnd.openxmlformats-officedocument.presentationml.presentation';

Future<bool> openPptxFile(
  BuildContext context,
  WidgetRef ref, {
  required String path,
  required String name,
  bool excludeBuiltIn = false,
  bool? useSavedDefaultApps,
  String? mimeTypeOverride,
  bool allowSaveDefault = true,
}) async {
  final mimeType = mimeTypeOverride ?? pptxMimeType;
  final repository = ref.read(openWithRepositoryProvider);
  if (!excludeBuiltIn &&
      (useSavedDefaultApps ??
          ref.read(appSettingsProvider).useSavedDefaultApps)) {
    try {
      final saved = await ref
          .read(defaultFileAppsProvider.notifier)
          .find('.pptx', category: 'Documents');
      if (!context.mounted) return false;
      if (saved?.isPresentationViewer == true) {
        TabsManager.instance.openPptxViewerTab(path);
        return true;
      }
      if (saved != null && !saved.isPresentationViewer) {
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
            'The saved app for .pptx files is unavailable.',
          );
        }
      }
    } catch (error) {
      if (context.mounted) {
        _showMessage(
          context,
          'Could not open the saved presentation app: $error',
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
    if (context.mounted)
      _showMessage(context, 'Could not load presentation apps: $error');
    return false;
  }
  if (!context.mounted) return false;
  if (excludeBuiltIn && apps.isEmpty) {
    _showMessage(context, 'No other installed app can open this presentation.');
    return false;
  }

  const builtIn = OpenWithApp(
    name: 'Presentation Viewer (built-in)',
    packageName: DefaultFileApp.presentationViewerHandlerId,
    mimeType: pptxMimeType,
  );
  final selection = await showDialog<_PptxSelection>(
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
                  _PptxSelection(builtIn, saveAsDefault),
                ),
                child: Row(
                  children: [
                    Image.asset(Branding.logoPng, width: 32, height: 32),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Text(
                        'Presentation Viewer (built-in)',
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
                  _PptxSelection(app, saveAsDefault),
                ),
              ),
            if (!excludeBuiltIn && allowSaveDefault)
              CheckboxListTile(
                title: const Text('Always use this app for .pptx files'),
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
      selection.app.packageName == DefaultFileApp.presentationViewerHandlerId;
  if (selection.saveAsDefault && allowSaveDefault && !excludeBuiltIn) {
    try {
      await ref
          .read(defaultFileAppsProvider.notifier)
          .save(
            DefaultFileApp(
              extension: '.pptx',
              handlerId: isBuiltIn
                  ? DefaultFileApp.presentationViewerHandlerId
                  : 'external',
              category: 'Documents',
              mimeType: mimeType,
              packageName: isBuiltIn ? null : selection.app.packageName,
              displayName: isBuiltIn ? null : selection.app.name,
              activityName: isBuiltIn ? null : selection.app.activityName,
              extensionSpecific: true,
              extensions: const ['.pptx'],
            ),
          );
    } catch (error) {
      if (context.mounted) {
        _showMessage(context, 'Could not save the PPTX default app: $error');
      }
    }
  }
  if (!context.mounted) return false;
  if (isBuiltIn) {
    TabsManager.instance.openPptxViewerTab(path);
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

void _showMessage(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

class _PptxSelection {
  const _PptxSelection(this.app, this.saveAsDefault);

  final OpenWithApp app;
  final bool saveAsDefault;
}

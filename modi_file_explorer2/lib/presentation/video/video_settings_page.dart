import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/video_providers.dart';
import 'widgets/video_sort_picker.dart';

class VideoSettingsPage extends ConsumerWidget {
  const VideoSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(videoPageSettingsProvider);
    final controller = ref.read(videoPageSettingsProvider.notifier);

    Future<void> update(VideoPageSettings next) async {
      try {
        await controller.update(next);
      } catch (error) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not save Video settings: $error')),
        );
      }
    }

    return Scrollbar(
      thumbVisibility: true,
      interactive: true,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
        ExpansionTile(
          initiallyExpanded: true,
          title: const Text('List'),
          children: [
            ListTile(
              title: const Text('View mode'),
              subtitle: Wrap(
                spacing: 4,
                children: [
                  _Choice(
                    label: 'Folders',
                    selected: settings.viewMode == 'folders',
                    onTap: () => update(settings.copyWith(viewMode: 'folders')),
                  ),
                  _Choice(
                    label: 'All folders',
                    selected: settings.viewMode == 'allFolders',
                    onTap: () =>
                        update(settings.copyWith(viewMode: 'allFolders')),
                  ),
                  _Choice(
                    label: 'Files',
                    selected: settings.viewMode == 'files',
                    onTap: () => update(settings.copyWith(viewMode: 'files')),
                  ),
                ],
              ),
            ),
            ListTile(
              title: const Text('Layout'),
              subtitle: Wrap(
                spacing: 4,
                children: [
                  _Choice(
                    label: 'List',
                    selected: settings.layout == 'list',
                    onTap: () => update(settings.copyWith(layout: 'list')),
                  ),
                  _Choice(
                    label: 'Grid',
                    selected: settings.layout == 'grid',
                    onTap: () => update(settings.copyWith(layout: 'grid')),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: VideoSortPicker(
                field: settings.sortField,
                ascending: settings.sortAscending,
                onChanged: (field, ascending) => update(
                  settings.copyWith(sortField: field, sortAscending: ascending),
                ),
              ),
            ),
            for (final field in _videoFields)
              SwitchListTile.adaptive(
                title: Text(field.label),
                value: field.value(settings),
                onChanged: (value) => update(field.set(settings, value)),
              ),
            SwitchListTile.adaptive(
              title: const Text('Scroll long names'),
              value: settings.scrollLongNames,
              onChanged: (value) =>
                  update(settings.copyWith(scrollLongNames: value)),
            ),
            ListTile(
              title: const Text('Name character limit'),
              enabled: !settings.scrollLongNames,
              trailing: DropdownButton<int>(
                value: settings.nameCharacterLimit,
                items: const [
                  DropdownMenuItem(value: 1000, child: Text('Full / 1000')),
                  DropdownMenuItem(value: 250, child: Text('250')),
                  DropdownMenuItem(value: 120, child: Text('120')),
                  DropdownMenuItem(value: 100, child: Text('100')),
                  DropdownMenuItem(value: 50, child: Text('50')),
                ],
                onChanged: settings.scrollLongNames
                    ? null
                    : (value) {
                        if (value != null) {
                          update(settings.copyWith(nameCharacterLimit: value));
                        }
                      },
              ),
            ),
          ],
        ),
        ExpansionTile(
          title: const Text('General'),
          children: [
            SwitchListTile.adaptive(
              title: const Text('Display length over thumbnail'),
              value: settings.displayLengthOverThumbnail,
              onChanged: (value) =>
                  update(settings.copyWith(displayLengthOverThumbnail: value)),
            ),
            SwitchListTile.adaptive(
              title: const Text('Show hidden files and folders'),
              value: settings.showHiddenFilesAndFolders,
              onChanged: (value) =>
                  update(settings.copyWith(showHiddenFilesAndFolders: value)),
            ),
            SwitchListTile.adaptive(
              title: const Text('Recognize .nomedia'),
              value: settings.recognizeNomedia,
              onChanged: (value) =>
                  update(settings.copyWith(recognizeNomedia: value)),
            ),
            SwitchListTile.adaptive(
              title: const Text('Show path bar'),
              value: settings.showPathBar,
              onChanged: (value) =>
                  update(settings.copyWith(showPathBar: value)),
            ),
          ],
        ),
        ExpansionTile(
          title: const Text('Player'),
          children: [
            SwitchListTile.adaptive(
              title: const Text('Return to Videos after playing'),
              value: settings.returnToVideosAfterPlaying,
              onChanged: (value) =>
                  update(settings.copyWith(returnToVideosAfterPlaying: value)),
            ),
          ],
        ),
        const ExpansionTile(
          title: Text('Audio'),
          children: [
            ListTile(title: Text('No audio settings are available yet.')),
          ],
        ),
        const ExpansionTile(
          title: Text('Subtitle'),
          children: [
            ListTile(title: Text('No subtitle settings are available yet.')),
          ],
        ),
        ],
      ),
    );
  }
}

class _VideoField {
  const _VideoField(this.label, this.key);

  final String label;
  final String key;

  bool value(VideoPageSettings settings) => switch (key) {
    'thumbnail' => settings.showThumbnail,
    'length' => settings.showLength,
    'fileExtension' => settings.showFileExtension,
    'resolution' => settings.showResolution,
    'size' => settings.showSize,
    'contents' => settings.showContents,
    'playedTime' => settings.showPlayedTime,
    'frameRate' => settings.showFrameRate,
    'path' => settings.showPath,
    'date' => settings.showDate,
    _ => false,
  };

  VideoPageSettings set(VideoPageSettings settings, bool value) =>
      switch (key) {
        'thumbnail' => settings.copyWith(showThumbnail: value),
        'length' => settings.copyWith(showLength: value),
        'fileExtension' => settings.copyWith(showFileExtension: value),
        'resolution' => settings.copyWith(showResolution: value),
        'size' => settings.copyWith(showSize: value),
        'contents' => settings.copyWith(showContents: value),
        'playedTime' => settings.copyWith(showPlayedTime: value),
        'frameRate' => settings.copyWith(showFrameRate: value),
        'path' => settings.copyWith(showPath: value),
        'date' => settings.copyWith(showDate: value),
        _ => settings,
      };
}

const _videoFields = <_VideoField>[
  _VideoField('Thumbnail', 'thumbnail'),
  _VideoField('Length', 'length'),
  _VideoField('File extension', 'fileExtension'),
  _VideoField('Resolution', 'resolution'),
  _VideoField('Size', 'size'),
  _VideoField('Contents', 'contents'),
  _VideoField('Played time', 'playedTime'),
  _VideoField('Frame rate', 'frameRate'),
  _VideoField('Path', 'path'),
  _VideoField('Date', 'date'),
];

class _Choice extends StatelessWidget {
  const _Choice({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ChoiceChip(
    label: Text(label),
    selected: selected,
    onSelected: (_) => onTap(),
    visualDensity: VisualDensity.compact,
    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
  );
}

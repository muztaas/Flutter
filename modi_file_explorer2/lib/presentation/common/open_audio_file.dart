import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/audio_player_provider.dart';
import '../../core/providers/file_type_categories_provider.dart';
import '../../core/tabs/tabs_manager.dart';

TabEntry? openAudioFile(
  WidgetRef ref, {
  required String path,
  List<String>? queuePaths,
  bool allowExtensionOverride = false,
}) {
  final audioCategory = ref
      .read(fileTypeCategoriesProvider)
      .where((category) => category.name == 'Audio')
      .firstOrNull;
  final extensions = {
    ...?audioCategory?.extensions
        .map((extension) => extension.toLowerCase()),
    if (allowExtensionOverride) _extension(path),
  }..remove('');
  return TabsManager.instance.openAudioPlayerTab(
    path,
    extensions: extensions,
    queuePaths: queuePaths,
    repository: ref.read(audioPlayerRepositoryProvider),
  );
}

String _extension(String path) {
  final name = path.split(RegExp(r'[/\\]')).last;
  final separator = name.lastIndexOf('.');
  return separator <= 0 ? '' : name.substring(separator).toLowerCase();
}

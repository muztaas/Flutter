import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/datasources/android/android_audio_player_repository.dart';
import '../../domain/repositories/audio_player_repository.dart';

final audioPlayerRepositoryProvider = Provider<AudioPlayerRepository>((ref) {
  final repository = AndroidAudioPlayerRepository();
  ref.onDispose(repository.dispose);
  return repository;
});

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/datasources/android/android_video_repository.dart';
import '../../data/datasources/android/android_video_player_controller.dart';
import '../../domain/entities/file_type_category.dart';
import '../../domain/entities/video_library_scan.dart';
import '../../domain/entities/video_path_properties.dart';
import '../../domain/entities/video_file.dart';
import '../../domain/entities/video_index_record.dart';
import '../../domain/repositories/video_repository.dart';
import '../../domain/repositories/video_player_repository.dart';
import '../../domain/usecases/scan_video_library.dart';
import '../../domain/usecases/resolve_video_file.dart';
import '../../domain/usecases/set_video_status.dart';
import 'file_type_categories_provider.dart';
import 'storage_providers.dart';

final videoRepositoryProvider = Provider<VideoRepository>(
  (ref) => AndroidVideoRepository(),
);

final videoPlayerControllerProvider = Provider.autoDispose
    .family<VideoPlayerController, String>((ref, sessionId) {
      final controller = AndroidVideoPlayerController();
      ref.onDispose(() => unawaited(controller.dispose()));
      return controller;
    });

final videoInformationProvider = Provider<VideoInformationService>(
  (ref) => VideoInformationService(ref.watch(videoRepositoryProvider)),
);

class VideoInformationService {
  const VideoInformationService(this._repository);

  final VideoRepository _repository;

  Future<VideoIndexRecord?> getInformation(VideoFile video) =>
      _repository.getInformation(video);

  Future<VideoIndexRecord?> getCachedInformation(VideoFile video) =>
      _repository.getCachedInformation(video);

  Future<Map<String, VideoIndexRecord>> getCachedRecords(
    List<VideoFile> videos,
  ) => _repository.getCachedRecords(videos);

  Future<void> synchronizeSnapshot(VideoLibraryScan library) =>
      _repository.synchronizeSnapshot(library);

  Future<void> markPlayed(VideoFile video) => _repository.markPlayed(video);

  Future<Duration> getResumePosition(VideoFile video) =>
      _repository.getResumePosition(video);

  Future<void> saveResumePosition(VideoFile video, Duration position) =>
      _repository.saveResumePosition(video, position);

  Future<List<VideoFile>> recentlyPlayed(List<VideoFile> availableVideos) =>
      _repository.recentlyPlayed(availableVideos);

  Future<void> moveRecord(VideoFile oldVideo, VideoFile newVideo) =>
      _repository.moveRecord(oldVideo, newVideo);

  Future<VideoPathProperties> getPathProperties({
    required String driveId,
    required String relativePath,
  }) => _repository.getPathProperties(
    driveId: driveId,
    relativePath: relativePath,
  );

  Future<void> renamePath({
    required String driveId,
    required String relativePath,
    required String newName,
  }) => _repository.renamePath(
    driveId: driveId,
    relativePath: relativePath,
    newName: newName,
  );

  Future<void> deletePath({
    required String driveId,
    required String relativePath,
  }) => _repository.deletePath(driveId: driveId, relativePath: relativePath);

  Future<bool> pathExists({
    required String driveId,
    required String relativePath,
  }) => _repository.pathExists(driveId: driveId, relativePath: relativePath);

  Future<void> copyPath({
    required String sourceDriveId,
    required String sourceRelativePath,
    required String destinationDriveId,
    required String destinationRelativePath,
    required String targetName,
    required bool replaceExisting,
  }) => _repository.copyPath(
    sourceDriveId: sourceDriveId,
    sourceRelativePath: sourceRelativePath,
    destinationDriveId: destinationDriveId,
    destinationRelativePath: destinationRelativePath,
    targetName: targetName,
    replaceExisting: replaceExisting,
  );

  Future<List<int>?> getThumbnail(
    VideoFile video, {
    required int width,
    required int height,
  }) => _repository.getThumbnail(video, width: width, height: height);

  void cancelPending(VideoFile video) => _repository.cancelPending(video);
}

final scanVideoLibraryProvider = Provider<ScanVideoLibrary>(
  (ref) => ScanVideoLibrary(
    ref.watch(storageRepositoryProvider),
    ref.watch(videoRepositoryProvider),
  ),
);

final resolveVideoFileProvider = Provider<ResolveVideoFile>(
  (ref) => ResolveVideoFile(
    ref.watch(storageRepositoryProvider),
    ref.watch(videoRepositoryProvider),
  ),
);

final setVideoStatusProvider = Provider<SetVideoStatus>(
  (ref) => SetVideoStatus(ref.watch(videoRepositoryProvider)),
);

final videoStatusRefreshProvider = StateProvider<int>((ref) => 0);

final videoStatusRecordsProvider = FutureProvider.autoDispose
    .family<Map<String, VideoIndexRecord>, String>((ref, sessionId) async {
      ref.watch(videoStatusRefreshProvider);
      final library = ref.watch(videoTabProvider(sessionId)).library;
      if (library == null) return const {};
      return ref
          .watch(videoInformationProvider)
          .getCachedRecords(library.videos);
    });

class VideoPageSettings {
  const VideoPageSettings({
    this.viewMode = 'folders',
    this.layout = 'list',
    this.sortField = 'title',
    this.sortAscending = true,
    this.showThumbnail = true,
    this.showLength = true,
    this.showFileExtension = true,
    this.showResolution = true,
    this.showSize = true,
    this.showContents = true,
    this.showPlayedTime = false,
    this.showFrameRate = false,
    this.showPath = false,
    this.showDate = false,
    this.scrollLongNames = true,
    this.nameCharacterLimit = 1000,
    this.displayLengthOverThumbnail = true,
    this.showHiddenFilesAndFolders = false,
    this.recognizeNomedia = true,
    this.returnToVideosAfterPlaying = true,
    this.showPathBar = true,
  });

  final String viewMode;
  final String layout;
  final String sortField;
  final bool sortAscending;
  final bool showThumbnail;
  final bool showLength;
  final bool showFileExtension;
  final bool showResolution;
  final bool showSize;
  final bool showContents;
  final bool showPlayedTime;
  final bool showFrameRate;
  final bool showPath;
  final bool showDate;
  final bool scrollLongNames;
  final int nameCharacterLimit;
  final bool displayLengthOverThumbnail;
  final bool showHiddenFilesAndFolders;
  final bool recognizeNomedia;
  final bool returnToVideosAfterPlaying;
  final bool showPathBar;

  VideoPageSettings copyWith({
    String? viewMode,
    String? layout,
    String? sortField,
    bool? sortAscending,
    bool? showThumbnail,
    bool? showLength,
    bool? showFileExtension,
    bool? showResolution,
    bool? showSize,
    bool? showContents,
    bool? showPlayedTime,
    bool? showFrameRate,
    bool? showPath,
    bool? showDate,
    bool? scrollLongNames,
    int? nameCharacterLimit,
    bool? displayLengthOverThumbnail,
    bool? showHiddenFilesAndFolders,
    bool? recognizeNomedia,
    bool? returnToVideosAfterPlaying,
    bool? showPathBar,
  }) => VideoPageSettings(
    viewMode: viewMode ?? this.viewMode,
    layout: layout ?? this.layout,
    sortField: sortField ?? this.sortField,
    sortAscending: sortAscending ?? this.sortAscending,
    showThumbnail: showThumbnail ?? this.showThumbnail,
    showLength: showLength ?? this.showLength,
    showFileExtension: showFileExtension ?? this.showFileExtension,
    showResolution: showResolution ?? this.showResolution,
    showSize: showSize ?? this.showSize,
    showContents: showContents ?? this.showContents,
    showPlayedTime: showPlayedTime ?? this.showPlayedTime,
    showFrameRate: showFrameRate ?? this.showFrameRate,
    showPath: showPath ?? this.showPath,
    showDate: showDate ?? this.showDate,
    scrollLongNames: scrollLongNames ?? this.scrollLongNames,
    nameCharacterLimit: nameCharacterLimit ?? this.nameCharacterLimit,
    displayLengthOverThumbnail:
        displayLengthOverThumbnail ?? this.displayLengthOverThumbnail,
    showHiddenFilesAndFolders:
        showHiddenFilesAndFolders ?? this.showHiddenFilesAndFolders,
    recognizeNomedia: recognizeNomedia ?? this.recognizeNomedia,
    returnToVideosAfterPlaying:
        returnToVideosAfterPlaying ?? this.returnToVideosAfterPlaying,
    showPathBar: showPathBar ?? this.showPathBar,
  );

  factory VideoPageSettings.fromPreferences(SharedPreferences preferences) {
    const sortFields = {
      'title',
      'date',
      'playedTime',
      'status',
      'length',
      'size',
      'resolution',
      'path',
      'frameRate',
      'type',
    };
    const nameLimits = {1000, 250, 120, 100, 50};
    final viewMode = preferences.getString('video.viewMode') ?? 'folders';
    final layout = preferences.getString('video.layout') ?? 'list';
    final sortField = preferences.getString('video.sortField') ?? 'title';
    final nameCharacterLimit =
        preferences.getInt('video.nameCharacterLimit') ?? 1000;
    return VideoPageSettings(
      viewMode: {'folders', 'allFolders', 'files'}.contains(viewMode)
          ? viewMode
          : 'folders',
      layout: {'list', 'grid'}.contains(layout) ? layout : 'list',
      sortField: sortFields.contains(sortField) ? sortField : 'title',
      sortAscending: preferences.getBool('video.sortAscending') ?? true,
      showThumbnail: preferences.getBool('video.field.thumbnail') ?? true,
      showLength: preferences.getBool('video.field.length') ?? true,
      showFileExtension:
          preferences.getBool('video.field.fileExtension') ?? true,
      showResolution: preferences.getBool('video.field.resolution') ?? true,
      showSize: preferences.getBool('video.field.size') ?? true,
      showContents: preferences.getBool('video.field.contents') ?? true,
      showPlayedTime: preferences.getBool('video.field.playedTime') ?? false,
      showFrameRate: preferences.getBool('video.field.frameRate') ?? false,
      showPath: preferences.getBool('video.field.path') ?? false,
      showDate: preferences.getBool('video.field.date') ?? false,
      scrollLongNames: preferences.getBool('video.scrollLongNames') ?? true,
      nameCharacterLimit: nameLimits.contains(nameCharacterLimit)
          ? nameCharacterLimit
          : 1000,
      displayLengthOverThumbnail:
          preferences.getBool('video.advanced.displayLengthOverThumbnail') ??
          true,
      showHiddenFilesAndFolders:
          preferences.getBool('video.advanced.showHiddenFilesAndFolders') ??
          false,
      recognizeNomedia:
          preferences.getBool('video.advanced.recognizeNomedia') ?? true,
      returnToVideosAfterPlaying:
          preferences.getBool('video.advanced.returnToVideosAfterPlaying') ??
          true,
      showPathBar: preferences.getBool('video.advanced.showPathBar') ?? true,
    );
  }
}

class VideoPageSettingsController extends StateNotifier<VideoPageSettings> {
  VideoPageSettingsController() : super(const VideoPageSettings()) {
    ready = _load();
  }

  late final Future<void> ready;

  Future<void> _load() async {
    final preferences = await SharedPreferences.getInstance();
    state = VideoPageSettings.fromPreferences(preferences);
  }

  Future<void> setShowHiddenFilesAndFolders(bool value) async {
    await update(state.copyWith(showHiddenFilesAndFolders: value));
  }

  Future<void> setRecognizeNomedia(bool value) async {
    await update(state.copyWith(recognizeNomedia: value));
  }

  Future<void> update(VideoPageSettings next) async {
    final previous = state;
    state = next;
    final preferences = await SharedPreferences.getInstance();
    final writes = <Future<bool>>[];
    if (previous.viewMode != next.viewMode) {
      writes.add(preferences.setString('video.viewMode', next.viewMode));
    }
    if (previous.layout != next.layout) {
      writes.add(preferences.setString('video.layout', next.layout));
    }
    if (previous.sortField != next.sortField) {
      writes.add(preferences.setString('video.sortField', next.sortField));
    }
    if (previous.sortAscending != next.sortAscending) {
      writes.add(
        preferences.setBool('video.sortAscending', next.sortAscending),
      );
    }
    if (previous.showThumbnail != next.showThumbnail) {
      writes.add(
        preferences.setBool('video.field.thumbnail', next.showThumbnail),
      );
    }
    if (previous.showLength != next.showLength) {
      writes.add(preferences.setBool('video.field.length', next.showLength));
    }
    if (previous.showFileExtension != next.showFileExtension) {
      writes.add(
        preferences.setBool(
          'video.field.fileExtension',
          next.showFileExtension,
        ),
      );
    }
    if (previous.showResolution != next.showResolution) {
      writes.add(
        preferences.setBool('video.field.resolution', next.showResolution),
      );
    }
    if (previous.showSize != next.showSize) {
      writes.add(preferences.setBool('video.field.size', next.showSize));
    }
    if (previous.showContents != next.showContents) {
      writes.add(
        preferences.setBool('video.field.contents', next.showContents),
      );
    }
    if (previous.showPlayedTime != next.showPlayedTime) {
      writes.add(
        preferences.setBool('video.field.playedTime', next.showPlayedTime),
      );
    }
    if (previous.showFrameRate != next.showFrameRate) {
      writes.add(
        preferences.setBool('video.field.frameRate', next.showFrameRate),
      );
    }
    if (previous.showPath != next.showPath) {
      writes.add(preferences.setBool('video.field.path', next.showPath));
    }
    if (previous.showDate != next.showDate) {
      writes.add(preferences.setBool('video.field.date', next.showDate));
    }
    if (previous.scrollLongNames != next.scrollLongNames) {
      writes.add(
        preferences.setBool('video.scrollLongNames', next.scrollLongNames),
      );
    }
    if (previous.nameCharacterLimit != next.nameCharacterLimit) {
      writes.add(
        preferences.setInt('video.nameCharacterLimit', next.nameCharacterLimit),
      );
    }
    if (previous.displayLengthOverThumbnail !=
        next.displayLengthOverThumbnail) {
      writes.add(
        preferences.setBool(
          'video.advanced.displayLengthOverThumbnail',
          next.displayLengthOverThumbnail,
        ),
      );
    }
    if (previous.showHiddenFilesAndFolders != next.showHiddenFilesAndFolders) {
      writes.add(
        preferences.setBool(
          'video.advanced.showHiddenFilesAndFolders',
          next.showHiddenFilesAndFolders,
        ),
      );
    }
    if (previous.recognizeNomedia != next.recognizeNomedia) {
      writes.add(
        preferences.setBool(
          'video.advanced.recognizeNomedia',
          next.recognizeNomedia,
        ),
      );
    }
    if (previous.returnToVideosAfterPlaying !=
        next.returnToVideosAfterPlaying) {
      writes.add(
        preferences.setBool(
          'video.advanced.returnToVideosAfterPlaying',
          next.returnToVideosAfterPlaying,
        ),
      );
    }
    if (previous.showPathBar != next.showPathBar) {
      writes.add(
        preferences.setBool('video.advanced.showPathBar', next.showPathBar),
      );
    }
    final results = await Future.wait(writes);
    if (results.any((success) => !success)) {
      throw StateError('At least one Video setting could not be saved.');
    }
  }
}

final videoPageSettingsProvider =
    StateNotifierProvider<VideoPageSettingsController, VideoPageSettings>(
      (ref) => VideoPageSettingsController(),
    );

class VideoLibraryTabState {
  const VideoLibraryTabState({
    this.library,
    this.folderPath = '',
    this.isLoading = false,
    this.permissionDenied = false,
    this.error,
    this.hasLoaded = false,
  });

  final VideoLibraryScan? library;
  final String folderPath;
  final bool isLoading;
  final bool permissionDenied;
  final Object? error;
  final bool hasLoaded;

  List<String> get pathSegments => folderPath.isEmpty
      ? const []
      : folderPath.split('/').where((segment) => segment.isNotEmpty).toList();

  VideoLibraryTabState copyWith({
    VideoLibraryScan? library,
    String? folderPath,
    bool? isLoading,
    bool? permissionDenied,
    Object? error,
    bool clearError = false,
    bool? hasLoaded,
  }) => VideoLibraryTabState(
    library: library ?? this.library,
    folderPath: folderPath ?? this.folderPath,
    isLoading: isLoading ?? this.isLoading,
    permissionDenied: permissionDenied ?? this.permissionDenied,
    error: clearError ? null : error ?? this.error,
    hasLoaded: hasLoaded ?? this.hasLoaded,
  );
}

class VideoTabController extends StateNotifier<VideoLibraryTabState> {
  VideoTabController(this._scanLibrary, this._extensions, this._repository)
    : super(const VideoLibraryTabState());

  final Future<VideoLibraryScan?> Function(Set<String> extensions) _scanLibrary;
  final Future<Set<String>> Function() _extensions;
  final VideoRepository _repository;
  bool _loadStarted = false;

  Future<void> load({
    required bool permissionGranted,
    String? initialDriveId,
    String initialRelativePath = '',
    required VideoPageSettings settings,
  }) async {
    if (_loadStarted) return;
    _loadStarted = true;
    await _scan(
      permissionGranted: permissionGranted,
      requestedDriveId: initialDriveId,
      requestedPath: initialRelativePath,
      settings: settings,
    );
  }

  Future<void> refresh({
    required bool permissionGranted,
    required VideoPageSettings settings,
  }) => _scan(
    permissionGranted: permissionGranted,
    requestedDriveId: state.library?.drive.id,
    requestedPath: state.folderPath,
    settings: settings,
  );

  Future<void> _scan({
    required bool permissionGranted,
    required String? requestedDriveId,
    required String requestedPath,
    required VideoPageSettings settings,
  }) async {
    if (!permissionGranted) {
      state = state.copyWith(
        isLoading: false,
        permissionDenied: true,
        hasLoaded: true,
        clearError: true,
      );
      return;
    }
    state = state.copyWith(
      isLoading: true,
      permissionDenied: false,
      clearError: true,
    );
    try {
      final library = await _scanLibrary(await _extensions());
      if (library == null) {
        state = state.copyWith(
          library: null,
          folderPath: '',
          isLoading: false,
          hasLoaded: true,
          error: StateError('Internal storage is unavailable.'),
        );
        return;
      }
      await _repository.synchronizeSnapshot(library);
      final requestedSegments = requestedPath
          .replaceAll('\\', '/')
          .split('/')
          .where((segment) => segment.isNotEmpty)
          .toList();
      final canRestoreDrive =
          requestedDriveId == null || requestedDriveId == library.drive.id;
      final visibleFolderPaths = _visibleFolderPaths(library, settings);
      var restorePath = canRestoreDrive ? requestedSegments.join('/') : '';
      while (restorePath.isNotEmpty &&
          !visibleFolderPaths.contains(restorePath)) {
        requestedSegments.removeLast();
        restorePath = requestedSegments.join('/');
      }
      state = state.copyWith(
        library: library,
        folderPath: restorePath,
        isLoading: false,
        hasLoaded: true,
        clearError: true,
      );
    } catch (error) {
      state = state.copyWith(isLoading: false, hasLoaded: true, error: error);
    }
  }

  void openFolder(String relativePath) {
    if (state.library == null) return;
    state = state.copyWith(folderPath: relativePath);
  }

  void returnToRoot() {
    if (state.folderPath.isEmpty) return;
    state = state.copyWith(folderPath: '');
  }

  void reconcileVisibility(VideoPageSettings settings) {
    final library = state.library;
    if (library == null) return;
    final visiblePaths = _visibleFolderPaths(library, settings);
    final segments = state.pathSegments;
    while (segments.isNotEmpty && !visiblePaths.contains(segments.join('/'))) {
      segments.removeLast();
    }
    state = state.copyWith(folderPath: segments.join('/'));
  }

  void goUp() {
    final segments = state.pathSegments;
    if (segments.isEmpty) return;
    state = state.copyWith(
      folderPath: segments.take(segments.length - 1).join('/'),
    );
  }

  void reportFailure(Object error) {
    state = state.copyWith(isLoading: false, hasLoaded: true, error: error);
  }
}

final videoTabProvider = StateNotifierProvider.autoDispose
    .family<VideoTabController, VideoLibraryTabState, String>((ref, _) {
      Future<Set<String>> videoExtensions() async {
        await ref.read(fileTypeCategoriesProvider.notifier).ready;
        final categories = ref.read(fileTypeCategoriesProvider);
        return categories
                .where((category) => category.name == 'Video')
                .firstOrNull
                ?.extensions
                .map(FileTypeCategory.normalizeExtension)
                .where((extension) => extension.isNotEmpty)
                .toSet() ??
            <String>{};
      }

      return VideoTabController(
        (extensions) => ref.read(scanVideoLibraryProvider)(extensions),
        videoExtensions,
        ref.read(videoRepositoryProvider),
      );
    });

Set<String> _visibleFolderPaths(
  VideoLibraryScan library,
  VideoPageSettings settings,
) {
  final folders = {
    for (final folder in library.folders)
      if ((settings.showHiddenFilesAndFolders || !folder.isHidden) &&
          (!settings.recognizeNomedia || !folder.isInsideNomedia))
        folder.relativePath: folder,
  };
  final visiblePaths = <String>{};
  for (final video in library.videos) {
    if (!(settings.showHiddenFilesAndFolders || !video.isHidden) ||
        (settings.recognizeNomedia && video.isInsideNomedia)) {
      continue;
    }
    var path = video.relativePath;
    final separator = path.lastIndexOf('/');
    path = separator < 0 ? '' : path.substring(0, separator);
    while (path.isNotEmpty) {
      if (folders.containsKey(path)) visiblePaths.add(path);
      final parentSeparator = path.lastIndexOf('/');
      path = parentSeparator < 0 ? '' : path.substring(0, parentSeparator);
    }
  }
  return visiblePaths;
}

bool videoSortNeedsInformation(String sortField) =>
    sortField == 'length' ||
    sortField == 'resolution' ||
    sortField == 'frameRate';

class VideoIndexingState {
  const VideoIndexingState({
    this.isIndexing = false,
    this.completed = 0,
    this.total = 0,
    this.records = const {},
    this.error,
  });

  final bool isIndexing;
  final int completed;
  final int total;
  final Map<String, VideoIndexRecord> records;
  final Object? error;
}

class VideoIndexingController extends StateNotifier<VideoIndexingState> {
  VideoIndexingController(this._service) : super(const VideoIndexingState());

  final VideoInformationService _service;
  int _generation = 0;
  List<VideoFile>? _videos;
  VideoFile? _currentVideo;

  void start(List<VideoFile> videos) {
    if (identical(_videos, videos)) return;
    if (_videos != null) cancelWork();
    _videos = videos;
    final generation = ++_generation;
    state = VideoIndexingState(
      isIndexing: videos.isNotEmpty,
      total: videos.length,
    );
    unawaited(_index(videos, generation));
  }

  void stop() {
    if (_videos == null && !state.isIndexing) return;
    cancelWork();
    state = const VideoIndexingState();
  }

  void cancelWork() {
    _generation++;
    _videos = null;
    final currentVideo = _currentVideo;
    if (currentVideo != null) _service.cancelPending(currentVideo);
    _currentVideo = null;
  }

  Future<void> _index(List<VideoFile> videos, int generation) async {
    var completed = 0;
    Object? error;
    final records = Map<String, VideoIndexRecord>.from(state.records);
    for (final video in videos) {
      if (generation != _generation) return;
      _currentVideo = video;
      try {
        final cached = await _service.getCachedInformation(video);
        if (generation != _generation) return;
        final record = cached?.information != null
            ? cached
            : await _service.getInformation(video);
        if (generation != _generation) return;
        if (record != null) records[video.relativePath] = record;
      } catch (caught) {
        if (generation != _generation) return;
        error = caught;
      } finally {
        _currentVideo = null;
      }
      completed++;
      if (completed % 50 == 0 || completed == videos.length) {
        state = VideoIndexingState(
          isIndexing: completed < videos.length,
          completed: completed,
          total: videos.length,
          records: Map.unmodifiable(records),
          error: error,
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    if (generation == _generation) {
      state = VideoIndexingState(
        completed: completed,
        total: videos.length,
        records: Map.unmodifiable(records),
        error: error,
      );
    }
  }
}

final videoIndexingProvider = StateNotifierProvider.autoDispose
    .family<VideoIndexingController, VideoIndexingState, String>((ref, _) {
      final controller = VideoIndexingController(
        ref.watch(videoInformationProvider),
      );
      ref.onDispose(controller.cancelWork);
      return controller;
    });

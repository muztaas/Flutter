enum AudioPlayMode {
  singleTrack,
  folder,
}

extension AudioPlayModeLabel on AudioPlayMode {
  String get label => switch (this) {
    AudioPlayMode.singleTrack => 'This audio',
    AudioPlayMode.folder => 'All in folder',
  };
}

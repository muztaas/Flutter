import 'dart:async';
import 'dart:io';

enum FileChangeKind { created, deleted, renamed, modified, refreshRequired }

class FileChange {
  const FileChange({
    required this.kind,
    this.path,
    this.oldPath,
    this.newPath,
    this.folderPath,
  });

  final FileChangeKind kind;
  final String? path;
  final String? oldPath;
  final String? newPath;
  final String? folderPath;

  Set<String> get affectedFolders {
    final folders = <String>{};
    if (folderPath != null) folders.add(folderPath!);
    if (path != null) folders.add(File(path!).parent.path);
    if (oldPath != null) folders.add(File(oldPath!).parent.path);
    if (newPath != null) folders.add(File(newPath!).parent.path);
    return folders;
  }

  Set<String> get changedPaths => {
    ?path,
    ?oldPath,
    ?newPath,
  };

  factory FileChange.refreshFolder(String path) => FileChange(
    kind: FileChangeKind.refreshRequired,
    folderPath: path,
  );
}

class FileChangeEvent {
  const FileChangeEvent(this.changes);

  final List<FileChange> changes;

  Set<String> get affectedFolders => {
    for (final change in changes) ...change.affectedFolders,
  };

  Set<String> get changedPaths => {
    for (final change in changes) ...change.changedPaths,
  };
}

class FileChangeNotifier {
  FileChangeNotifier._();

  static final FileChangeNotifier instance = FileChangeNotifier._();
  static const _coalesceDelay = Duration(milliseconds: 300);
  static const _missingReportWindow = Duration(seconds: 2);

  final StreamController<FileChangeEvent> _events =
      StreamController<FileChangeEvent>.broadcast();
  final List<FileChange> _pendingChanges = [];
  final Map<String, DateTime> _lastMissingReports = {};
  Timer? _dispatchTimer;

  Stream<FileChangeEvent> get changes => _events.stream;

  void publish(Iterable<FileChange> changes) {
    _pendingChanges.addAll(changes);
    if (_pendingChanges.isEmpty) return;
    _dispatchTimer?.cancel();
    _dispatchTimer = Timer(_coalesceDelay, _dispatch);
  }

  void reportMissing(String path) {
    final parent = File(path).parent.path;
    final now = DateTime.now();
    final lastReported = _lastMissingReports[parent];
    if (lastReported != null &&
        now.difference(lastReported) < _missingReportWindow) {
      return;
    }
    _lastMissingReports.removeWhere(
      (_, reportedAt) => now.difference(reportedAt) >= _missingReportWindow,
    );
    _lastMissingReports[parent] = now;
    publish([
      FileChange(kind: FileChangeKind.refreshRequired, path: path),
    ]);
  }

  void _dispatch() {
    _dispatchTimer = null;
    if (_pendingChanges.isEmpty || _events.isClosed) return;
    final changes = List<FileChange>.unmodifiable(_pendingChanges);
    _pendingChanges.clear();
    _events.add(FileChangeEvent(changes));
  }
}

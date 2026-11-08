import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

enum RefreshPriority { visiblePage, openPages, prefetch, maintenance }

class RefreshCancelled implements Exception {
  const RefreshCancelled();
}

class RefreshCancellationToken {
  bool _isCancelled = false;

  bool get isCancelled => _isCancelled;

  void cancel() => _isCancelled = true;

  void throwIfCancelled() {
    if (_isCancelled) throw const RefreshCancelled();
  }
}

class RefreshWorkResult<T> {
  const RefreshWorkResult(this.value, {this.changeCount = 0});

  final T value;
  final int changeCount;
}

class RefreshCoordinator with WidgetsBindingObserver {
  RefreshCoordinator._() {
    WidgetsBinding.instance.addObserver(this);
  }

  static final RefreshCoordinator instance = RefreshCoordinator._();
  static const int _maximumConcurrent = 2;

  final Map<String, _RefreshJob<Object?>> _jobs = {};
  final List<_RefreshJob<Object?>> _queue = [];
  int _running = 0;
  int _sequence = 0;
  bool _appIsForeground = true;
  bool _lowBattery = false;
  bool _batterySaver = false;

  Future<T> run<T>({
    required String scope,
    required Object owner,
    required RefreshPriority priority,
    required Future<RefreshWorkResult<T>> Function(
      RefreshCancellationToken token,
    )
    work,
  }) {
    final existing = _jobs[scope];
    if (existing != null) {
      existing.owners.add(owner);
      if (priority.index < existing.priority.index) {
        existing.priority = priority;
        _sortQueue();
      }
      return existing.future.then((result) => result as T);
    }
    if (priority == RefreshPriority.prefetch && !_canPrefetch) {
      return Future<T>.error(const RefreshCancelled());
    }
    final job = _RefreshJob<T>(
      scope: scope,
      owner: owner,
      priority: priority,
      sequence: _sequence++,
      work: work,
    );
    _jobs[scope] = job as _RefreshJob<Object?>;
    _queue.add(job as _RefreshJob<Object?>);
    _sortQueue();
    _pump();
    return job.future.then((result) => result as T);
  }

  void cancelOwner(Object owner) {
    for (final job in List<_RefreshJob<Object?>>.of(_jobs.values)) {
      job.owners.remove(owner);
      if (job.owners.isNotEmpty) continue;
      job.token.cancel();
      if (!job.isRunning) {
        _queue.remove(job);
        _jobs.remove(job.scope);
        if (!job.completer.isCompleted) {
          job.completer.completeError(const RefreshCancelled());
        }
      }
    }
    _pump();
  }

  void updatePowerConstraints({
    required bool lowBattery,
    required bool batterySaver,
  }) {
    _lowBattery = lowBattery;
    _batterySaver = batterySaver;
    if (!_canPrefetch) {
      for (final job in List<_RefreshJob<Object?>>.of(_jobs.values)) {
        if (job.priority != RefreshPriority.prefetch) continue;
        job.token.cancel();
        if (!job.isRunning) {
          _queue.remove(job);
          _jobs.remove(job.scope);
          if (!job.completer.isCompleted) {
            job.completer.completeError(const RefreshCancelled());
          }
        }
      }
    }
    _pump();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appIsForeground = state == AppLifecycleState.resumed;
    if (!_appIsForeground) {
      for (final job in List<_RefreshJob<Object?>>.of(_jobs.values)) {
        if (job.priority == RefreshPriority.prefetch) {
          job.token.cancel();
          if (!job.isRunning) {
            _queue.remove(job);
            _jobs.remove(job.scope);
            if (!job.completer.isCompleted) {
              job.completer.completeError(const RefreshCancelled());
            }
          }
        }
      }
    }
    _pump();
  }

  bool get _canPrefetch => _appIsForeground && !_lowBattery && !_batterySaver;

  void _sortQueue() {
    _queue.sort((left, right) {
      final priority = left.priority.index.compareTo(right.priority.index);
      return priority != 0 ? priority : left.sequence.compareTo(right.sequence);
    });
  }

  void _pump() {
    while (_running < _maximumConcurrent && _queue.isNotEmpty) {
      final nextIndex = _queue.indexWhere(
        (job) => job.priority != RefreshPriority.prefetch || _canPrefetch,
      );
      if (nextIndex < 0) return;
      final next = _queue.removeAt(nextIndex);
      if (next.token.isCancelled) continue;
      next.isRunning = true;
      _running++;
      unawaited(_execute(next));
    }
  }

  Future<void> _execute(_RefreshJob<Object?> job) async {
    final stopwatch = Stopwatch()..start();
    try {
      job.token.throwIfCancelled();
      final result = await job.work(job.token);
      job.token.throwIfCancelled();
      if (!job.completer.isCompleted) job.completer.complete(result.value);
      if (kDebugMode) {
        debugPrint(
          '[RefreshCoordinator] scope=${job.scope} '
          'durationMs=${stopwatch.elapsedMilliseconds} '
          'changes=${result.changeCount}',
        );
      }
    } catch (error, stackTrace) {
      if (!job.completer.isCompleted) {
        job.completer.completeError(error, stackTrace);
      }
    } finally {
      stopwatch.stop();
      _jobs.remove(job.scope);
      _running--;
      _pump();
    }
  }
}

class _RefreshJob<T> {
  _RefreshJob({
    required this.scope,
    required Object owner,
    required this.priority,
    required this.sequence,
    required Future<RefreshWorkResult<T>> Function(
      RefreshCancellationToken token,
    )
    work,
  }) : owners = {owner},
       work = work,
       completer = Completer<Object?>();

  final String scope;
  final Set<Object> owners;
  final int sequence;
  final Future<RefreshWorkResult<T>> Function(RefreshCancellationToken token)
  work;
  final Completer<Object?> completer;
  final RefreshCancellationToken token = RefreshCancellationToken();
  RefreshPriority priority;
  bool isRunning = false;

  Future<Object?> get future => completer.future;
}

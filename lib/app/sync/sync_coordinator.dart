// ignore_for_file: prefer_initializing_formals
import 'dart:async';

import '../backup/backup_settings.dart';
import 'sync_engine.dart';

/// Coordinates sync lifecycle: debounces local mutations, serializes concurrent
/// triggers, and gates automatic runs on transport mode.
///
/// Designed for testability: takes a run function callback and a mode getter,
/// allowing tests to verify debouncing and trigger semantics without a real
/// WebDAV server or controller dependency.
class SyncCoordinator {
  SyncCoordinator({
    required BackupTransportMode Function() getTransportMode,
    required Future<SyncRunResult> Function(SyncTrigger trigger) runSync,
    Duration debounceDuration = const Duration(milliseconds: 500),
    void Function(Object error)? onError,
  }) : _getTransportMode = getTransportMode,
       _runSync = runSync,
       _debounceDuration = debounceDuration,
       _onError = onError;

  final BackupTransportMode Function() _getTransportMode;
  final Future<SyncRunResult> Function(SyncTrigger trigger) _runSync;
  final Duration _debounceDuration;
  final void Function(Object error)? _onError;

  Timer? _debounceTimer;
  Future<SyncRunResult>? _activeFuture;
  bool _pendingRerun = false;
  SyncTrigger? _pendingTrigger;
  final List<Completer<SyncRunResult>> _pendingWaiters = [];

  /// Whether a sync run is currently active.
  bool get isRunning => _activeFuture != null;

  /// App startup: trigger immediate sync in autoSync mode.
  Future<void> onStartup() async {
    if (_getTransportMode() != BackupTransportMode.autoSync) {
      return;
    }
    await _triggerRun(SyncTrigger.startup);
  }

  /// App resumed from background: trigger immediate sync in autoSync mode.
  Future<void> onResumed() async {
    if (_getTransportMode() != BackupTransportMode.autoSync) {
      return;
    }
    await _triggerRun(SyncTrigger.resumed);
  }

  /// Local mutation occurred: debounce and trigger sync in autoSync mode.
  void onLocalMutation() {
    if (_getTransportMode() != BackupTransportMode.autoSync) {
      return;
    }
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounceDuration, () {
      unawaited(_triggerRun(SyncTrigger.localMutation));
    });
  }

  /// Manual user sync: bypass debounce, run regardless of mode.
  Future<SyncRunResult> runManual() {
    _debounceTimer?.cancel();
    return _triggerRun(SyncTrigger.manual);
  }

  /// Dispose and cancel pending work.
  void dispose() {
    _debounceTimer?.cancel();
    _debounceTimer = null;
  }

  /// Trigger a sync run: if already running, queue for rerun after completion.
  Future<SyncRunResult> _triggerRun(SyncTrigger trigger) {
    final completer = Completer<SyncRunResult>();
    _pendingWaiters.add(completer);

    // Track the trigger type (upgrade to higher priority if needed)
    if (_pendingTrigger == null ||
        trigger == SyncTrigger.manual ||
        (trigger == SyncTrigger.startup &&
            _pendingTrigger != SyncTrigger.manual) ||
        (trigger == SyncTrigger.resumed &&
            _pendingTrigger == SyncTrigger.localMutation)) {
      _pendingTrigger = trigger;
    }

    if (_activeFuture == null) {
      _drainQueue();
    } else {
      _pendingRerun = true;
    }

    return completer.future;
  }

  /// Drain the pending waiters queue: run sync until no more pending work.
  Future<void> _drainQueue() async {
    while (_pendingWaiters.isNotEmpty || _pendingRerun) {
      _pendingRerun = false;
      final trigger = _pendingTrigger ?? SyncTrigger.manual;
      _pendingTrigger = null;

      // Snapshot waiters before the run
      final waitersBeforeRun = List<Completer<SyncRunResult>>.from(
        _pendingWaiters,
      );
      _pendingWaiters.clear();

      try {
        _activeFuture = _runSync(trigger);
        final result = await _activeFuture!;

        // Settle all waiters that were present before this run
        for (final waiter in waitersBeforeRun) {
          if (!waiter.isCompleted) {
            waiter.complete(result);
          }
        }
      } catch (error) {
        _onError?.call(error);

        // Settle waiters with an error result
        final errorResult = SyncRunResult(
          uploaded: 0,
          downloaded: 0,
          conflicts: 0,
          pending: 0,
          errorCode: error.toString(),
        );

        for (final waiter in waitersBeforeRun) {
          if (!waiter.isCompleted) {
            waiter.complete(errorResult);
          }
        }
      } finally {
        _activeFuture = null;
      }

      // If new work arrived during the run, continue draining
      if (!_pendingRerun && _pendingWaiters.isEmpty) {
        break;
      }
    }
  }
}

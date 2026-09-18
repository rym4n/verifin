import 'dart:async';
import 'dart:math';
import '../../local_storage/local_storage.dart';
import '../veri_fin_controller.dart';
import 'sync_clock.dart';
import 'sync_conflict.dart';
import 'sync_change_tracker.dart';
import 'sync_coordinator.dart';
import 'sync_engine.dart';
import 'sync_store.dart';
import 'sync_models.dart';
import 'webdav_sync_transport.dart';

/// One process-owned clock, tracker and engine, shared by all triggers.
class SyncRuntime {
  SyncRuntime._(this.controller, this.clock, this.tracker, this.engine) {
    coordinator = SyncCoordinator(
      getTransportMode: () => controller.backupTransportMode,
      runSync: run,
    );
    controller.syncChangeTracker = tracker;
    controller.syncCoordinator = coordinator;
    controller.onSyncChanged = coordinator.onLocalMutation;
  }
  final VeriFinController controller;
  final SyncClock clock;
  final SyncChangeTracker tracker;
  final SyncEngine engine;
  late final SyncCoordinator coordinator;
  late final SyncRepository _repository;
  bool _disposed = false;
  Future<void> _operationTail = Future<void>.value();
  Future<T> _serialize<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _operationTail = _operationTail.then((_) async {
      try {
        completer.complete(await action());
      } catch (error, stack) {
        completer.completeError(error, stack);
      }
    });
    return completer.future;
  }

  Future<void> resolveConflict(String id, ConflictResolution resolution) =>
      _serialize(() => engine.resolveConflict(id, resolution));
  static Future<SyncRuntime> create({
    required VeriFinController controller,
    required SyncRepository repository,
    required LocalKeyValueStore store,
    required WebdavSyncTransport transport,
  }) async {
    final persisted = await repository.loadDeviceState();
    final clock = persisted.deviceId.isEmpty
        ? await SyncClock.create(store)
        : SyncClock.restore(
            deviceId: persisted.deviceId,
            nextSequence: persisted.nextSequence,
            knownVector: persisted.knownVector,
          );
    final tracker = SyncChangeTracker(
      controller: controller,
      repository: repository,
      clock: clock,
    );
    final engine = SyncEngine(
      repository: repository,
      transport: transport,
      controller: controller,
      clock: clock,
      config: controller.webdavConfig,
      passphrase: controller.backupPassphrase,
    );
    await repository.saveDeviceState(clock.getState());
    return SyncRuntime._(controller, clock, tracker, engine)
      .._repository = repository;
  }

  Future<SyncRunResult> run(SyncTrigger trigger) =>
      _serialize(() => _run(trigger));
  Future<SyncRunResult> _run(SyncTrigger trigger) async {
    final runLog = _SyncRunLog(controller, trigger);
    runLog.start();
    if (_disposed) {
      const result = SyncRunResult(
        uploaded: 0,
        downloaded: 0,
        conflicts: 0,
        pending: 0,
        errorCode: 'disposed',
      );
      runLog.finish(result);
      return result;
    }
    engine.updateConfig(
      controller.webdavConfig.isConfigured ? controller.webdavConfig : null,
    );
    engine.updatePassphrase(controller.backupPassphrase);
    try {
      await runLog.phase(SyncPhase.prepare, () async {
        await controller.waitForPendingWrites();
        await controller.applySyncPreferenceJournal();
      });
      await runLog.phase(SyncPhase.initialize, () async {});
      await runLog.phase(SyncPhase.reconcile, tracker.reconcile);
      final result = await engine.runSnapshot(
        trigger: trigger,
        onPhase: runLog.reportPhase,
      );
      await _recordErrorSafely(result.errorCode, runLog);
      runLog.finish(result);
      return result;
    } catch (error) {
      await _recordErrorSafely(syncErrorCode(error), runLog);
      final result = SyncRunResult(
        uploaded: 0,
        downloaded: 0,
        conflicts: 0,
        pending: 0,
        errorCode: syncErrorCode(error),
      );
      runLog.finish(result);
      return result;
    }
  }

  Future<void> _recordErrorSafely(String? code, _SyncRunLog runLog) async {
    try {
      await _recordError(code);
    } catch (_) {
      runLog.recordStatusFailure();
    }
  }

  Future<void> _recordError(String? code) async {
    final previous = await _repository.loadScanState();
    await _repository.saveScanState(
      SyncScanState(
        contiguousSequences: previous.contiguousSequences,
        gaps: previous.gaps,
        lastSuccess: code == null ? DateTime.now() : previous.lastSuccess,
        lastErrorCode: code,
        retryCount: code == null ? 0 : previous.retryCount + 1,
      ),
    );
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    coordinator.dispose();
    tracker.dispose();
    controller.syncChangeTracker = null;
    controller.syncCoordinator = null;
    controller.onSyncChanged = null;
  }
}

class _SyncRunLog {
  _SyncRunLog(this._controller, this._trigger) : runId = _newRunId();

  final VeriFinController _controller;
  final SyncTrigger _trigger;
  final String runId;

  void start() {
    _controller.logger?.info(
      '同步开始 run=$runId trigger=${_trigger.name}',
      source: 'sync',
    );
  }

  Future<T> phase<T>(SyncPhase phase, Future<T> Function() action) async {
    reportPhase(phase, SyncPhaseState.start, null);
    try {
      final result = await action();
      reportPhase(phase, SyncPhaseState.success, null);
      return result;
    } catch (error) {
      reportPhase(phase, SyncPhaseState.error, error);
      rethrow;
    }
  }

  void reportPhase(SyncPhase phase, SyncPhaseState state, Object? error) {
    final errorCode = error == null ? '' : ' errorCode=${syncErrorCode(error)}';
    final message =
        '同步阶段 run=$runId phase=${phase.logValue} '
        'state=${state.name}$errorCode';
    if (state == SyncPhaseState.error) {
      _controller.logger?.error(message, source: 'sync');
      if (error is WebdavException && error.diagnostic != null) {
        _controller.logger?.error(
          'WebDAV失败 run=$runId phase=${phase.logValue} '
          '${error.safeLogDetails}',
          source: 'sync',
        );
      } else if (error is WebdavFileCollision && error.diagnostic != null) {
        _controller.logger?.error(
          'WebDAV失败 run=$runId phase=${phase.logValue} '
          '${error.safeLogDetails}',
          source: 'sync',
        );
      }
    } else {
      _controller.logger?.info(message, source: 'sync');
    }
  }

  void finish(SyncRunResult result) {
    final message =
        '同步结束 run=$runId uploaded=${result.uploaded} '
        'downloaded=${result.downloaded} conflicts=${result.conflicts} '
        'pending=${result.pending} errorCode=${result.errorCode ?? 'none'}';
    if (result.errorCode == null) {
      _controller.logger?.info(message, source: 'sync');
    } else {
      _controller.logger?.error(message, source: 'sync');
    }
  }

  void recordStatusFailure() {
    _controller.logger?.error(
      '同步状态记录失败 run=$runId errorCode=persist',
      source: 'sync',
    );
  }
}

String _newRunId() {
  final random = Random.secure();
  return List<int>.generate(3, (_) => random.nextInt(256))
      .map((value) => value.toRadixString(16).padLeft(2, '0'))
      .join()
      .toUpperCase();
}

import 'dart:async';
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
      onError: (error) =>
          controller.logger?.error('同步失败', source: 'sync', error: error),
    );
    await repository.saveDeviceState(clock.getState());
    return SyncRuntime._(controller, clock, tracker, engine)
      .._repository = repository;
  }

  Future<SyncRunResult> run(SyncTrigger trigger) =>
      _serialize(() => _run(trigger));
  Future<SyncRunResult> _run(SyncTrigger trigger) async {
    if (_disposed) {
      return const SyncRunResult(
        uploaded: 0,
        downloaded: 0,
        conflicts: 0,
        pending: 0,
        errorCode: 'disposed',
      );
    }
    engine.updateConfig(
      controller.webdavConfig.isConfigured ? controller.webdavConfig : null,
    );
    engine.updatePassphrase(controller.backupPassphrase);
    try {
      await controller.waitForPendingWrites();
      await controller.applySyncPreferenceJournal();
      await engine.initializeFromRestoredData();
      if (await _repository.loadEnrollmentState() == 'enrolling') {
        return SyncRunResult(
          uploaded: 0,
          downloaded: 0,
          conflicts: 0,
          pending: (await _repository.loadPendingBatches()).length,
        );
      }
      await tracker.reconcile();
      final result = await engine.run(trigger: trigger);
      await _recordError(result.errorCode);
      return result;
    } catch (error) {
      controller.logger?.error('同步失败', source: 'sync', error: error);
      await _recordError(syncErrorCode(error));
      return SyncRunResult(
        uploaded: 0,
        downloaded: 0,
        conflicts: 0,
        pending: 0,
        errorCode: syncErrorCode(error),
      );
    }
  }

  Future<void> _recordError(String? code) async {
    if (code == null) return;
    final previous = await _repository.loadScanState();
    await _repository.saveScanState(
      SyncScanState(
        contiguousSequences: previous.contiguousSequences,
        gaps: previous.gaps,
        lastSuccess: previous.lastSuccess,
        lastErrorCode: code,
        retryCount: previous.retryCount + 1,
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

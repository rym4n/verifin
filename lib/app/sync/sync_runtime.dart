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

/// 一次同步运行的兜底总时限。
///
/// 传输层每个请求已各自有 60 秒上界，正常情况下轮不到这里。它存在的唯一理由是
/// 保证「任何一处未加上界的 await 都不能把同步队列永久焊死」——[SyncRuntime._serialize]
/// 把每次运行串在同一条 `_operationTail` 上，一次挂死会让此后每一次同步（含用户
/// 手动点的「立即同步」）无声排队到进程结束。取值刻意放宽，宁可让一次真正缓慢的
/// 首次同步跑完，也不要误杀；超时后下一次运行会幂等续传。
const Duration _defaultSyncRunTimeout = Duration(minutes: 15);

/// One process-owned clock, tracker and engine, shared by all triggers.
class SyncRuntime {
  SyncRuntime._(
    this.controller,
    this.clock,
    this.tracker,
    this.engine,
    this.runTimeout,
  ) {
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
  final Duration runTimeout;
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
    Duration? runTimeout,
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
    return SyncRuntime._(
      controller,
      clock,
      tracker,
      engine,
      runTimeout ?? _defaultSyncRunTimeout,
    ).._repository = repository;
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
      final result = await _runPhases(trigger, runLog).timeout(runTimeout);
      await _recordErrorSafely(result.errorCode, runLog);
      runLog.finish(result);
      return result;
    } catch (error) {
      if (error is TimeoutException) runLog.timedOut(runTimeout);
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

  /// 阶段序列单独成一个 future，好让 [_run] 给它整体加上界。超时只放弃「等待」，
  /// 被放弃的运行仍在后台跑；这是刻意的取舍——传输层已各自有超时会很快自行解开，
  /// 而让 `_operationTail` 立刻释放，才能保证后续同步不被永久拖死。
  Future<SyncRunResult> _runPhases(
    SyncTrigger trigger,
    _SyncRunLog runLog,
  ) async {
    await runLog.phase(SyncPhase.prepare, () async {
      await controller.waitForPendingWrites();
      await controller.applySyncPreferenceJournal();
    });
    await runLog.phase(SyncPhase.initialize, () async {});
    await runLog.phase(SyncPhase.reconcile, tracker.reconcile);
    return engine.runSnapshot(trigger: trigger, onPhase: runLog.reportPhase);
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
  SyncPhase? _phaseInFlight;

  void start() {
    _controller.logger?.info(
      '同步开始 run=$runId trigger=${_trigger.name}',
      source: 'sync',
    );
  }

  /// 兜底超时触发时，阶段日志只会留下一条没有结尾的 `state=start`。这条日志把
  /// 「卡在哪个阶段」直接写出来，免得排查时只能靠缺失的 success/error 反推。
  void timedOut(Duration limit) {
    _controller.logger?.error(
      '同步超时 run=$runId phase=${_phaseInFlight?.logValue ?? 'none'} '
      'limit=${limit.inSeconds}s',
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
    _phaseInFlight = state == SyncPhaseState.start ? phase : null;
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

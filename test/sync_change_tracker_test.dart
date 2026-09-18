import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/sync/sync_change_tracker.dart';
import 'package:verifin/app/sync/sync_clock.dart';
import 'package:verifin/app/sync/sync_models.dart';
import 'package:verifin/app/sync/sync_store.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/local_storage/local_storage.dart';

import 'support/in_memory_ledger_repository.dart';
import 'support/test_harness.dart';

/// 载入与首启动播种正常、但保存交易时抛错的仓储，用于验证「落库失败的写
/// 不报告成功变更」。
class _ThrowingOnEntrySaveRepository extends InMemoryLedgerRepository {
  @override
  Future<void> saveEntryAggregate({
    required List<LedgerEntry> entries,
    required List<Attachment> attachments,
    List<ExchangeRate>? exchangeRates,
  }) async {
    throw StateError('disk full');
  }
}

/// [RecordingSyncRepository] 的 [loadShadow] 可通过 [loadShadowCompleter] 暂停。
///
/// 用于精确控制「第一次 reconcile 正在等 loadShadow」这个时机，使第二次
/// reconcile 调用到达时 `_reconciling` 一定是 `true`，从而重现重入竞态。
class _BlockingRecordingSyncRepository extends RecordingSyncRepository {
  _BlockingRecordingSyncRepository(super.inner);

  /// 每次调用 [loadShadow] 时，若该字段不为空，则等待其完成后再继续。
  /// 调用完成后自动置 null，使后续调用不再阻塞。
  Completer<void>? loadShadowCompleter;

  @override
  Future<Map<SyncEntityKey, String>> loadShadow() async {
    final completer = loadShadowCompleter;
    if (completer != null) {
      loadShadowCompleter = null;
      await completer.future;
    }
    return super.loadShadow();
  }

  /// 每次调用 [saveShadow] 时，若该字段不为空，则等待其完成后再继续。
  ///
  /// `saveShadow` 是 `_reconcileOnce` 里最后一步、且在 `exportDataForSync()` /
  /// `enqueueBatch()` 都已执行之后才会被调用。阻塞在这里而不是 [loadShadow]，
  /// 使得「第一轮已经把它看到的那份投影提交完毕，只差 shadow 还没落」——之后
  /// 再发生的任何控制器变更，只会被「重入触发的第二轮」看到，不会被第一轮
  /// 吸收。这正是重现「重入丢失 alignShadowOnly 意图」竞态所需要的时序。
  Completer<void>? saveShadowCompleter;

  @override
  Future<void> saveShadow(Map<SyncEntityKey, String> shadow) async {
    final completer = saveShadowCompleter;
    if (completer != null) {
      saveShadowCompleter = null;
      await completer.future;
    }
    return super.saveShadow(shadow);
  }
}

/// 记录调用、可注入失败的 [SyncRepository]，其余方法委托给内存镜像。
class RecordingSyncRepository implements SyncRepository {
  @override
  Future<SyncSnapshotState> loadSnapshotState() => _inner.loadSnapshotState();
  @override
  Future<PreparedSyncSnapshot> prepareSnapshotPublication() =>
      _inner.prepareSnapshotPublication();
  @override
  Future<void> freezeSnapshotBlobMembers(
    int sequence,
    List<SnapshotBlobMapping> mappings,
  ) => _inner.freezeSnapshotBlobMembers(sequence, mappings);
  @override
  Future<void> markSnapshotPublished(
    int sequence, {
    required String filename,
    required String snapshotHash,
  }) => _inner.markSnapshotPublished(
    sequence,
    filename: filename,
    snapshotHash: snapshotHash,
  );
  @override
  Future<void> abandonIncompleteSnapshotPublications() =>
      _inner.abandonIncompleteSnapshotPublications();
  @override
  Future<void> recordV1Scan({
    required bool v1HistoryFound,
    required String? fingerprint,
  }) => _inner.recordV1Scan(
    v1HistoryFound: v1HistoryFound,
    fingerprint: fingerprint,
  );
  @override
  Future<void> markV1ReadyToCutover() => _inner.markV1ReadyToCutover();
  @override
  Future<void> markV1MigrationNotRequired() =>
      _inner.markV1MigrationNotRequired();
  @override
  Future<void> completeV1CutoverWithPublication(
    int sequence, {
    required String filename,
    required String snapshotHash,
  }) => _inner.completeV1CutoverWithPublication(
    sequence,
    filename: filename,
    snapshotHash: snapshotHash,
  );
  @override
  Future<SyncSnapshotCursor?> loadSnapshotCursor(String deviceId) =>
      _inner.loadSnapshotCursor(deviceId);
  @override
  Future<List<SyncSnapshotCursor>> loadSnapshotCursors() =>
      _inner.loadSnapshotCursors();
  @override
  Future<void> saveSnapshotCursor(SnapshotCursorAdvance cursor) =>
      _inner.saveSnapshotCursor(cursor);
  @override
  Future<void> saveVerifiedBlobMapping(SnapshotBlobMapping mapping) =>
      _inner.saveVerifiedBlobMapping(mapping);
  @override
  Future<void> markSnapshotBlobMappingInvalid(
    String rawHash,
    String fileHash,
  ) => _inner.markSnapshotBlobMappingInvalid(rawHash, fileHash);
  @override
  Future<List<SnapshotBlobMapping>> loadVerifiedBlobMappings(String rawHash) =>
      _inner.loadVerifiedBlobMappings(rawHash);
  @override
  Future<String?> loadEnrollmentState() => _inner.loadEnrollmentState();
  @override
  Future<void> saveEnrollmentState(String state) =>
      _inner.saveEnrollmentState(state);
  @override
  Future<void> saveConflictChoice(
    String id,
    String conflict,
    SyncEvent? event,
  ) => _inner.saveConflictChoice(id, conflict, event);
  @override
  Future<void> finalizePreparedBatches() => _inner.finalizePreparedBatches();
  @override
  Future<void> removePendingBatch(String id) => _inner.removePendingBatch(id);
  @override
  Future<Map<SyncEntityKey, SyncEntityVersion>> loadEntityHeads(
    Set<SyncEntityKey> keys,
  ) => _inner.loadEntityHeads(keys);
  @override
  Future<void> savePendingBatch(
    String id,
    List<SyncEvent> events,
    String reason,
  ) => _inner.savePendingBatch(id, events, reason);
  @override
  Future<List<SyncPendingBatch>> loadPendingBatches() =>
      _inner.loadPendingBatches();
  @override
  Future<Map<String, String>> loadAppliedOperationHashes(List<String> ids) =>
      _inner.loadAppliedOperationHashes(ids);
  RecordingSyncRepository(this._inner);

  final SyncRepository _inner;

  final List<SyncBatchRecord> enqueued = <SyncBatchRecord>[];
  int saveShadowCalls = 0;
  int applyRemoteCalls = 0;

  /// 为 true 时 [enqueueBatch] 抛错（模拟「业务已保存、outbox 落库失败」）。
  bool failEnqueue = false;

  @override
  Future<SyncDeviceState> loadDeviceState() => _inner.loadDeviceState();

  @override
  Future<void> saveDeviceState(SyncDeviceState state) =>
      _inner.saveDeviceState(state);

  @override
  Future<List<SyncOutboxRecord>> loadOutbox() => _inner.loadOutbox();

  @override
  Future<void> enqueueBatch(SyncBatchRecord batch) async {
    if (failEnqueue) {
      throw StateError('outbox write failed');
    }
    enqueued.add(batch);
    await _inner.enqueueBatch(batch);
  }

  @override
  Future<void> markBatchUploaded(String batchId) =>
      _inner.markBatchUploaded(batchId);

  @override
  Future<void> applyRemoteBatch(RemoteApplyPlan plan) {
    applyRemoteCalls++;
    return _inner.applyRemoteBatch(plan);
  }

  @override
  Future<SyncScanState> loadScanState() => _inner.loadScanState();

  @override
  Future<void> saveScanState(SyncScanState state) =>
      _inner.saveScanState(state);

  @override
  Future<List<SyncConflictRecord>> loadConflicts() => _inner.loadConflicts();

  @override
  Future<void> storeConflict(SyncConflictRecord conflict) =>
      _inner.storeConflict(conflict);

  @override
  Future<void> removeConflict(String conflictId) =>
      _inner.removeConflict(conflictId);

  @override
  Future<Map<SyncEntityKey, String>> loadShadow() => _inner.loadShadow();

  @override
  Future<void> saveShadow(Map<SyncEntityKey, String> shadow) {
    saveShadowCalls++;
    return _inner.saveShadow(shadow);
  }

  @override
  Future<List<KvJournalEntry>> loadPendingKvJournal() =>
      _inner.loadPendingKvJournal();

  @override
  Future<void> markKvJournalApplied(int id) => _inner.markKvJournalApplied(id);
}

typedef _Tracked = ({
  SyncChangeTracker tracker,
  RecordingSyncRepository repo,
  VeriFinController controller,
});

// ignore: library_private_types_in_public_api — 仅内部使用的测试辅助。
Future<_Tracked> buildTracker({
  Duration debounce = const Duration(milliseconds: 300),
}) async {
  final repository = InMemoryLedgerRepository();
  final repo = RecordingSyncRepository(repository.sync);
  final store = LocalKeyValueStore();
  final controller = await makeController(store);
  final clock = await SyncClock.create(store);
  final tracker = SyncChangeTracker(
    controller: controller,
    repository: repo,
    clock: clock,
    debounce: debounce,
  );
  return (tracker: tracker, repo: repo, controller: controller);
}

void main() {
  useTestDatabases();

  group('reconcile', () {
    test('显式 enrollment 对齐 shadow 基线，不上传本地既有数据', () async {
      final t = await buildTracker();
      await t.tracker.reconcile(alignShadowOnly: true);

      expect(t.repo.enqueued, isEmpty);
      expect(t.repo.saveShadowCalls, 1);
      final shadow = await t.repo.loadShadow();
      expect(shadow, isNotEmpty);
    });

    test('内容变化后 reconcile 产生 upsert 事件并推进 shadow', () async {
      final t = await buildTracker();
      await t.tracker.reconcile(alignShadowOnly: true);
      final baseline = await t.repo.loadShadow();

      t.controller.setThemePreference(ThemePreference.dark);
      await t.tracker.reconcile();

      expect(t.repo.enqueued.length, 1);
      final batch = t.repo.enqueued.single;
      expect(batch.events.length, 1);
      final event = batch.events.single;
      expect(
        event.entity,
        const SyncEntityKey(
          scope: 'global',
          type: 'themePreference',
          id: 'singleton',
        ),
      );
      expect(event.operation, SyncOperationKind.upsert);
      expect(event.payload, 'dark');
      expect(event.payloadHash, computeSyncPayloadHash(event.payload));
      expect(event.version.dot.deviceId, t.tracker.clock.deviceId);
      expect(batch.manifest.operationIds, <String>[event.operationId]);

      final advanced = await t.repo.loadShadow();
      expect(advanced, isNot(baseline));
      expect(
        advanced[const SyncEntityKey(
          scope: 'global',
          type: 'themePreference',
          id: 'singleton',
        )],
        event.payloadHash,
      );

      // 再跑一次不应重复发事件（shadow 已推进）。
      await t.tracker.reconcile();
      expect(t.repo.enqueued.length, 1);
    });

    test('删除产生显式 tombstone，不靠远端缺文件推断', () async {
      final t = await buildTracker();
      final bookId = t.controller.activeBook.id;
      t.controller.addAccount(
        Account(
          id: 'acct',
          bookId: bookId,
          name: '现金',
          type: AccountType.cash,
          groupId: null,
          initialBalance: 0,
          iconCode: 'cash',
          note: '',
          includeInAssets: true,
          hidden: false,
        ),
      );
      await t.tracker.reconcile(alignShadowOnly: true);
      t.repo.enqueued.clear();

      await t.controller.deleteAccount('acct');
      await t.tracker.reconcile();

      final events = t.repo.enqueued.expand((batch) => batch.events);
      final tombstone = events.firstWhere(
        (event) => event.operation == SyncOperationKind.delete,
      );
      expect(
        tombstone.entity,
        const SyncEntityKey(scope: 'ledger', type: 'accounts', id: 'acct'),
      );
      expect(tombstone.payload, isNull);
    });

    test('事件序列在同一设备上单调递增且不复用', () async {
      final t = await buildTracker();
      await t.tracker.reconcile(alignShadowOnly: true);
      t.controller.setThemePreference(ThemePreference.dark);
      await t.tracker.reconcile();
      t.controller.setHapticsEnabled(false);
      await t.tracker.reconcile();

      final sequences = t.repo.enqueued
          .expand((batch) => batch.events)
          .map((event) => event.version.dot.sequence)
          .toList();
      // 单调递增且不重复；起点由设备序列号决定，不硬编码。
      expect(sequences.length, 2);
      expect(sequences[1], greaterThan(sequences[0]));
    });

    test('凭证类数据不在白名单，不产生任何事件', () async {
      final t = await buildTracker();
      await t.tracker.reconcile(alignShadowOnly: true);
      t.controller
        ..setBackupPassphrase('hunter2')
        ..setWebdavAutoUpload(true);
      await t.tracker.reconcile();
      expect(t.repo.enqueued, isEmpty);
    });
  });

  group('markLocalMutation', () {
    test('防抖后自动 reconcile，多次标记只跑一次', () async {
      final t = await buildTracker(debounce: const Duration(milliseconds: 20));
      // 先建立基线（同步引擎在启动时做这件事），否则第一次比较只写 shadow。
      await t.tracker.reconcile(alignShadowOnly: true);

      t.tracker.markLocalMutation();
      t.controller.setThemePreference(ThemePreference.dark);
      t.tracker.markLocalMutation();
      // 防抖窗口内不入队。
      expect(t.repo.enqueued, isEmpty);

      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(t.repo.enqueued.length, 1);
      expect(t.repo.enqueued.single.events.single.payload, 'dark');
      t.tracker.dispose();
    });

    test('远端应用期间抑制 outbox 生成', () async {
      final t = await buildTracker();
      await t.tracker.reconcile(alignShadowOnly: true);

      t.tracker.markRemoteApply();
      expect(t.tracker.remoteApplyActive, isTrue);
      // 窗口内的「远端结果」：业务数据变了，但绝不能变成出站事件。
      t.controller.setThemePreference(ThemePreference.dark);
      // 普通比较被抑制。
      await t.tracker.reconcile();
      expect(t.repo.enqueued, isEmpty);

      // 窗口内也必须把 shadow 对齐到远端结果，否则窗口一关，下一轮比较会把
      // 刚应用的远端值当成本地新变更上传（回声）。这是引擎收口时要做的对齐。
      await t.tracker.reconcile(alignShadowOnly: true);
      final shadow = await t.repo.loadShadow();
      expect(
        shadow[const SyncEntityKey(
          scope: 'global',
          type: 'themePreference',
          id: 'singleton',
        )],
        computeSyncPayloadHash('dark'),
      );
      expect(t.repo.enqueued, isEmpty);
      expect(t.tracker.remoteApplyActive, isTrue);

      t.tracker.clearRemoteApply();
      expect(t.tracker.remoteApplyActive, isFalse);
      // 窗口关闭后再比较一次：没有新事件（shadow 已对齐）。
      await t.tracker.reconcile();
      expect(t.repo.enqueued, isEmpty);
    });

    test('markRemoteApply/clearRemoteApply 必须成对，嵌套计数不提前放行', () async {
      final t = await buildTracker();
      await t.tracker.reconcile(alignShadowOnly: true);

      t.tracker.markRemoteApply();
      t.tracker.markRemoteApply();
      t.controller.setThemePreference(ThemePreference.dark);
      t.tracker.clearRemoteApply();
      await t.tracker.reconcile();
      expect(t.tracker.remoteApplyActive, isTrue);
      expect(t.repo.enqueued, isEmpty);

      t.tracker.clearRemoteApply();
      expect(t.tracker.remoteApplyActive, isFalse);
      // 多余的 clear 不应把计数压成负数而重新「打开」窗口。
      t.tracker.clearRemoteApply();
      expect(t.tracker.remoteApplyActive, isFalse);
    });
  });

  group('崩溃恢复', () {
    test('outbox 落库失败时 shadow 不推进，下次 reconcile 补发', () async {
      final t = await buildTracker();
      await t.tracker.reconcile(alignShadowOnly: true);
      final baseline = await t.repo.loadShadow();

      t.repo.failEnqueue = true;
      t.controller.setThemePreference(ThemePreference.dark);
      await expectLater(t.tracker.reconcile(), throwsA(isA<StateError>()));

      // 业务数据已改而 shadow 未动：下一轮必须重新发现同一变更。
      expect(await t.repo.loadShadow(), baseline);

      t.repo.failEnqueue = false;
      await t.tracker.reconcile();
      expect(t.repo.enqueued.length, 1);
      expect(t.repo.enqueued.single.events.single.payload, 'dark');
    });

    test('未落库的本地变更在下次启动比较时补出事件', () async {
      final repository = InMemoryLedgerRepository();
      final repo = RecordingSyncRepository(repository.sync);
      final store = LocalKeyValueStore();
      final controller = await makeController(store);
      final clock = await SyncClock.create(store);
      final tracker = SyncChangeTracker(
        controller: controller,
        repository: repo,
        clock: clock,
      );

      // 建立基线（同步引擎启用时做的事）。
      await tracker.reconcile(alignShadowOnly: true);
      expect(repo.enqueued, isEmpty);

      // 模拟「本地写成功，但进程在 reconcile 之前被杀」：只改业务数据，
      // 不调用 reconcile，因此 shadow 仍是旧值。
      controller.setThemePreference(ThemePreference.dark);
      expect(repo.enqueued, isEmpty);

      // 下次启动的 startup reconcile 必须补出这次遗漏的变更。
      await tracker.reconcile();
      final events = repo.enqueued.expand((batch) => batch.events).toList();
      expect(
        events.any(
          (event) =>
              event.entity.type == 'themePreference' && event.payload == 'dark',
        ),
        isTrue,
      );
      tracker.dispose();
    });
  });

  group('复入与并发', () {
    test('reconcile 进行中再次调用不会重复入队', () async {
      final t = await buildTracker();
      await t.tracker.reconcile(alignShadowOnly: true);
      t.controller.setThemePreference(ThemePreference.dark);

      await Future.wait(<Future<void>>[
        t.tracker.reconcile(),
        t.tracker.reconcile(),
      ]);
      expect(t.repo.enqueued.length, 1);
    });

    test('reconcile 进行中到达的本地变更不会被吞掉', () async {
      final t = await buildTracker();
      await t.tracker.reconcile(alignShadowOnly: true);
      t.controller.setThemePreference(ThemePreference.dark);

      final first = t.tracker.reconcile();
      t.controller.setHapticsEnabled(false);
      await first;
      await t.tracker.reconcile();

      final events = t.repo.enqueued.expand((batch) => batch.events).toList();
      expect(
        events.any(
          (event) =>
              event.entity.type == 'hapticsEnabled' && event.payload == false,
        ),
        isTrue,
      );
    });

    test('重入丢失对齐意图会产生回声：alignShadowOnly=true 的请求在第一轮尚未提交时到达，'
        'rerun 必须仍按对齐模式跑，不能把重入期间发生的新变更当本地事件入队', () async {
      final repository = InMemoryLedgerRepository();
      final repo = _BlockingRecordingSyncRepository(repository.sync);
      final store = LocalKeyValueStore();
      final controller = await makeController(store);
      final clock = await SyncClock.create(store);
      final tracker = SyncChangeTracker(
        controller: controller,
        repository: repo,
        clock: clock,
      );

      // 建立基线：shadow 与当前投影一致，之后的差异才会真正触发入队路径。
      await tracker.reconcile(alignShadowOnly: true);

      // 变更 A（真实的本地变更，发生在第一轮开始之前）：第一轮理应把它当成
      // 一次合法的本地变更提交，这是预期行为，不受本次修复影响。
      controller.setThemePreference(ThemePreference.dark);

      // 让第一轮卡在 saveShadow——此时它已经读过 exportDataForSync()、算出
      // 了「变更 A」的 diff、也已经调用过 enqueueBatch 把这批提交，只差把
      // shadow 推进这最后一步。选在这里挂起，是为了让「变更 A」完整地被
      // 第一轮自己吸收，不掺进重入触发的第二轮里。
      final gate = Completer<void>();
      repo.saveShadowCompleter = gate;
      final first = tracker.reconcile(); // alignShadowOnly: false（默认）

      // 让第一轮推进到卡在 saveShadow 的那一步（中间只有微任务级别的
      // await，一次事件循环足够）。
      await Future<void>.delayed(Duration.zero);

      // 变更 B：模拟远端批次已经应用完毕、业务数据已被改写。这必须发生在
      // 第一轮读完投影（已经卡在 saveShadow）之后，才能保证只有重入触发的
      // 第二轮会看到它。
      controller.setHapticsEnabled(false);

      // runRemoteApply 在 apply() 完成后调用的正是这个：因为 `_reconciling`
      // 仍为 true（第一轮还没跑完），这次调用只能设位等待 rerun。
      final second = tracker.reconcile(alignShadowOnly: true);

      // 释放 saveShadow，让第一轮完成提交；随后应触发一次 rerun。
      gate.complete();
      await first;
      await second;

      // 第一轮的合法提交（变更 A）必须存在且只有这一条。
      expect(repo.enqueued.length, 1);
      final firstBatchEvents = repo.enqueued.single.events;
      expect(firstBatchEvents.single.entity.type, 'themePreference');
      expect(firstBatchEvents.single.payload, 'dark');

      // rerun 必须按对齐模式跑：变更 B（模拟的远端结果）绝不能作为第二个
      // 批次入队——否则就是本次修复要堵住的回声。
      expect(
        repo.enqueued.any(
          (batch) => batch.events.any(
            (event) => event.entity.type == 'hapticsEnabled',
          ),
        ),
        isFalse,
      );

      // 但 shadow 仍必须推进到反映变更 B，否则窗口关闭后的下一次比较会把
      // 它误判成本地新变更、重新回传一次。
      final shadow = await repo.loadShadow();
      expect(
        shadow[const SyncEntityKey(
          scope: 'global',
          type: 'hapticsEnabled',
          id: 'singleton',
        )],
        computeSyncPayloadHash(false),
      );
    });

    test('重入的 OR 语义不会被后到的普通请求降级：先到的 alignShadowOnly=true 意图'
        '必须在整个忙碌窗口内一直保持，即使窗口关闭前又有一次普通 reconcile() 插队', () async {
      final repository = InMemoryLedgerRepository();
      final repo = _BlockingRecordingSyncRepository(repository.sync);
      final store = LocalKeyValueStore();
      final controller = await makeController(store);
      final clock = await SyncClock.create(store);
      final tracker = SyncChangeTracker(
        controller: controller,
        repository: repo,
        clock: clock,
      );

      await tracker.reconcile(alignShadowOnly: true);
      controller.setThemePreference(ThemePreference.dark);

      final gate = Completer<void>();
      repo.saveShadowCompleter = gate;
      final first = tracker.reconcile();
      await Future<void>.delayed(Duration.zero);

      controller.setHapticsEnabled(false);

      // 先到的请求要求对齐：把 `_rerunAlignShadowOnly` 置为 true。
      final second = tracker.reconcile(alignShadowOnly: true);
      // 后到的普通请求：如果实现错误地用「最后一次赋值」而非 OR 语义，
      // 这次调用会把 `_rerunAlignShadowOnly` 错误地覆盖回 false。
      final third = tracker.reconcile();

      gate.complete();
      await first;
      await second;
      await third;

      expect(repo.enqueued.length, 1);
      expect(
        repo.enqueued.any(
          (batch) => batch.events.any(
            (event) => event.entity.type == 'hapticsEnabled',
          ),
        ),
        isFalse,
        reason:
            'OR 语义必须保留先到请求的对齐意图，不能被后到的普通请求降级'
            '（否则重入触发的第二轮会把 hapticsEnabled 的变化当本地事件入队）',
      );
    });
  });

  group('VeriFinController 接线', () {
    test('成功的本地写触发 onSyncChanged', () async {
      final controller = await makeController(LocalKeyValueStore());
      var fired = 0;
      controller.onSyncChanged = () => fired++;

      controller.setThemePreference(ThemePreference.dark);
      expect(fired, 1);

      controller.addEntry(
        LedgerEntry(
          id: 'entry-hook',
          bookId: controller.activeBook.id,
          type: EntryType.expense,
          amount: 10,
          currencyCode: 'CNY',
          baseAmount: 10,
          categoryId: controller.categoriesForType(EntryType.expense).first.id,
          accountId: 'acct-hook',
          note: 'x',
          occurredAt: DateTime(2026, 9, 1),
        ),
      );
      // 账目写入是 fire-and-forget：上报发生在落库成功之后。
      await controller.waitForPendingWrites();
      expect(fired, greaterThan(1));
      expect(controller.entries.any((e) => e.id == 'entry-hook'), isTrue);

      // 重复写入同一值不触发（setter 提前 return）。
      final before = fired;
      controller.setThemePreference(ThemePreference.dark);
      expect(fired, before);
    });

    test('落库失败的写不报告成功变更', () async {
      final controller = await VeriFinController.create(
        LocalKeyValueStore(),
        repository: _ThrowingOnEntrySaveRepository(),
      );
      final bookId = controller.activeBook.id;
      var fired = 0;
      controller.onSyncChanged = () => fired++;

      final deleted = await controller.deleteEntry('nonexistent');
      expect(deleted, isFalse);
      expect(fired, 0);

      // 有内容可删时落库失败：内存不提交、也不上报变更。
      controller.addEntry(
        LedgerEntry(
          id: 'entry-fail',
          bookId: bookId,
          type: EntryType.expense,
          amount: 1,
          currencyCode: 'CNY',
          baseAmount: 1,
          categoryId: controller.categoriesForType(EntryType.expense).first.id,
          accountId: 'acct',
          note: '',
          occurredAt: DateTime(2026, 9, 1),
        ),
      );
      await controller.waitForPendingWrites();
      final before = fired;
      final ok = await controller.deleteEntry('entry-fail');
      expect(ok, isFalse);
      expect(fired, before);
      expect(controller.entries.any((e) => e.id == 'entry-fail'), isTrue);
      controller.dispose();
    });
  });
}

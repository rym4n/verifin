import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/backup/webdav_config.dart';
import 'package:verifin/app/sync/sync_clock.dart';
import 'package:verifin/app/sync/sync_engine.dart';
import 'package:verifin/app/sync/sync_kv_projection.dart';
import 'package:verifin/app/sync/sync_models.dart';
import 'package:verifin/app/sync/webdav_sync_transport_stub.dart';
import 'package:verifin/local_storage/local_storage.dart';

import 'support/in_memory_ledger_repository.dart';
import 'support/test_harness.dart';

const testConfig = WebdavConfig(
  url: 'https://test.example.com/dav',
  username: 'test',
  password: 'test',
);

/// 构造一个「远端偏好批次」事件。默认 `themePreference`（单值 KV 偏好），
/// 用来验证 remote apply 会为它插入一条 journal 行。
SyncEvent kvEvent({
  required SyncEntityKey entity,
  required Object? payload,
  String? operationId,
  String batchId = 'batch-kv',
  SyncOperationKind operation = SyncOperationKind.upsert,
}) {
  final clock = SyncClock.createWithDeviceId('dev-remote');
  return SyncEvent(
    protocolVersion: syncProtocolVersion,
    operationId: operationId ?? clock.nextOperationId(),
    version: clock.nextVersion(),
    entity: entity,
    operation: operation,
    payloadHash: computeSyncPayloadHash(payload),
    payload: payload,
    batchId: batchId,
    keyFingerprint: 'test-key',
  );
}

/// Task 6 Step 4：KV 偏好 journal 的插入、确定性顺序、重放幂等与失败保持 pending。
void main() {
  useTestDatabases();

  group('SyncKvProjection 映射', () {
    test('只认识偏好类类型，账目类类型返回 null', () {
      expect(SyncKvProjection.storageKeyFor('profile'), 'verifin.profile.v1');
      expect(
        SyncKvProjection.storageKeyFor('themePreference'),
        'verifin.theme.v1',
      );
      expect(SyncKvProjection.isKvPreferenceType('homePanels'), isTrue);
      expect(SyncKvProjection.storageKeyFor('entries'), isNull);
      expect(SyncKvProjection.isKvPreferenceType('accounts'), isFalse);
    });

    test('map-per-key 类型只改一个键，保留同键下其余键', () {
      final merged = SyncKvProjection.mergeToStorageValue(
        entityType: 'defaultAccountIds',
        entityId: 'book-1',
        currentValue: <String, Object?>{'book-1': 'old', 'book-2': 'keep'},
        payload: 'acc-9',
        deleted: false,
      );
      expect(merged, isNotNull);
      // 整份重写：book-2 必须原样保留——这正是「先读当前完整值再叠加」的意义。
      expect(merged, contains('"book-2":"keep"'));
      expect(merged, contains('"book-1":"acc-9"'));
      expect(merged, isNot(contains('"old"')));
    });

    test('map-per-key 类型的删除只摘掉目标键', () {
      final merged = SyncKvProjection.mergeToStorageValue(
        entityType: 'defaultAccountIds',
        entityId: 'book-1',
        currentValue: <String, Object?>{'book-1': 'a', 'book-2': 'b'},
        payload: null,
        deleted: true,
      );
      expect(merged, isNot(contains('book-1')));
      expect(merged, contains('book-2'));
    });

    test('单值类型直接替换', () {
      expect(
        SyncKvProjection.mergeToStorageValue(
          entityType: 'themePreference',
          entityId: 'default',
          currentValue: 'light',
          payload: 'dark',
          deleted: false,
        ),
        'dark',
      );
      expect(
        SyncKvProjection.mergeToStorageValue(
          entityType: 'amountForceTwoDecimals',
          entityId: 'default',
          currentValue: false,
          payload: true,
          deleted: false,
        ),
        'true',
      );
    });

    test('列表类型按 id 定位增删', () {
      final updated = SyncKvProjection.mergeToStorageValue(
        entityType: 'homePanels',
        entityId: 'p2',
        currentValue: <Object?>[
          <String, Object?>{'id': 'p1', 'enabled': true},
          <String, Object?>{'id': 'p2', 'enabled': true},
        ],
        payload: <String, Object?>{'id': 'p2', 'enabled': false},
        deleted: false,
      );
      expect(updated, contains('"enabled":false'));
      expect(updated, contains('p1'));

      final removed = SyncKvProjection.mergeToStorageValue(
        entityType: 'homePanels',
        entityId: 'p1',
        currentValue: <Object?>[
          <String, Object?>{'id': 'p1'},
          <String, Object?>{'id': 'p2'},
        ],
        payload: null,
        deleted: true,
      );
      expect(removed, isNot(contains('p1')));
      expect(removed, contains('p2'));
    });

    test('顺序类型按 container:position 写入指定位置', () {
      final merged = SyncKvProjection.mergeToStorageValue(
        entityType: 'assetAccountOrders',
        entityId: 'book-1:1',
        currentValue: <String, Object?>{
          'book-1': <Object?>['a', 'b'],
        },
        payload: <String, Object?>{
          'container': 'book-1',
          'position': 1,
          'id': 'a',
        },
        deleted: false,
      );
      expect(merged, contains('"book-1":["a","a"]'));
    });

    test('顺序类型 id 格式非法时原样保留当前值而不是写坏数据', () {
      final merged = SyncKvProjection.mergeToStorageValue(
        entityType: 'assetAccountOrders',
        entityId: 'no-separator',
        currentValue: <String, Object?>{
          'book-1': <Object?>['a'],
        },
        payload: <String, Object?>{'id': 'x'},
        deleted: false,
      );
      expect(merged, '{"book-1":["a"]}');
    });
  });

  group('remote apply 插入 journal 行', () {
    test('偏好类型的远端事件落一条 journal 行，账目类型不落', () async {
      final repo = InMemoryLedgerRepository();
      final transport = StubWebdavSyncTransport();
      final engine = SyncEngine(
        repository: repo.sync,
        transport: transport,
        controller: repo,
        config: testConfig,
      );

      await transport.simulateRemoteBatch('dev-remote', 1, [
        kvEvent(
          entity: const SyncEntityKey(
            scope: 'global',
            type: 'themePreference',
            id: 'default',
          ),
          payload: 'dark',
        ),
      ]);
      await engine.run(trigger: SyncTrigger.manual);

      final pending = await repo.sync.loadPendingKvJournal();
      expect(pending, hasLength(1));
      expect(pending.single.key, 'verifin.theme.v1');
      expect(pending.single.value, 'dark');
      // target_hash 与值一致，供调试/校验使用。
      expect(pending.single.targetHash, computeSyncPayloadHash('dark'));

      // 账目类事件不该产生 journal 行。
      await transport.simulateRemoteBatch('dev-remote', 2, [
        kvEvent(
          entity: const SyncEntityKey(
            scope: 'ledger',
            type: 'entries',
            id: 'e1',
          ),
          payload: <String, Object?>{'amount': 1},
        ),
      ]);
      await engine.run(trigger: SyncTrigger.manual);
      expect(await repo.sync.loadPendingKvJournal(), hasLength(1));
    });
  });

  group('applySyncPreferenceJournal 重放', () {
    test('启动时重放未应用的行，落到本地 KV 并标记已应用', () async {
      final store = LocalKeyValueStore();
      final repo = InMemoryLedgerRepository();
      await repo.sync.applyRemoteBatch(
        RemoteApplyPlan(
          batchId: 'batch-1',
          entityVersions: const <SyncEntityVersion>[],
          appliedOperationIds: const <String>['op-1'],
          shadowHashes: const <String, String>{},
          kvJournalValues: const <String, String>{
            'verifin.theme.v1': 'dark',
            'verifin.fab_action.v1': 'manual',
          },
        ),
      );
      expect(await repo.sync.loadPendingKvJournal(), hasLength(2));

      // 启动时（create 序列末尾）自动重放，无需显式调用。
      await makeController(store, true, repo);

      expect(store.read('verifin.theme.v1'), 'dark');
      expect(store.read('verifin.fab_action.v1'), 'manual');
      expect(await repo.sync.loadPendingKvJournal(), isEmpty);
    });

    test('重放幂等：再跑一次不产生副作用也不报错', () async {
      final store = LocalKeyValueStore();
      final repo = InMemoryLedgerRepository();
      await repo.sync.applyRemoteBatch(
        RemoteApplyPlan(
          batchId: 'batch-1',
          entityVersions: const <SyncEntityVersion>[],
          appliedOperationIds: const <String>['op-1'],
          shadowHashes: const <String, String>{},
          kvJournalValues: const <String, String>{'verifin.theme.v1': 'dark'},
        ),
      );

      final controller = await makeController(store, true, repo);
      await controller.applySyncPreferenceJournal();
      await controller.applySyncPreferenceJournal();

      expect(store.read('verifin.theme.v1'), 'dark');
      expect(await repo.sync.loadPendingKvJournal(), isEmpty);
    });

    test('内核按 key 确定性顺序写入', () async {
      final store = LocalKeyValueStore();
      final repo = InMemoryLedgerRepository();
      // 故意乱序插入，断言重放时按 key 排序（而不是插入顺序）处理。
      await repo.sync.applyRemoteBatch(
        RemoteApplyPlan(
          batchId: 'batch-1',
          entityVersions: const <SyncEntityVersion>[],
          appliedOperationIds: const <String>['op-1'],
          shadowHashes: const <String, String>{},
          kvJournalValues: const <String, String>{
            'verifin.theme.v1': 'dark',
            'verifin.fab_action.v1': 'widget',
            'verifin.amount_format.v1': 'true',
          },
        ),
      );

      final pending = await repo.sync.loadPendingKvJournal();
      final sortedKeys = pending.map((e) => e.key).toList()..sort();
      expect(sortedKeys, <String>[
        'verifin.amount_format.v1',
        'verifin.fab_action.v1',
        'verifin.theme.v1',
      ]);

      await makeController(store, true, repo);
      expect(store.read('verifin.amount_format.v1'), 'true');
      expect(store.read('verifin.fab_action.v1'), 'widget');
      expect(store.read('verifin.theme.v1'), 'dark');
    });

    test('写入失败时该行保持待处理，不被标记为已应用', () async {
      final store = _FailingStore();
      final repo = InMemoryLedgerRepository();
      await repo.sync.applyRemoteBatch(
        RemoteApplyPlan(
          batchId: 'batch-1',
          entityVersions: const <SyncEntityVersion>[],
          appliedOperationIds: const <String>['op-1'],
          shadowHashes: const <String, String>{},
          kvJournalValues: const <String, String>{'verifin.theme.v1': 'dark'},
        ),
      );

      // 启动期的重放写入全部失败（模拟磁盘满/权限问题）。
      store.failWrites = true;
      final controller = await makeController(store, true, repo);
      expect(controller, isNotNull);

      expect(
        await repo.sync.loadPendingKvJournal(),
        hasLength(1),
        reason: '写入失败的行不能被标记为已应用，否则本地 KV 会永久停在旧值',
      );
      expect(store.read('verifin.theme.v1'), isNot('dark'));

      // 写入恢复后再次启动应把它补上——重放本身是幂等的。
      store.failWrites = false;
      final reloaded = await makeController(store, true, repo);
      expect(reloaded, isNotNull);
      expect(store.read('verifin.theme.v1'), 'dark');
      expect(await repo.sync.loadPendingKvJournal(), isEmpty);
    });

    test('启动时自动重放：create 之后待处理行已清空且内存字段对齐', () async {
      final store = LocalKeyValueStore();
      final repo = InMemoryLedgerRepository();
      await repo.sync.applyRemoteBatch(
        RemoteApplyPlan(
          batchId: 'batch-1',
          entityVersions: const <SyncEntityVersion>[],
          appliedOperationIds: const <String>['op-1'],
          shadowHashes: const <String, String>{},
          kvJournalValues: const <String, String>{'verifin.theme.v1': 'dark'},
        ),
      );

      final controller = await makeController(store, true, repo);
      expect(store.read('verifin.theme.v1'), 'dark');
      expect(await repo.sync.loadPendingKvJournal(), isEmpty);
      // 内存字段也重新载入过，与刚落地的 KV 一致。
      expect(controller.themePreference.name, 'dark');
    });

    test('空 journal 时重放是安全 no-op', () async {
      final store = LocalKeyValueStore();
      final repo = InMemoryLedgerRepository();
      final controller = await makeController(store, true, repo);
      await controller.applySyncPreferenceJournal();
      expect(await repo.sync.loadPendingKvJournal(), isEmpty);
    });

    test('loadSyncPreferenceStatus 报告待处理与冲突计数', () async {
      final store = LocalKeyValueStore();
      final repo = InMemoryLedgerRepository();
      final controller = await makeController(store, true, repo);
      final empty = await controller.loadSyncPreferenceStatus();
      expect(empty.pendingCount, 0);
      expect(empty.conflictCount, 0);
      expect(empty.hasPending, isFalse);
      expect(empty.hasError, isFalse);
    });
  });
}

/// 可注入写失败的 [LocalKeyValueStore]：只在 `writeAndFlush` 路径失败，
/// 用来验证「KV 写失败 → journal 行保持待处理」。
///
/// `LocalKeyValueStore` 的所有方法都是具体实现（无 abstract 成员），子类直接
/// override 即可——不需要 mock 库。
class _FailingStore extends LocalKeyValueStore {
  bool failWrites = false;

  @override
  Future<void> writeAndFlush(String key, String value) async {
    if (failWrites) {
      throw StateError('write failed');
    }
    return super.writeAndFlush(key, value);
  }
}

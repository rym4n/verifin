import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:verifin/app/sync/sync_models.dart';
import 'package:verifin/app/sync/sync_store.dart';
import 'package:verifin/data/app_database.dart';
import 'package:verifin/data/ledger_repository.dart';

import 'support/in_memory_ledger_repository.dart';

/// 同步元数据仓储契约测试：同一组断言对 InMemory 与 SQLite 两个实现各跑一遍。
///
/// 覆盖 device state、outbox、scan state、conflicts 的读写往返，以及
/// applyRemoteBatch 的原子性与冲突拒绝语义——这些是同步协议「不丢数据、
/// 不重复应用、不静默覆盖」承诺的持久化落点。
void main() {
  setUpAll(sqfliteFfiInit);

  final opened = <AppDatabase>[];
  tearDown(() async {
    for (final db in opened) {
      await db.close();
    }
    opened.clear();
  });

  SyncRepository openMemory() => InMemoryLedgerRepository().sync;

  SyncRepository openSqlite() {
    late SyncRepository repo;
    final ready =
        AppDatabase.open(
          factory: databaseFactoryFfi,
          path: inMemoryDatabasePath,
        ).then((db) {
          opened.add(db);
          repo = SqliteLedgerRepository(db).sync;
          return repo;
        });
    return _DeferredSyncRepository(ready);
  }

  for (final (label, open) in <(String, SyncRepository Function())>[
    ('InMemoryLedgerRepository', openMemory),
    ('SqliteLedgerRepository', openSqlite),
  ]) {
    group('同步仓储契约 · $label', () {
      test('设备状态默认值：首次读取给出未初始化的空状态', () async {
        final sync = open();
        final state = await sync.loadDeviceState();
        expect(state.deviceId, isEmpty);
        expect(state.nextSequence, 1);
        expect(state.knownVector.values, isEmpty);
      });

      test('设备状态保存后原样读回', () async {
        final sync = open();
        const state = SyncDeviceState(
          deviceId: 'dev-1',
          nextSequence: 7,
          knownVector: SyncVersionVector(<String, int>{'dev-1': 6, 'dev-2': 3}),
        );
        await sync.saveDeviceState(state);
        final loaded = await sync.loadDeviceState();
        expect(loaded.deviceId, 'dev-1');
        expect(loaded.nextSequence, 7);
        expect(loaded.knownVector, state.knownVector);
      });

      test('设备状态重复保存是覆盖而非追加', () async {
        final sync = open();
        await sync.saveDeviceState(
          const SyncDeviceState(
            deviceId: 'dev-1',
            nextSequence: 1,
            knownVector: SyncVersionVector(<String, int>{}),
          ),
        );
        await sync.saveDeviceState(
          const SyncDeviceState(
            deviceId: 'dev-2',
            nextSequence: 9,
            knownVector: SyncVersionVector(<String, int>{'dev-2': 8}),
          ),
        );
        final loaded = await sync.loadDeviceState();
        expect(loaded.deviceId, 'dev-2');
        expect(loaded.nextSequence, 9);
      });

      test('shadow 保存后原样读回，含 id 里的竖线', () async {
        final sync = open();
        const key = SyncEntityKey(
          scope: 'ledger',
          type: 'entries',
          id: 'entry_1',
        );
        const oddId = SyncEntityKey(
          scope: 'global',
          type: 'monthlyBudgets',
          id: 'default:2026-09',
        );
        await sync.saveShadow(<SyncEntityKey, String>{
          key: 'hash-a',
          oddId: 'hash-b',
        });

        final loaded = await sync.loadShadow();
        expect(loaded.length, 2);
        expect(loaded[key], 'hash-a');
        expect(loaded[oddId], 'hash-b');
      });

      test('shadow 保存是整体替换而非合并（否则删除会被反复判成新变更）', () async {
        final sync = open();
        const kept = SyncEntityKey(
          scope: 'ledger',
          type: 'entries',
          id: 'kept',
        );
        const removed = SyncEntityKey(
          scope: 'ledger',
          type: 'entries',
          id: 'removed',
        );
        await sync.saveShadow(<SyncEntityKey, String>{
          kept: 'hash-kept',
          removed: 'hash-removed',
        });

        // 第二轮投影里 removed 已消失：shadow 必须随之消失。
        await sync.saveShadow(<SyncEntityKey, String>{kept: 'hash-kept'});

        final loaded = await sync.loadShadow();
        expect(loaded.length, 1);
        expect(loaded.containsKey(removed), isFalse);
      });

      test('shadow 可整体清空（恢复/重置时重建基线）', () async {
        final sync = open();
        await sync.saveShadow(<SyncEntityKey, String>{
          const SyncEntityKey(scope: 'ledger', type: 'entries', id: 'e1'): 'h',
        });
        await sync.saveShadow(<SyncEntityKey, String>{});
        expect(await sync.loadShadow(), isEmpty);
      });

      test('空库的 shadow 是空表而不是抛错', () async {
        final sync = open();
        expect(await sync.loadShadow(), isEmpty);
      });

      test('outbox 入队后可按批次读回，标记上传后不再出现在待传列表', () async {
        final sync = open();
        expect(await sync.loadOutbox(), isEmpty);

        await sync.enqueueBatch(_batch('b1', <String>['op-1', 'op-2']));
        await sync.enqueueBatch(_batch('b2', <String>['op-3']));
        final outbox = await sync.loadOutbox();
        expect(outbox.map((r) => r.batchId).toSet(), <String>{'b1', 'b2'});
        expect(outbox.map((r) => r.operationId).toSet(), <String>{
          'op-1',
          'op-2',
          'op-3',
        });

        await sync.markBatchUploaded('b1');
        final remaining = await sync.loadOutbox();
        expect(remaining.map((r) => r.batchId).toSet(), <String>{'b2'});
      });

      test('outbox 记录带 payload hash、重试计数与协议相对路径', () async {
        final sync = open();
        await sync.enqueueBatch(_batch('b1', <String>['op-1']));
        final record = (await sync.loadOutbox()).single;
        expect(record.payloadHash, isNotEmpty);
        expect(record.retryCount, 0);
        // 协议布局：events/<deviceId>/<20 位零填充 sequence>-<operationId>.vfsync。
        // 零填充不得丢失——扫描按目录字典序推进 sequence，缺了填充顺序就乱了。
        expect(
          record.relativePath,
          'events/dev-1/00000000000000000001-op-1.vfsync',
        );
      });

      test('outbox 记录返回完整事件，上传不依赖进程内缓存', () async {
        final sync = open();
        final batch = _batch('b1', <String>['op-1']);

        await sync.enqueueBatch(batch);

        final record = (await sync.loadOutbox()).single;
        expect(record.event, batch.events.single);
      });

      test('扫描状态默认值：无连续序列、无 gap、无成功时间', () async {
        final sync = open();
        final state = await sync.loadScanState();
        expect(state.contiguousSequences, isEmpty);
        expect(state.gaps, isEmpty);
        expect(state.lastSuccess, isNull);
        expect(state.lastErrorCode, isNull);
        expect(state.retryCount, 0);
      });

      test('快照发布只确认准备时冻结的成员，且序号绝不复用', () async {
        final sync = open();
        await sync.enqueueBatch(_batch('first', const <String>['op-1']));
        final first = await sync.prepareSnapshotPublication();
        expect(first.publication.sequence, 1);
        expect(first.publication.state, SnapshotPublicationState.prepared);

        // Preparation creates an immutable cutoff. This later operation must
        // survive confirmation of the earlier snapshot.
        await sync.enqueueBatch(_batch('later', const <String>['op-2']));
        await sync.freezeSnapshotBlobMembers(
          first.publication.sequence,
          const [],
        );
        await sync.markSnapshotPublished(
          first.publication.sequence,
          filename: 'snapshot-1.json',
          snapshotHash: 'snapshot-hash-1',
        );
        expect(
          (await sync.loadOutbox()).map((row) => row.operationId),
          const <String>['op-2'],
        );

        final second = await sync.prepareSnapshotPublication();
        expect(second.publication.sequence, 2);
      });

      test('cursor only advances as part of accepted remote apply', () async {
        final sync = open();
        await sync.applyRemoteBatch(
          _plan(
            batchId: 'cursor',
            versions: <SyncEntityVersion>[
              _version('cursor-op', 'entry', 'cursor-entry', hash: 'cursor'),
            ],
            cursorAdvance: const SnapshotCursorAdvance(
              deviceId: 'remote-device',
              sequence: 7,
              snapshotHash: 'remote-hash',
              mergedAt: null,
            ),
          ),
        );
        final cursor = await sync.loadSnapshotCursor('remote-device');
        expect(cursor, isNotNull);
        expect(cursor!.lastMergedSequence, 7);
        expect(cursor.lastMergedHash, 'remote-hash');
      });

      test('扫描状态保存后原样读回（含 gap 集合与错误码）', () async {
        final sync = open();
        await sync.saveScanState(
          SyncScanState(
            contiguousSequences: const <String, int>{'dev-2': 5},
            gaps: const <String, List<int>>{
              'dev-2': <int>[6, 7],
            },
            lastSuccess: DateTime(2026, 9, 14, 10, 30),
            lastErrorCode: 'networkUnreachable',
            retryCount: 2,
          ),
        );
        final state = await sync.loadScanState();
        expect(state.contiguousSequences, <String, int>{'dev-2': 5});
        expect(state.gaps, <String, List<int>>{
          'dev-2': <int>[6, 7],
        });
        expect(state.lastSuccess, DateTime(2026, 9, 14, 10, 30));
        expect(state.lastErrorCode, 'networkUnreachable');
        expect(state.retryCount, 2);
      });

      test('扫描状态清空后读回空态', () async {
        final sync = open();
        await sync.saveScanState(
          const SyncScanState(
            contiguousSequences: <String, int>{'dev-2': 5},
            gaps: <String, List<int>>{},
            lastSuccess: null,
            lastErrorCode: 'x',
            retryCount: 1,
          ),
        );
        await sync.saveScanState(
          const SyncScanState(
            contiguousSequences: <String, int>{},
            gaps: <String, List<int>>{},
            lastSuccess: null,
            lastErrorCode: null,
            retryCount: 0,
          ),
        );
        final state = await sync.loadScanState();
        expect(state.contiguousSequences, isEmpty);
        expect(state.lastErrorCode, isNull);
      });

      test('新库无冲突记录', () async {
        expect(await open().loadConflicts(), isEmpty);
      });

      test('shadow 键编码为 "scope|type|id" 且可逆', () async {
        // 编码格式是协议约定（Task 5 的计划构造方依赖它），因此固定断言字面量，
        // 避免实现悄然换成别的格式而下游无从察觉。
        const key = SyncEntityKey(scope: 'default', type: 'entry', id: 'e1');
        expect(encodeSyncEntityKey(key), 'default|entry|e1');
        expect(decodeSyncEntityKey('default|entry|e1'), key);

        // type/id 中出现竖线时按前两个分隔符切分，id 原样保留、不被截断。
        expect(
          decodeSyncEntityKey('default|entry|a|b'),
          const SyncEntityKey(scope: 'default', type: 'entry', id: 'a|b'),
        );

        // 段数不足或空段属于协议违约：抛错而不是静默还原出一个错误实体。
        for (final malformed in const <String>[
          '',
          'default',
          'default|entry',
          '|entry|e1',
          'default||e1',
          'default|entry|',
        ]) {
          expect(
            () => decodeSyncEntityKey(malformed),
            throwsA(isA<FormatException>()),
            reason: '应拒绝非法编码 "$malformed"',
          );
        }
      });

      test(
        'applyRemoteBatch 拒绝纯操作批次（id 不在 entityVersions）的载荷 hash 变化',
        () async {
          // 批次的 appliedOperationIds 可以包含没有实体版本的操作（例如决议事件、
          // 只改 KV 的批次）。这类操作的「已应用」判定只能靠 sync_applied_ops，
          // 不能靠 sync_entity_versions——后者根本没有它的行。
          final sync = open();
          final plan = _plan(
            batchId: 'b1',
            versions: <SyncEntityVersion>[],
            appliedOperationIds: const <String>['op-kv-only'],
            appliedPayloadHashes: const <String, String>{
              'op-kv-only': 'hash-a',
            },
          );
          await sync.applyRemoteBatch(plan);

          // 同一 operationId、不同 hash：必须被拒绝，两个实现结论一致。
          final conflicting = _plan(
            batchId: 'b2',
            versions: <SyncEntityVersion>[],
            appliedOperationIds: const <String>['op-kv-only'],
            appliedPayloadHashes: const <String, String>{
              'op-kv-only': 'hash-b',
            },
          );
          await expectLater(
            sync.applyRemoteBatch(conflicting),
            throwsA(isA<SyncConflictException>()),
          );

          // 同 hash 重放仍应幂等通过。
          await sync.applyRemoteBatch(plan);
        },
      );

      test('applyRemoteBatch 的已应用判定与 entityVersions 无关', () async {
        // 反向用例：先以「带实体版本」的形式应用，再用「纯操作」形式重放同一 hash，
        // 两种形态必须落在同一张已应用表上，而不是各查各的。
        final sync = open();
        await sync.applyRemoteBatch(
          _plan(
            batchId: 'b1',
            versions: <SyncEntityVersion>[
              _version('op-1', 'entry', 'e1', hash: 'h1', payload: 'A'),
            ],
          ),
        );

        await sync.applyRemoteBatch(
          _plan(
            batchId: 'b2',
            versions: <SyncEntityVersion>[],
            appliedOperationIds: const <String>['op-1'],
            appliedPayloadHashes: const <String, String>{'op-1': 'h1'},
          ),
        );

        await expectLater(
          sync.applyRemoteBatch(
            _plan(
              batchId: 'b3',
              versions: <SyncEntityVersion>[],
              appliedOperationIds: const <String>['op-1'],
              appliedPayloadHashes: const <String, String>{
                'op-1': 'h1-different',
              },
            ),
          ),
          throwsA(isA<SyncConflictException>()),
        );
      });

      test('applyRemoteBatch 写入实体版本并登记已应用操作', () async {
        final sync = open();
        final plan = _plan(
          batchId: 'b1',
          versions: <SyncEntityVersion>[
            _version('op-1', 'entry', 'e1', hash: 'h1', payload: 'A'),
          ],
        );
        await sync.applyRemoteBatch(plan);

        final state = await sync.loadDeviceState();
        expect(state.deviceId, isEmpty, reason: '应用批次不改设备身份');
        expect(await sync.loadConflicts(), isEmpty);
      });

      test('applyRemoteBatch 对同一 operationId 重复应用是幂等的', () async {
        final sync = open();
        final plan = _plan(
          batchId: 'b1',
          versions: <SyncEntityVersion>[
            _version('op-1', 'entry', 'e1', hash: 'h1', payload: 'A'),
          ],
        );
        await sync.applyRemoteBatch(plan);
        await sync.applyRemoteBatch(plan);
        expect(await sync.loadConflicts(), isEmpty);
      });

      test('applyRemoteBatch 拒绝同一 operationId 的载荷 hash 变化', () async {
        final sync = open();
        await sync.applyRemoteBatch(
          _plan(
            batchId: 'b1',
            versions: <SyncEntityVersion>[
              _version('op-1', 'entry', 'e1', hash: 'h1', payload: 'A'),
            ],
          ),
        );

        final conflicting = _plan(
          batchId: 'b2',
          versions: <SyncEntityVersion>[
            _version('op-1', 'entry', 'e1', hash: 'h2', payload: 'B'),
          ],
        );
        await expectLater(
          sync.applyRemoteBatch(conflicting),
          throwsA(isA<SyncConflictException>()),
        );
      });

      test('applyRemoteBatch 校验失败时不写入任何内容（原子性）', () async {
        final sync = open();
        await sync.applyRemoteBatch(
          _plan(
            batchId: 'b1',
            versions: <SyncEntityVersion>[
              _version('op-1', 'entry', 'e1', hash: 'h1', payload: 'A'),
            ],
          ),
        );

        // 同一批次里前面是干净的新操作，后面夹一个 hash 冲突的旧操作：
        // 整批必须一起失败，前面的 op-2 不能留下痕迹。
        final mixed = _plan(
          batchId: 'b2',
          versions: <SyncEntityVersion>[
            _version('op-2', 'entry', 'e2', hash: 'h2', payload: 'B'),
            _version('op-1', 'entry', 'e1', hash: 'changed', payload: 'C'),
          ],
        );
        await expectLater(
          sync.applyRemoteBatch(mixed),
          throwsA(isA<SyncConflictException>()),
        );

        // 用一次干净的重放确认 op-2 尚未被登记为已应用：
        // 若上一批已部分写入，这里会因 op-2 已存在而抛错。
        await sync.applyRemoteBatch(
          _plan(
            batchId: 'b3',
            versions: <SyncEntityVersion>[
              _version('op-2', 'entry', 'e2', hash: 'h2', payload: 'B'),
            ],
          ),
        );
      });

      test('applyRemoteBatch 对因果回退的 tombstone 抛冲突', () async {
        final sync = open();
        // 先应用一个较新的版本。
        await sync.applyRemoteBatch(
          _plan(
            batchId: 'b1',
            versions: <SyncEntityVersion>[
              SyncEntityVersion(
                entity: const SyncEntityKey(
                  scope: 'default',
                  type: 'entry',
                  id: 'e1',
                ),
                version: SyncVersion(
                  dot: const SyncDot(deviceId: 'dev-2', sequence: 2),
                  context: const SyncVersionVector(<String, int>{'dev-2': 2}),
                  logicalTime: 20,
                ),
                payloadHash: 'h2',
                payload: 'B',
                deleted: false,
                operationId: 'op-new',
              ),
            ],
          ),
        );

        // 再来一个严格早于当前版本的删除：属于因果回退，必须拒绝。
        final regressing = _plan(
          batchId: 'b2',
          versions: <SyncEntityVersion>[
            _version(
              'op-old',
              'entry',
              'e1',
              hash: 'h1',
              payload: null,
              deleted: true,
              context: const <String, int>{'dev-2': 1},
              sequence: 1,
            ),
          ],
        );
        await expectLater(
          sync.applyRemoteBatch(regressing),
          throwsA(isA<SyncConflictException>()),
        );
      });

      test('applyRemoteBatch 接受同一实体的因果后继版本', () async {
        final sync = open();
        await sync.applyRemoteBatch(
          _plan(
            batchId: 'b1',
            versions: <SyncEntityVersion>[
              _version(
                'op-1',
                'entry',
                'e1',
                hash: 'h1',
                payload: 'A',
                context: const <String, int>{'dev-1': 1},
                sequence: 1,
              ),
            ],
          ),
        );
        await sync.applyRemoteBatch(
          _plan(
            batchId: 'b2',
            versions: <SyncEntityVersion>[
              _version(
                'op-2',
                'entry',
                'e1',
                hash: 'h2',
                payload: 'B',
                context: const <String, int>{'dev-1': 2},
                sequence: 2,
              ),
            ],
          ),
        );
        expect(await sync.loadConflicts(), isEmpty);
      });

      test('applyRemoteBatch 记录 KV journal 值供重启后重放', () async {
        final sync = open();
        await sync.applyRemoteBatch(
          _plan(
            batchId: 'b1',
            versions: <SyncEntityVersion>[
              _version('op-1', 'preference', 'themePreference', hash: 'h1'),
            ],
            kvJournalValues: const <String, String>{
              'themePreference': '"dark"',
            },
          ),
        );
        expect(await sync.loadConflicts(), isEmpty);
      });
    });
  }

  test('SQLite outbox 关闭并重开数据库后仍能恢复完整事件', () async {
    final directory = Directory.systemTemp.createTempSync(
      'verifin_sync_outbox_',
    );
    final path = '${directory.path}/outbox.db';
    final batch = _batch('restart-batch', <String>['restart-op']);

    try {
      final firstDatabase = await AppDatabase.open(
        factory: databaseFactoryFfi,
        path: path,
      );
      await SqliteLedgerRepository(firstDatabase).sync.enqueueBatch(batch);
      await firstDatabase.close();

      final reopenedDatabase = await AppDatabase.open(
        factory: databaseFactoryFfi,
        path: path,
      );
      final outbox = await SqliteLedgerRepository(
        reopenedDatabase,
      ).sync.loadOutbox();
      expect(outbox, hasLength(1));
      expect(outbox.single.event, batch.events.single);
      await reopenedDatabase.close();
    } finally {
      await directory.delete(recursive: true);
    }
  });
}

/// SqliteLedgerRepository 需要真实异步建库；这里把「等待建库」的 Future 包装成
/// [SyncRepository]，让契约测试的两条实现路径共用同一个同步的 open() 签名。
class _DeferredSyncRepository implements SyncRepository {
  @override
  Future<SyncSnapshotState> loadSnapshotState() async =>
      (await _ready).loadSnapshotState();
  @override
  Future<PreparedSyncSnapshot> prepareSnapshotPublication() async =>
      (await _ready).prepareSnapshotPublication();
  @override
  Future<void> freezeSnapshotBlobMembers(
    int sequence,
    List<SnapshotBlobMapping> mappings,
  ) async => (await _ready).freezeSnapshotBlobMembers(sequence, mappings);
  @override
  Future<void> markSnapshotPublished(
    int sequence, {
    required String filename,
    required String snapshotHash,
  }) async => (await _ready).markSnapshotPublished(
    sequence,
    filename: filename,
    snapshotHash: snapshotHash,
  );
  @override
  Future<void> abandonIncompleteSnapshotPublications() async =>
      (await _ready).abandonIncompleteSnapshotPublications();
  @override
  Future<void> recordV1Scan({
    required bool v1HistoryFound,
    required String? fingerprint,
  }) async => (await _ready).recordV1Scan(
    v1HistoryFound: v1HistoryFound,
    fingerprint: fingerprint,
  );
  @override
  Future<void> markV1ReadyToCutover() async =>
      (await _ready).markV1ReadyToCutover();
  @override
  Future<void> markV1MigrationNotRequired() async =>
      (await _ready).markV1MigrationNotRequired();
  @override
  Future<void> completeV1CutoverWithPublication(
    int sequence, {
    required String filename,
    required String snapshotHash,
  }) async => (await _ready).completeV1CutoverWithPublication(
    sequence,
    filename: filename,
    snapshotHash: snapshotHash,
  );
  @override
  Future<SyncSnapshotCursor?> loadSnapshotCursor(String deviceId) async =>
      (await _ready).loadSnapshotCursor(deviceId);
  @override
  Future<List<SyncSnapshotCursor>> loadSnapshotCursors() async =>
      (await _ready).loadSnapshotCursors();
  @override
  Future<void> saveSnapshotCursor(SnapshotCursorAdvance cursor) async =>
      (await _ready).saveSnapshotCursor(cursor);
  @override
  Future<void> saveVerifiedBlobMapping(SnapshotBlobMapping mapping) async =>
      (await _ready).saveVerifiedBlobMapping(mapping);
  @override
  Future<void> markSnapshotBlobMappingInvalid(
    String rawHash,
    String fileHash,
  ) async => (await _ready).markSnapshotBlobMappingInvalid(rawHash, fileHash);
  @override
  Future<List<SnapshotBlobMapping>> loadVerifiedBlobMappings(
    String rawHash,
  ) async => (await _ready).loadVerifiedBlobMappings(rawHash);
  @override
  Future<String?> loadEnrollmentState() async =>
      (await _ready).loadEnrollmentState();
  @override
  Future<void> saveEnrollmentState(String state) async =>
      (await _ready).saveEnrollmentState(state);
  @override
  Future<void> saveConflictChoice(
    String id,
    String conflict,
    SyncEvent? event,
  ) async => (await _ready).saveConflictChoice(id, conflict, event);
  @override
  Future<void> finalizePreparedBatches() async =>
      (await _ready).finalizePreparedBatches();
  @override
  Future<void> removePendingBatch(String id) async =>
      (await _ready).removePendingBatch(id);
  @override
  Future<Map<SyncEntityKey, SyncEntityVersion>> loadEntityHeads(
    Set<SyncEntityKey> keys,
  ) async => (await _ready).loadEntityHeads(keys);
  @override
  Future<void> savePendingBatch(
    String id,
    List<SyncEvent> events,
    String reason,
  ) async => (await _ready).savePendingBatch(id, events, reason);
  @override
  Future<List<SyncPendingBatch>> loadPendingBatches() async =>
      (await _ready).loadPendingBatches();
  @override
  Future<Map<String, String>> loadAppliedOperationHashes(
    List<String> ids,
  ) async => (await _ready).loadAppliedOperationHashes(ids);
  _DeferredSyncRepository(this._ready);

  final Future<SyncRepository> _ready;

  @override
  Future<void> applyRemoteBatch(RemoteApplyPlan plan) async =>
      (await _ready).applyRemoteBatch(plan);

  @override
  Future<void> enqueueBatch(SyncBatchRecord batch) async =>
      (await _ready).enqueueBatch(batch);

  @override
  Future<SyncDeviceState> loadDeviceState() async =>
      (await _ready).loadDeviceState();

  @override
  Future<List<SyncConflictRecord>> loadConflicts() async =>
      (await _ready).loadConflicts();

  @override
  Future<void> storeConflict(SyncConflictRecord conflict) async =>
      (await _ready).storeConflict(conflict);

  @override
  Future<void> removeConflict(String conflictId) async =>
      (await _ready).removeConflict(conflictId);

  @override
  Future<List<SyncOutboxRecord>> loadOutbox() async =>
      (await _ready).loadOutbox();

  @override
  Future<SyncScanState> loadScanState() async => (await _ready).loadScanState();

  @override
  Future<void> markBatchUploaded(String batchId) async =>
      (await _ready).markBatchUploaded(batchId);

  @override
  Future<void> saveDeviceState(SyncDeviceState state) async =>
      (await _ready).saveDeviceState(state);

  @override
  Future<void> saveScanState(SyncScanState state) async =>
      (await _ready).saveScanState(state);

  @override
  Future<Map<SyncEntityKey, String>> loadShadow() async =>
      (await _ready).loadShadow();

  @override
  Future<void> saveShadow(Map<SyncEntityKey, String> shadow) async =>
      (await _ready).saveShadow(shadow);

  @override
  Future<List<KvJournalEntry>> loadPendingKvJournal() async =>
      (await _ready).loadPendingKvJournal();

  @override
  Future<void> markKvJournalApplied(int id) async =>
      (await _ready).markKvJournalApplied(id);
}

SyncBatchRecord _batch(String batchId, List<String> operationIds) {
  final events = <SyncEvent>[
    for (final operationId in operationIds)
      _event(operationId: operationId, batchId: batchId),
  ];
  return SyncBatchRecord(
    batchId: batchId,
    events: events,
    manifest: SyncBatchManifest(
      batchId: batchId,
      operationIds: operationIds,
      blobHashes: const <String>[],
      manifestHash: 'manifest-$batchId',
    ),
  );
}

SyncEvent _event({required String operationId, required String batchId}) {
  const payload = <String, Object?>{'note': 'p'};
  return SyncEvent(
    protocolVersion: '1',
    operationId: operationId,
    version: const SyncVersion(
      dot: SyncDot(deviceId: 'dev-1', sequence: 1),
      context: SyncVersionVector(<String, int>{'dev-1': 1}),
      logicalTime: 1,
    ),
    entity: const SyncEntityKey(scope: 'default', type: 'entry', id: 'e1'),
    operation: SyncOperationKind.upsert,
    payloadHash: computeSyncPayloadHash(payload),
    payload: payload,
    batchId: batchId,
    keyFingerprint: 'none',
  );
}

/// 构造 [RemoteApplyPlan]。默认 appliedOperationIds 取自 entityVersions；
/// 需要表达「有已应用操作、但没有对应实体版本」的批次时，用 [appliedOperationIds]
/// 与 [appliedPayloadHashes] 显式覆盖。
RemoteApplyPlan _plan({
  required String batchId,
  required List<SyncEntityVersion> versions,
  List<String>? appliedOperationIds,
  Map<String, String> appliedPayloadHashes = const <String, String>{},
  Map<String, String> kvJournalValues = const <String, String>{},
  SnapshotCursorAdvance? cursorAdvance,
}) {
  return RemoteApplyPlan(
    batchId: batchId,
    entityVersions: versions,
    appliedOperationIds:
        appliedOperationIds ?? versions.map((v) => v.operationId).toList(),
    shadowHashes: <String, String>{
      for (final version in versions)
        encodeSyncEntityKey(version.entity): version.payloadHash,
    },
    // 无实体版本的操作没有 shadow 行，其 hash 只存在于 appliedPayloadHashes。
    appliedPayloadHashes: <String, String>{
      for (final version in versions) version.operationId: version.payloadHash,
      ...appliedPayloadHashes,
    },
    kvJournalValues: kvJournalValues,
    cursorAdvance: cursorAdvance,
  );
}

/// 构造一个默认来自 dev-1、序列自增的实体版本，便于单点覆盖某几个字段。
SyncEntityVersion _version(
  String operationId,
  String type,
  String id, {
  required String hash,
  Object? payload,
  bool deleted = false,
  Map<String, int> context = const <String, int>{'dev-1': 1},
  int sequence = 1,
}) {
  return SyncEntityVersion(
    entity: SyncEntityKey(scope: 'default', type: type, id: id),
    version: SyncVersion(
      dot: SyncDot(deviceId: 'dev-1', sequence: sequence),
      context: SyncVersionVector(context),
      logicalTime: sequence,
    ),
    payloadHash: hash,
    payload: payload,
    deleted: deleted,
    operationId: operationId,
  );
}

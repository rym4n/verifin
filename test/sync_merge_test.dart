import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/backup/webdav_config.dart';
import 'package:verifin/app/sync/sync_clock.dart';
import 'package:verifin/app/sync/sync_engine.dart';
import 'package:verifin/app/sync/sync_models.dart';
import 'package:verifin/app/sync/webdav_sync_transport_stub.dart';

import 'support/in_memory_ledger_repository.dart';

/// 同步合并语义测试：因果关系、冲突检测、幂等性。
void main() {
  group('SyncEngine · 合并语义', () {
    test('两个离线设备分别添加条目产生两条记录', () async {
      final repo = InMemoryLedgerRepository();
      final transport = StubWebdavSyncTransport();
      final engine = SyncEngine(
        repository: repo.sync,
        transport: transport,
        controller: repo,
      );

      // Device A adds entry-1.
      final clockA = SyncClock.createWithDeviceId('dev-a');
      final eventA = SyncEvent(
        protocolVersion: syncProtocolVersion,
        operationId: clockA.nextOperationId(),
        version: clockA.nextVersion(),
        entity: const SyncEntityKey(
          scope: 'ledger',
          type: 'entries',
          id: 'entry-1',
        ),
        operation: SyncOperationKind.upsert,
        payloadHash: computeSyncPayloadHash({'amount': 100}),
        payload: {'amount': 100},
        batchId: 'batch-a',
        keyFingerprint: 'test-key',
      );

      // Device B adds entry-2.
      final clockB = SyncClock.createWithDeviceId('dev-b');
      final eventB = SyncEvent(
        protocolVersion: syncProtocolVersion,
        operationId: clockB.nextOperationId(),
        version: clockB.nextVersion(),
        entity: const SyncEntityKey(
          scope: 'ledger',
          type: 'entries',
          id: 'entry-2',
        ),
        operation: SyncOperationKind.upsert,
        payloadHash: computeSyncPayloadHash({'amount': 200}),
        payload: {'amount': 200},
        batchId: 'batch-b',
        keyFingerprint: 'test-key',
      );

      await transport.simulateRemoteBatch('dev-a', 1, [eventA]);
      await transport.simulateRemoteBatch('dev-b', 1, [eventB]);

      final result = await engine.run(trigger: SyncTrigger.manual);
      expect(result.downloaded, 2);
      expect(result.conflicts, 0);

      final data = repo.exportDataForSync();
      final entries = data['entries'] as List?;
      expect(entries, isNotNull);
      expect(entries!.length, 2);
    });

    test('同一操作重复应用是幂等的（不产生重复记录）', () async {
      final repo = InMemoryLedgerRepository();
      final transport = StubWebdavSyncTransport();
      final engine = SyncEngine(
        repository: repo.sync,
        transport: transport,
        controller: repo,
      );

      final clock = SyncClock.createWithDeviceId('dev-a');
      final event = SyncEvent(
        protocolVersion: syncProtocolVersion,
        operationId: 'op-1',
        version: clock.nextVersion(),
        entity: const SyncEntityKey(
          scope: 'ledger',
          type: 'entries',
          id: 'entry-1',
        ),
        operation: SyncOperationKind.upsert,
        payloadHash: computeSyncPayloadHash({'amount': 100}),
        payload: {'amount': 100},
        batchId: 'batch-1',
        keyFingerprint: 'test-key',
      );

      await transport.simulateRemoteBatch('dev-a', 1, [event]);
      await engine.run(trigger: SyncTrigger.manual);

      // Apply the same batch again.
      await transport.simulateRemoteBatch('dev-a', 2, [event]);
      final result = await engine.run(trigger: SyncTrigger.manual);

      expect(result.downloaded, 0); // Already applied, skip.
      final data = repo.exportDataForSync();
      final entries = data['entries'] as List?;
      expect(entries?.length, 1); // Still just one entry.
    });

    test('因果后继替换前驱（causal successor replaces predecessor）', () async {
      final repo = InMemoryLedgerRepository();
      final transport = StubWebdavSyncTransport();
      final engine = SyncEngine(
        repository: repo.sync,
        transport: transport,
        controller: repo,
      );

      final clock = SyncClock.createWithDeviceId('dev-a');

      // Version 1: initial value.
      final v1 = clock.nextVersion();
      final event1 = SyncEvent(
        protocolVersion: syncProtocolVersion,
        operationId: clock.nextOperationId(),
        version: v1,
        entity: const SyncEntityKey(
          scope: 'global',
          type: 'profile',
          id: 'default',
        ),
        operation: SyncOperationKind.upsert,
        payloadHash: computeSyncPayloadHash({'name': 'Alice'}),
        payload: {'name': 'Alice'},
        batchId: 'batch-1',
        keyFingerprint: 'test-key',
      );

      // Version 2: update (successor of v1).
      final v2 = clock.nextVersion();
      final event2 = SyncEvent(
        protocolVersion: syncProtocolVersion,
        operationId: clock.nextOperationId(),
        version: v2,
        entity: const SyncEntityKey(
          scope: 'global',
          type: 'profile',
          id: 'default',
        ),
        operation: SyncOperationKind.upsert,
        payloadHash: computeSyncPayloadHash({'name': 'Bob'}),
        payload: {'name': 'Bob'},
        batchId: 'batch-2',
        keyFingerprint: 'test-key',
      );

      await transport.simulateRemoteBatch('dev-a', 1, [event1]);
      await transport.simulateRemoteBatch('dev-a', 2, [event2]);

      await engine.run(trigger: SyncTrigger.manual);

      final data = repo.exportDataForSync();
      expect(data['profile'], {'name': 'Bob'}); // v2 replaces v1.
    });

    test('并发版本创建冲突记录（concurrent versions create conflict）', () async {
      final repo = InMemoryLedgerRepository();
      final transport = StubWebdavSyncTransport();
      final engine = SyncEngine(
        repository: repo.sync,
        transport: transport,
        controller: repo,
      );

      // Device A and B both edit the same entity concurrently.
      final clockA = SyncClock.createWithDeviceId('dev-a');
      final clockB = SyncClock.createWithDeviceId('dev-b');

      final eventA = SyncEvent(
        protocolVersion: syncProtocolVersion,
        operationId: clockA.nextOperationId(),
        version: clockA.nextVersion(),
        entity: const SyncEntityKey(
          scope: 'global',
          type: 'profile',
          id: 'default',
        ),
        operation: SyncOperationKind.upsert,
        payloadHash: computeSyncPayloadHash({'name': 'Alice'}),
        payload: {'name': 'Alice'},
        batchId: 'batch-a',
        keyFingerprint: 'test-key',
      );

      final eventB = SyncEvent(
        protocolVersion: syncProtocolVersion,
        operationId: clockB.nextOperationId(),
        version: clockB.nextVersion(),
        entity: const SyncEntityKey(
          scope: 'global',
          type: 'profile',
          id: 'default',
        ),
        operation: SyncOperationKind.upsert,
        payloadHash: computeSyncPayloadHash({'name': 'Bob'}),
        payload: {'name': 'Bob'},
        batchId: 'batch-b',
        keyFingerprint: 'test-key',
      );

      await transport.simulateRemoteBatch('dev-a', 1, [eventA]);
      await transport.simulateRemoteBatch('dev-b', 1, [eventB]);

      final result = await engine.run(trigger: SyncTrigger.manual);
      expect(result.conflicts, 1);

      final conflicts = await engine.conflicts();
      expect(conflicts.length, 1);
    });

    test('删除与编辑的并发创建冲突', () async {
      final repo = InMemoryLedgerRepository();
      final transport = StubWebdavSyncTransport();
      final engine = SyncEngine(
        repository: repo.sync,
        transport: transport,
        controller: repo,
      );

      final clockA = SyncClock.createWithDeviceId('dev-a');
      final clockB = SyncClock.createWithDeviceId('dev-b');

      // Device A deletes.
      final eventA = SyncEvent(
        protocolVersion: syncProtocolVersion,
        operationId: clockA.nextOperationId(),
        version: clockA.nextVersion(),
        entity: const SyncEntityKey(
          scope: 'ledger',
          type: 'entries',
          id: 'entry-1',
        ),
        operation: SyncOperationKind.delete,
        payloadHash: computeSyncPayloadHash(null),
        payload: null,
        batchId: 'batch-a',
        keyFingerprint: 'test-key',
      );

      // Device B edits.
      final eventB = SyncEvent(
        protocolVersion: syncProtocolVersion,
        operationId: clockB.nextOperationId(),
        version: clockB.nextVersion(),
        entity: const SyncEntityKey(
          scope: 'ledger',
          type: 'entries',
          id: 'entry-1',
        ),
        operation: SyncOperationKind.upsert,
        payloadHash: computeSyncPayloadHash({'amount': 100}),
        payload: {'amount': 100},
        batchId: 'batch-b',
        keyFingerprint: 'test-key',
      );

      await transport.simulateRemoteBatch('dev-a', 1, [eventA]);
      await transport.simulateRemoteBatch('dev-b', 1, [eventB]);

      final result = await engine.run(trigger: SyncTrigger.manual);
      expect(result.conflicts, 1);
    });

    test('相同路径不同字节内容创建冲突', () async {
      final repo = InMemoryLedgerRepository();
      final transport = StubWebdavSyncTransport();
      final engine = SyncEngine(
        repository: repo.sync,
        transport: transport,
        controller: repo,
      );

      final clockA = SyncClock.createWithDeviceId('dev-a');
      final clockB = SyncClock.createWithDeviceId('dev-b');

      final eventA = SyncEvent(
        protocolVersion: syncProtocolVersion,
        operationId: clockA.nextOperationId(),
        version: clockA.nextVersion(),
        entity: const SyncEntityKey(
          scope: 'global',
          type: 'profile',
          id: 'default',
        ),
        operation: SyncOperationKind.upsert,
        payloadHash: computeSyncPayloadHash({'name': 'Alice', 'age': 30}),
        payload: {'name': 'Alice', 'age': 30},
        batchId: 'batch-a',
        keyFingerprint: 'test-key',
      );

      final eventB = SyncEvent(
        protocolVersion: syncProtocolVersion,
        operationId: clockB.nextOperationId(),
        version: clockB.nextVersion(),
        entity: const SyncEntityKey(
          scope: 'global',
          type: 'profile',
          id: 'default',
        ),
        operation: SyncOperationKind.upsert,
        payloadHash: computeSyncPayloadHash({'name': 'Bob', 'age': 25}),
        payload: {'name': 'Bob', 'age': 25},
        batchId: 'batch-b',
        keyFingerprint: 'test-key',
      );

      await transport.simulateRemoteBatch('dev-a', 1, [eventA]);
      await transport.simulateRemoteBatch('dev-b', 1, [eventB]);

      final result = await engine.run(trigger: SyncTrigger.manual);
      expect(result.conflicts, 1);
    });
  });
}

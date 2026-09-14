import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/backup/webdav_config.dart';
import 'package:verifin/app/sync/sync_clock.dart';
import 'package:verifin/app/sync/sync_engine.dart';
import 'package:verifin/app/sync/sync_models.dart';
import 'package:verifin/app/sync/webdav_sync_transport_stub.dart';

import 'support/in_memory_ledger_repository.dart';

const testConfig = WebdavConfig(
  url: 'https://test.example.com/dav',
  username: 'test',
  password: 'test',
);

/// 基线初始化与首次加入测试。
void main() {
  group('SyncEngine · 基线初始化', () {
    test('空远端创建基线批次而不视为新用户编辑', () async {
      final repo = InMemoryLedgerRepository();
      final transport = StubWebdavSyncTransport();
      final engine = SyncEngine(
        repository: repo.sync,
        transport: transport,
        controller: repo,
        config: testConfig,
      );

      // Populate local data.
      repo.setProfile({'name': 'LocalUser'});
      repo.addTestEntry({'id': 'entry-1', 'amount': 100});

      // Initialize from restored data with empty remote.
      await engine.initializeFromRestoredData();

      // Should create a baseline batch.
      final outbox = await repo.sync.loadOutbox();
      expect(outbox, isNotEmpty);

      // Upload the baseline.
      final result = await engine.run(trigger: SyncTrigger.startup);
      expect(result.uploaded, greaterThan(0));
      expect(result.errorCode, isNull);
    });

    test('非空远端重建远端状态并创建 join 冲突（本地哈希不同）', () async {
      final repo = InMemoryLedgerRepository();
      final transport = StubWebdavSyncTransport();
      final engine = SyncEngine(
        repository: repo.sync,
        transport: transport,
        controller: repo,
        config: testConfig,
      );

      // Remote device already has data.
      final clockRemote = SyncClock.createWithDeviceId('dev-remote');
      final eventRemote = SyncEvent(
        protocolVersion: syncProtocolVersion,
        operationId: clockRemote.nextOperationId(),
        version: clockRemote.nextVersion(),
        entity: const SyncEntityKey(
          scope: 'global',
          type: 'profile',
          id: 'default',
        ),
        operation: SyncOperationKind.upsert,
        payloadHash: computeSyncPayloadHash({'name': 'RemoteUser'}),
        payload: {'name': 'RemoteUser'},
        batchId: 'batch-remote',
        keyFingerprint: 'test-key',
      );
      await transport.simulateRemoteBatch('dev-remote', 1, [eventRemote]);

      // Local has different data.
      repo.setProfile({'name': 'LocalUser'});

      // Initialize from restored data with non-empty remote.
      await engine.initializeFromRestoredData();

      // Should detect conflict.
      final conflicts = await engine.conflicts();
      expect(conflicts.length, 1);
      expect(conflicts.first.entity.type, 'profile');
    });

    test('非空远端本地哈希相同不产生冲突', () async {
      final repo = InMemoryLedgerRepository();
      final transport = StubWebdavSyncTransport();
      final engine = SyncEngine(
        repository: repo.sync,
        transport: transport,
        controller: repo,
        config: testConfig,
      );

      // Remote device has data.
      final clockRemote = SyncClock.createWithDeviceId('dev-remote');
      final profile = {'name': 'SameUser'};
      final eventRemote = SyncEvent(
        protocolVersion: syncProtocolVersion,
        operationId: clockRemote.nextOperationId(),
        version: clockRemote.nextVersion(),
        entity: const SyncEntityKey(
          scope: 'global',
          type: 'profile',
          id: 'default',
        ),
        operation: SyncOperationKind.upsert,
        payloadHash: computeSyncPayloadHash(profile),
        payload: profile,
        batchId: 'batch-remote',
        keyFingerprint: 'test-key',
      );
      await transport.simulateRemoteBatch('dev-remote', 1, [eventRemote]);

      // Local has same data.
      repo.setProfile(profile);

      // Initialize from restored data.
      await engine.initializeFromRestoredData();

      // No conflict expected.
      final conflicts = await engine.conflicts();
      expect(conflicts, isEmpty);
    });

    test('初始化期间到达的事件在下次扫描处理', () async {
      final repo = InMemoryLedgerRepository();
      final transport = StubWebdavSyncTransport();
      final engine = SyncEngine(
        repository: repo.sync,
        transport: transport,
        controller: repo,
        config: testConfig,
      );

      // Start with empty remote.
      repo.setProfile({'name': 'LocalUser'});
      await engine.initializeFromRestoredData();

      // Remote device uploads during scan.
      final clockRemote = SyncClock.createWithDeviceId('dev-remote');
      final eventRemote = SyncEvent(
        protocolVersion: syncProtocolVersion,
        operationId: clockRemote.nextOperationId(),
        version: clockRemote.nextVersion(),
        entity: const SyncEntityKey(
          scope: 'ledger',
          type: 'entries',
          id: 'entry-1',
        ),
        operation: SyncOperationKind.upsert,
        payloadHash: computeSyncPayloadHash({'amount': 100}),
        payload: {'amount': 100},
        batchId: 'batch-remote',
        keyFingerprint: 'test-key',
      );
      await transport.simulateRemoteBatch('dev-remote', 1, [eventRemote]);

      // Next sync run should process it.
      final result = await engine.run(trigger: SyncTrigger.manual);
      expect(result.downloaded, 1);

      final data = repo.exportDataForSync();
      final entries = data['entries'] as List?;
      expect(entries?.length, 1);
    });

    test('记录扫描前的设备高水位标记', () async {
      final repo = InMemoryLedgerRepository();
      final transport = StubWebdavSyncTransport();
      final engine = SyncEngine(
        repository: repo.sync,
        transport: transport,
        controller: repo,
        config: testConfig,
      );

      // Remote has events up to sequence 5.
      final clockRemote = SyncClock.createWithDeviceId('dev-remote');
      for (var i = 1; i <= 5; i++) {
        clockRemote.nextVersion();
        final event = SyncEvent(
          protocolVersion: syncProtocolVersion,
          operationId: clockRemote.nextOperationId(),
          version: SyncVersion(
            dot: SyncDot(deviceId: 'dev-remote', sequence: i),
            context: clockRemote.knownVector,
            logicalTime: i,
          ),
          entity: SyncEntityKey(
            scope: 'ledger',
            type: 'entries',
            id: 'entry-$i',
          ),
          operation: SyncOperationKind.upsert,
          payloadHash: computeSyncPayloadHash({'amount': i * 100}),
          payload: {'amount': i * 100},
          batchId: 'batch-$i',
          keyFingerprint: 'test-key',
        );
        await transport.simulateRemoteBatch('dev-remote', i, [event]);
      }

      await engine.initializeFromRestoredData();

      // Scan state should record high-water mark.
      final scanState = await repo.sync.loadScanState();
      expect(scanState.contiguousSequences['dev-remote'], 5);
    });
  });
}

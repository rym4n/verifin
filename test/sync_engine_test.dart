import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/backup/webdav_config.dart';
import 'package:verifin/app/sync/sync_clock.dart';
import 'package:verifin/app/sync/sync_engine.dart';
import 'package:verifin/app/sync/sync_models.dart';
import 'package:verifin/app/sync/webdav_sync_transport_stub.dart';

import 'support/in_memory_ledger_repository.dart';

/// 同步引擎端到端测试：覆盖上传、下载、合并、基线初始化。
void main() {
  group('SyncEngine · 上传与下载', () {
    test('空 outbox 返回零上传', () async {
      final repo = InMemoryLedgerRepository();
      final transport = StubWebdavSyncTransport();
      final engine = SyncEngine(
        repository: repo.sync,
        transport: transport,
        controller: repo,
        config: testConfig,
      );

      final result = await engine.run(trigger: SyncTrigger.manual);
      expect(result.uploaded, 0);
      expect(result.errorCode, isNull);
    });

    test('单批次上传创建事件文件、manifest 和 commit 标记', () async {
      final repo = InMemoryLedgerRepository();
      final transport = StubWebdavSyncTransport();
      final engine = SyncEngine(
        repository: repo.sync,
        transport: transport,
        controller: repo,
        config: testConfig,
      );

      // Enqueue a batch.
      final clock = SyncClock.createWithDeviceId('dev-1');
      final event = SyncEvent(
        protocolVersion: syncProtocolVersion,
        operationId: clock.nextOperationId(),
        version: clock.nextVersion(),
        entity: const SyncEntityKey(
          scope: 'global',
          type: 'profile',
          id: 'default',
        ),
        operation: SyncOperationKind.upsert,
        payloadHash: computeSyncPayloadHash({'name': 'Test'}),
        payload: {'name': 'Test'},
        batchId: 'batch-1',
        keyFingerprint: 'test-key',
      );
      await engine.enqueueBatch(
        SyncBatchRecord(
          batchId: 'batch-1',
          events: [event],
          manifest: SyncBatchManifest(
            batchId: 'batch-1',
            operationIds: [event.operationId],
            blobHashes: const [],
            manifestHash: 'manifest-hash',
          ),
        ),
      );

      final result = await engine.run(trigger: SyncTrigger.manual);
      expect(result.uploaded, 1);
      expect(result.errorCode, isNull);

      // Verify files created.
      final files = await transport.listSyncFiles(testConfig);
      expect(files.where((f) => f.kind == SyncFileKind.event).length, 1);
      expect(files.where((f) => f.kind == SyncFileKind.manifest).length, 1);
      expect(files.where((f) => f.kind == SyncFileKind.commit).length, 1);
    });

    test('commit 失败保留 outbox 行以便重试', () async {
      final repo = InMemoryLedgerRepository();
      final transport = StubWebdavSyncTransport()..failCommitUploads = true;
      final engine = SyncEngine(
        repository: repo.sync,
        transport: transport,
        controller: repo,
        config: testConfig,
      );

      final clock = SyncClock.createWithDeviceId('dev-1');
      final event = SyncEvent(
        protocolVersion: syncProtocolVersion,
        operationId: clock.nextOperationId(),
        version: clock.nextVersion(),
        entity: const SyncEntityKey(
          scope: 'global',
          type: 'profile',
          id: 'default',
        ),
        operation: SyncOperationKind.upsert,
        payloadHash: computeSyncPayloadHash({'name': 'Test'}),
        payload: {'name': 'Test'},
        batchId: 'batch-1',
        keyFingerprint: 'test-key',
      );
      await engine.enqueueBatch(
        SyncBatchRecord(
          batchId: 'batch-1',
          events: [event],
          manifest: SyncBatchManifest(
            batchId: 'batch-1',
            operationIds: [event.operationId],
            blobHashes: const [],
            manifestHash: 'manifest-hash',
          ),
        ),
      );

      final result = await engine.run(trigger: SyncTrigger.manual);
      expect(result.uploaded, 0);
      expect(result.errorCode, isNotNull);

      // Outbox should still have the batch.
      final outbox = await repo.sync.loadOutbox();
      expect(outbox, isNotEmpty);
    });
  });

  group('SyncEngine · 下载与应用', () {
    test('下载远端事件并应用到本地', () async {
      final repo = InMemoryLedgerRepository();
      final transport = StubWebdavSyncTransport();
      final engine = SyncEngine(
        repository: repo.sync,
        transport: transport,
        controller: repo,
        config: testConfig,
      );

      // Upload from remote device.
      final clock = SyncClock.createWithDeviceId('dev-remote');
      final event = SyncEvent(
        protocolVersion: syncProtocolVersion,
        operationId: clock.nextOperationId(),
        version: clock.nextVersion(),
        entity: const SyncEntityKey(
          scope: 'global',
          type: 'profile',
          id: 'default',
        ),
        operation: SyncOperationKind.upsert,
        payloadHash: computeSyncPayloadHash({'name': 'Remote'}),
        payload: {'name': 'Remote'},
        batchId: 'batch-remote',
        keyFingerprint: 'test-key',
      );
      await transport.simulateRemoteBatch('dev-remote', 1, [event]);

      final result = await engine.run(trigger: SyncTrigger.manual);
      expect(result.downloaded, 1);
      expect(result.errorCode, isNull);

      // Verify applied to controller.
      final data = repo.exportDataForSync();
      expect(data['profile'], {'name': 'Remote'});
    });

    test('不完整批次（缺少 commit）延迟到下次扫描', () async {
      final repo = InMemoryLedgerRepository();
      final transport = StubWebdavSyncTransport();
      final engine = SyncEngine(
        repository: repo.sync,
        transport: transport,
        controller: repo,
        config: testConfig,
      );

      // Upload event and manifest, but no commit.
      final clock = SyncClock.createWithDeviceId('dev-remote');
      final event = SyncEvent(
        protocolVersion: syncProtocolVersion,
        operationId: clock.nextOperationId(),
        version: clock.nextVersion(),
        entity: const SyncEntityKey(
          scope: 'global',
          type: 'profile',
          id: 'default',
        ),
        operation: SyncOperationKind.upsert,
        payloadHash: computeSyncPayloadHash({'name': 'Remote'}),
        payload: {'name': 'Remote'},
        batchId: 'batch-remote',
        keyFingerprint: 'test-key',
      );
      await transport.simulateRemoteBatch('dev-remote', 1, [
        event,
      ], includeCommit: false);

      final result = await engine.run(trigger: SyncTrigger.manual);
      expect(result.downloaded, 0);
      expect(result.pending, 1);
    });
  });
}

// Test WebDAV config
const testConfig = WebdavConfig(
  url: 'https://test.example.com/dav',
  username: 'test',
  password: 'test',
);

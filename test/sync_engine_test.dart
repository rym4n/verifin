import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:verifin/app/backup/webdav_config.dart';
import 'package:verifin/app/sync/sync_clock.dart';
import 'package:verifin/app/sync/sync_engine.dart';
import 'package:verifin/app/sync/sync_models.dart';
import 'package:verifin/app/sync/webdav_sync_transport_stub.dart';
import 'package:verifin/data/app_database.dart';
import 'package:verifin/data/ledger_repository.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/local_storage/local_storage.dart';

import 'support/in_memory_ledger_repository.dart';

/// 同步引擎端到端测试：覆盖上传、下载、合并、基线初始化。
void main() {
  setUpAll(sqfliteFfiInit);

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
        payloadHash: computeSyncPayloadHash({
          'nickname': 'Test',
          'bio': '',
          'avatarDataUrl': '',
        }),
        payload: {'nickname': 'Test', 'bio': '', 'avatarDataUrl': ''},
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

    test('关闭 SQLite 并重建 repository/engine 后仍完整上传', () async {
      final directory = Directory.systemTemp.createTempSync(
        'verifin_sync_engine_restart_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final databasePath = '${directory.path}/restart.db';
      final firstDatabase = await AppDatabase.open(
        factory: databaseFactoryFfi,
        path: databasePath,
      );
      final firstRepository = SqliteLedgerRepository(firstDatabase);
      final projection = InMemoryLedgerRepository();
      final transport = StubWebdavSyncTransport();
      final firstEngine = SyncEngine(
        repository: firstRepository.sync,
        transport: transport,
        controller: projection,
        config: testConfig,
      );
      final clock = SyncClock.createWithDeviceId('dev-restart');
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
        payloadHash: computeSyncPayloadHash({
          'nickname': 'Restart',
          'bio': '',
          'avatarDataUrl': '',
        }),
        payload: {'nickname': 'Restart', 'bio': '', 'avatarDataUrl': ''},
        batchId: 'restart-batch',
        keyFingerprint: 'test-key',
      );
      await firstEngine.enqueueBatch(
        SyncBatchRecord(
          batchId: 'restart-batch',
          events: <SyncEvent>[event],
          manifest: SyncBatchManifest(
            batchId: 'restart-batch',
            operationIds: <String>[event.operationId],
            blobHashes: const <String>[],
            manifestHash: 'restart-manifest-hash',
          ),
        ),
      );
      await firstDatabase.close();

      final reopenedDatabase = await AppDatabase.open(
        factory: databaseFactoryFfi,
        path: databasePath,
      );
      addTearDown(reopenedDatabase.close);
      final reopenedRepository = SqliteLedgerRepository(reopenedDatabase);
      final restartedEngine = SyncEngine(
        repository: reopenedRepository.sync,
        transport: transport,
        controller: projection,
        config: testConfig,
      );
      final result = await restartedEngine.run(trigger: SyncTrigger.manual);

      expect(result.errorCode, isNull);
      expect(result.uploaded, 1);
      final files = await transport.listSyncFiles(testConfig);
      expect(
        files.where((file) => file.kind == SyncFileKind.event),
        hasLength(1),
      );
      expect(await reopenedRepository.sync.loadOutbox(), isEmpty);
    });

    test('v17 旧 outbox 缺少事件正文时报明确错误并保留待传行', () async {
      final database = await AppDatabase.open(
        factory: databaseFactoryFfi,
        path: inMemoryDatabasePath,
      );
      addTearDown(database.close);
      await database.db.insert('sync_outbox', <String, Object?>{
        'batch_id': 'legacy-batch',
        'operation_id': 'legacy-operation',
        'relative_path':
            'events/legacy-device/00000000000000000001-legacy-operation.vfsync',
        'payload_hash': 'legacy-hash',
        'retry_count': 2,
        'uploaded': 0,
        'event_json': null,
      });
      final repository = SqliteLedgerRepository(database);
      final projection = InMemoryLedgerRepository();
      final transport = StubWebdavSyncTransport();
      final engine = SyncEngine(
        repository: repository.sync,
        transport: transport,
        controller: projection,
        config: testConfig,
      );

      final result = await engine.run(trigger: SyncTrigger.manual);

      expect(result.uploaded, 0);
      expect(result.errorCode, contains('outbox_event_missing'));
      expect(await transport.listSyncFiles(testConfig), isEmpty);
      final row = (await database.db.query('sync_outbox')).single;
      expect(row['uploaded'], 0);
      expect(row['retry_count'], 2);
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
        payloadHash: computeSyncPayloadHash({
          'nickname': 'Test',
          'bio': '',
          'avatarDataUrl': '',
        }),
        payload: {'nickname': 'Test', 'bio': '', 'avatarDataUrl': ''},
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
      final controller = await VeriFinController.create(
        LocalKeyValueStore(),
        repository: repo,
      );
      addTearDown(controller.dispose);
      final transport = StubWebdavSyncTransport();
      final engine = SyncEngine(
        repository: repo.sync,
        transport: transport,
        controller: controller,
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
          id: 'singleton',
        ),
        operation: SyncOperationKind.upsert,
        payloadHash: computeSyncPayloadHash({
          'nickname': 'Remote',
          'bio': '',
          'avatarDataUrl': '',
        }),
        payload: {'nickname': 'Remote', 'bio': '', 'avatarDataUrl': ''},
        batchId: 'batch-remote',
        keyFingerprint: 'test-key',
      );
      await transport.simulateRemoteBatch('dev-remote', 1, [event]);

      final result = await engine.run(trigger: SyncTrigger.manual);
      expect(result.downloaded, 1);
      expect(result.errorCode, isNull);

      // Verify applied to controller.
      final data = controller.exportDataForSync();
      expect((data['profile'] as Map)['nickname'], 'Remote');
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
        payloadHash: computeSyncPayloadHash({
          'nickname': 'Remote',
          'bio': '',
          'avatarDataUrl': '',
        }),
        payload: {'nickname': 'Remote', 'bio': '', 'avatarDataUrl': ''},
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

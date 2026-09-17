import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:verifin/app/backup/webdav_config.dart';
import 'package:verifin/app/sync/sync_clock.dart';
import 'package:verifin/app/sync/sync_engine.dart';
import 'package:verifin/app/sync/sync_models.dart';
import 'package:verifin/app/sync/sync_wire.dart';
import 'package:verifin/app/sync/webdav_sync_transport_stub.dart';
import 'package:verifin/app/sync/webdav_sync_transport.dart';
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

    test(
      'download failure preserves batches already uploaded in the result',
      () async {
        final repo = InMemoryLedgerRepository();
        final transport = _FailDownloadListingTransport();
        final engine = SyncEngine(
          repository: repo.sync,
          transport: transport,
          controller: repo,
          config: testConfig,
        );
        final clock = SyncClock.createWithDeviceId('dev-progress');
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
            'nickname': 'Progress',
            'bio': '',
            'avatarDataUrl': '',
          }),
          payload: {'nickname': 'Progress', 'bio': '', 'avatarDataUrl': ''},
          batchId: 'batch-progress',
          keyFingerprint: 'test-key',
        );
        await engine.enqueueBatch(
          SyncBatchRecord(
            batchId: event.batchId,
            events: [event],
            manifest: SyncBatchManifest(
              batchId: event.batchId,
              operationIds: [event.operationId],
              blobHashes: const [],
              manifestHash: 'manifest-hash',
            ),
          ),
        );

        final result = await engine.run(trigger: SyncTrigger.manual);

        expect(result.uploaded, 1);
        expect(result.downloaded, 0);
        expect(result.conflicts, 0);
        expect(result.pending, 0);
        expect(result.errorCode, 'network');
        expect(await repo.sync.loadOutbox(), isEmpty);
      },
    );

    test(
      'later upload failure preserves earlier completed batch count',
      () async {
        final repo = InMemoryLedgerRepository();
        final transport = _FailSpecificCommitTransport('batch-fail');
        final engine = SyncEngine(
          repository: repo.sync,
          transport: transport,
          controller: repo,
          config: testConfig,
        );
        final clock = SyncClock.createWithDeviceId('dev-partial-upload');
        final first = _profileEvent(clock, 'batch-ok', 'profile-ok');
        final second = _profileEvent(clock, 'batch-fail', 'profile-fail');
        for (final event in <SyncEvent>[first, second]) {
          await engine.enqueueBatch(
            SyncBatchRecord(
              batchId: event.batchId,
              events: [event],
              manifest: SyncBatchManifest(
                batchId: event.batchId,
                operationIds: [event.operationId],
                blobHashes: const [],
                manifestHash: 'manifest-hash',
              ),
            ),
          );
        }

        final result = await engine.run(trigger: SyncTrigger.manual);

        expect(result.uploaded, 1);
        expect(result.errorCode, 'network');
        expect(await repo.sync.loadOutbox(), hasLength(1));
      },
    );

    test('manifest collision reports redacted WebDAV diagnostics', () async {
      final repo = InMemoryLedgerRepository();
      final transport = StubWebdavSyncTransport();
      final engine = SyncEngine(
        repository: repo.sync,
        transport: transport,
        controller: repo,
        config: testConfig,
      );
      final clock = SyncClock.createWithDeviceId('dev-collision');
      final event = _profileEvent(
        clock,
        'batch-collision',
        'profile-collision',
      );
      await engine.enqueueBatch(
        SyncBatchRecord(
          batchId: event.batchId,
          events: [event],
          manifest: SyncBatchManifest(
            batchId: event.batchId,
            operationIds: [event.operationId],
            blobHashes: const [],
            manifestHash: 'manifest-hash',
          ),
        ),
      );
      transport.files['verifin-sync/v1/batches/dev-collision/'
          'batch-collision.manifest'] = syncJsonBytes({
        'protocolVersion': syncProtocolVersion,
        'batchId': 'different-batch',
      });
      Object? phaseError;

      final result = await engine.run(
        trigger: SyncTrigger.manual,
        onPhase: (phase, state, error) {
          if (phase == SyncPhase.upload && state == SyncPhaseState.error) {
            phaseError = error;
          }
        },
      );

      expect(result.errorCode, 'protocol');
      expect(phaseError, isA<WebdavFileCollision>());
      expect(
        (phaseError! as WebdavFileCollision).safeLogDetails,
        'method=GET operation=inspect_existing file=manifest status=200 '
        'redirects=0 redirect=none reason=file_collision',
      );
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

    test(
      'later invalid batch preserves earlier download and pending counts',
      () async {
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
        final clock = SyncClock.createWithDeviceId('dev-partial-download');
        final valid = SyncEvent(
          protocolVersion: syncProtocolVersion,
          operationId: clock.nextOperationId(),
          version: clock.nextVersion(),
          entity: const SyncEntityKey(
            scope: 'global',
            type: 'hapticsEnabled',
            id: 'singleton',
          ),
          operation: SyncOperationKind.upsert,
          payloadHash: computeSyncPayloadHash(false),
          payload: false,
          batchId: 'batch-valid',
          keyFingerprint: 'test-key',
        );
        final invalidPayload = <String, Object?>{
          'nickname': 42,
          'bio': '',
          'avatarDataUrl': '',
        };
        final invalid = SyncEvent(
          protocolVersion: syncProtocolVersion,
          operationId: clock.nextOperationId(),
          version: clock.nextVersion(),
          entity: const SyncEntityKey(
            scope: 'global',
            type: 'profile',
            id: 'singleton',
          ),
          operation: SyncOperationKind.upsert,
          payloadHash: computeSyncPayloadHash(invalidPayload),
          payload: invalidPayload,
          batchId: 'batch-invalid',
          keyFingerprint: 'test-key',
        );
        await transport.simulateRemoteBatch('dev-partial-download', 1, [valid]);
        await transport.simulateRemoteBatch('dev-partial-download', 2, [
          invalid,
        ]);

        final result = await engine.run(trigger: SyncTrigger.manual);

        expect(result.downloaded, 1);
        expect(result.pending, 1);
        expect(result.errorCode, 'validation');
        expect(controller.hapticsEnabled, isFalse);
      },
    );

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

class _FailDownloadListingTransport extends StubWebdavSyncTransport {
  @override
  Future<List<WebdavSyncFile>> listSyncFiles(WebdavConfig config) {
    if (files.keys.any((path) => path.endsWith('.commit'))) {
      throw const WebdavException(
        'download listing failed',
        diagnostic: WebdavDiagnostic(
          method: 'PROPFIND',
          operation: 'list_remote',
          fileKind: 'event',
          statusCode: 503,
          reason: 'http_status',
        ),
      );
    }
    return super.listSyncFiles(config);
  }
}

class _FailSpecificCommitTransport extends StubWebdavSyncTransport {
  _FailSpecificCommitTransport(this.batchId);

  final String batchId;

  @override
  Future<void> putImmutable(
    WebdavConfig config,
    String relativePath,
    Stream<List<int>> bytes,
    int length,
    String expectedHash,
  ) {
    if (relativePath.endsWith('/$batchId.commit')) {
      throw const WebdavException(
        'commit upload failed',
        diagnostic: WebdavDiagnostic(
          method: 'PUT',
          operation: 'upload',
          fileKind: 'commit',
          statusCode: 503,
          reason: 'http_status',
        ),
      );
    }
    return super.putImmutable(
      config,
      relativePath,
      bytes,
      length,
      expectedHash,
    );
  }
}

SyncEvent _profileEvent(SyncClock clock, String batchId, String entityId) {
  final payload = <String, Object?>{
    'nickname': entityId,
    'bio': '',
    'avatarDataUrl': '',
  };
  return SyncEvent(
    protocolVersion: syncProtocolVersion,
    operationId: clock.nextOperationId(),
    version: clock.nextVersion(),
    entity: SyncEntityKey(scope: 'global', type: 'profile', id: entityId),
    operation: SyncOperationKind.upsert,
    payloadHash: computeSyncPayloadHash(payload),
    payload: payload,
    batchId: batchId,
    keyFingerprint: 'test-key',
  );
}

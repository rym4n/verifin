import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:verifin/app/backup/webdav_config.dart';
import 'package:verifin/app/logging/app_logger.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/sync/sync_change_tracker.dart';
import 'package:verifin/app/sync/sync_engine.dart';
import 'package:verifin/app/sync/sync_codec.dart';
import 'package:verifin/app/sync/sync_clock.dart';
import 'package:verifin/app/sync/sync_models.dart';
import 'package:verifin/app/sync/webdav_sync_transport_stub.dart';
import 'package:verifin/app/sync/webdav_sync_transport.dart';
import 'package:verifin/app/sync/webdav_snapshot_transport.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/data/app_database.dart';
import 'package:verifin/data/ledger_repository.dart';
import 'package:verifin/local_storage/local_storage.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test(
    'software logs correlate every synchronization stage with one run ID',
    () async {
      final db = await AppDatabase.open(
        factory: databaseFactoryFfi,
        path: inMemoryDatabasePath,
      );
      final repo = SqliteLedgerRepository(db);
      final store = LocalKeyValueStore();
      final logger = AppLogger(store);
      final controller = await VeriFinController.create(
        store,
        repository: repo,
        logger: logger,
      );
      addTearDown(() async {
        controller.dispose();
        logger.dispose();
        await db.close();
      });
      controller.setWebdavConfig(
        const WebdavConfig(
          url: 'https://dav.example.com/private/user?token=url-secret',
          username: 'sync-user-secret',
          password: 'sync-password-secret',
        ),
      );
      final runtime = await controller.createSyncRuntime(
        transport: StubWebdavSyncTransport(),
      );

      final result = await runtime.run(SyncTrigger.manual);
      final scan = await repo.sync.loadScanState();
      expect(scan.lastSuccess, isNotNull);
      expect(scan.lastErrorCode, isNull);
      expect(scan.retryCount, 0);

      final messages = logger.records.reversed
          .where((record) => record.source == 'sync')
          .map((record) => record.message)
          .toList(growable: false);
      final start = messages.firstWhere(
        (message) => message.startsWith('同步开始'),
      );
      final match = RegExp(r'run=([A-F0-9]{6})\b').firstMatch(start);
      expect(match, isNotNull);
      final runId = match!.group(1)!;
      expect(start, contains('trigger=manual'));
      expect(
        messages,
        containsAll(<String>[
          '同步阶段 run=$runId phase=prepare state=start',
          '同步阶段 run=$runId phase=prepare state=success',
          '同步阶段 run=$runId phase=initialize state=start',
          '同步阶段 run=$runId phase=initialize state=success',
          '同步阶段 run=$runId phase=reconcile state=start',
          '同步阶段 run=$runId phase=reconcile state=success',
          '同步阶段 run=$runId phase=ensure_remote state=start',
          '同步阶段 run=$runId phase=ensure_remote state=success',
          '同步阶段 run=$runId phase=download state=start',
          '同步阶段 run=$runId phase=download state=success',
          '同步阶段 run=$runId phase=upload state=start',
          '同步阶段 run=$runId phase=upload state=success',
        ]),
      );
      expect(
        messages.last,
        '同步结束 run=$runId uploaded=${result.uploaded} '
        'downloaded=${result.downloaded} conflicts=${result.conflicts} '
        'pending=${result.pending} errorCode=none',
      );
      expect(
        messages.where((message) => message.contains('run=')),
        everyElement(contains('run=$runId')),
      );
      final exported = logger.exportText();
      expect(exported, isNot(contains('dav.example.com')));
      expect(exported, isNot(contains('private/user')));
      expect(exported, isNot(contains('url-secret')));
      expect(exported, isNot(contains('sync-user-secret')));
      expect(exported, isNot(contains('sync-password-secret')));
    },
  );

  test(
    'software logs expose only redacted WebDAV failure diagnostics',
    () async {
      final db = await AppDatabase.open(
        factory: databaseFactoryFfi,
        path: inMemoryDatabasePath,
      );
      final repo = SqliteLedgerRepository(db);
      final store = LocalKeyValueStore();
      final logger = AppLogger(store);
      final controller = await VeriFinController.create(
        store,
        repository: repo,
        logger: logger,
      );
      addTearDown(() async {
        controller.dispose();
        logger.dispose();
        await db.close();
      });
      controller.setWebdavConfig(
        const WebdavConfig(
          url: 'https://dav.example.com/private/path?token=config-secret',
          username: 'private-user',
          password: 'private-password',
        ),
      );
      final runtime = await controller.createSyncRuntime(
        transport: _DiagnosticFailureTransport(),
      );

      final result = await runtime.run(SyncTrigger.manual);

      expect(result.errorCode, 'network');
      final messages = logger.records.reversed
          .where((record) => record.source == 'sync')
          .map((record) => record.message)
          .toList(growable: false);
      final start = messages.firstWhere(
        (message) => message.startsWith('同步开始'),
      );
      final runId = RegExp(r'run=([A-F0-9]{6})\b').firstMatch(start)!.group(1)!;
      expect(
        messages,
        contains(
          '同步阶段 run=$runId phase=ensure_remote state=error '
          'errorCode=network',
        ),
      );
      expect(
        messages,
        contains(
          'WebDAV失败 run=$runId phase=ensure_remote method=GET '
          'operation=download file=manifest status=302 redirects=0 '
          'redirect=downgrade reason=redirect_downgrade',
        ),
      );
      expect(
        messages.last,
        '同步结束 run=$runId uploaded=0 downloaded=0 conflicts=0 '
        'pending=0 errorCode=network',
      );
      final exported = logger.exportText();
      for (final secret in <String>[
        'dav.example.com',
        'private/path',
        'config-secret',
        'private-user',
        'private-password',
        'Authorization',
        'ledger-body',
      ]) {
        expect(exported, isNot(contains(secret)));
      }
    },
  );

  test(
    'failure to persist error state does not drop the final sync log',
    () async {
      final db = await AppDatabase.open(
        factory: databaseFactoryFfi,
        path: inMemoryDatabasePath,
      );
      final repo = SqliteLedgerRepository(db);
      final store = LocalKeyValueStore();
      final logger = AppLogger(store);
      final controller = await VeriFinController.create(
        store,
        repository: repo,
        logger: logger,
      );
      addTearDown(() async {
        controller.dispose();
        logger.dispose();
        await db.close();
      });
      controller.setWebdavConfig(
        const WebdavConfig(
          url: 'https://dav.example.com',
          username: 'user',
          password: 'password',
        ),
      );
      final runtime = await controller.createSyncRuntime(
        transport: _DiagnosticFailureTransport(),
      );
      await db.db.execute('''
      CREATE TRIGGER fail_sync_scan_state_insert
      BEFORE INSERT ON sync_scan_state
      BEGIN
        SELECT RAISE(ABORT, 'scan state write blocked');
      END
    ''');
      await db.db.execute('''
      CREATE TRIGGER fail_sync_scan_state_update
      BEFORE UPDATE ON sync_scan_state
      BEGIN
        SELECT RAISE(ABORT, 'scan state write blocked');
      END
    ''');

      final result = await runtime.run(SyncTrigger.manual);

      expect(result.errorCode, 'network');
      final messages = logger.records.reversed
          .where((record) => record.source == 'sync')
          .map((record) => record.message)
          .toList(growable: false);
      final runId = RegExp(
        r'run=([A-F0-9]{6})\b',
      ).firstMatch(messages.first)!.group(1)!;
      expect(messages, contains('同步状态记录失败 run=$runId errorCode=persist'));
      expect(
        messages.last,
        '同步结束 run=$runId uploaded=0 downloaded=0 conflicts=0 '
        'pending=0 errorCode=network',
      );
    },
  );

  test(
    'manual synchronization uses one runtime and baseline uploads complete events only once',
    () async {
      final db = await AppDatabase.open(
        factory: databaseFactoryFfi,
        path: inMemoryDatabasePath,
      );
      final repo = SqliteLedgerRepository(db);
      final controller = await VeriFinController.create(
        LocalKeyValueStore(),
        repository: repo,
      );
      addTearDown(() async {
        controller.dispose();
        await db.close();
      });
      controller.setWebdavConfig(
        const WebdavConfig(
          url: 'https://example.com',
          username: 'u',
          password: 'p',
        ),
      );
      final transport = StubWebdavSyncTransport();
      final runtime = await controller.createSyncRuntime(transport: transport);
      expect(
        await controller.createSyncRuntime(transport: transport),
        same(runtime),
      );
      final result = await controller.runManualSync();
      expect(result!.errorCode, isNull);
      expect(result.uploaded, 1);
      for (final file in transport.files.entries.where(
        (f) => f.key.endsWith('.vfsync'),
      )) {
        expect(
          () => SyncEvent.fromJson(
            Map<String, Object?>.from(
              jsonDecode(utf8.decode(file.value)) as Map,
            ),
          ),
          returnsNormally,
        );
      }
      final fileCount = transport.files.length;
      expect((await controller.runManualSync())!.errorCode, isNull);
      expect(transport.files.length, fileCount);
      expect(await repo.sync.loadOutbox(), isEmpty);
    },
  );

  test('a hung transport cannot wedge later synchronization runs', () async {
    final db = await AppDatabase.open(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    final repo = SqliteLedgerRepository(db);
    final store = LocalKeyValueStore();
    final logger = AppLogger(store);
    final controller = await VeriFinController.create(
      store,
      repository: repo,
      logger: logger,
    );
    addTearDown(() async {
      controller.dispose();
      logger.dispose();
      await db.close();
    });
    controller.setWebdavConfig(
      const WebdavConfig(
        url: 'https://dav.example.com',
        username: 'user',
        password: 'password',
      ),
    );
    final runtime = await controller.createSyncRuntime(
      transport: _HangingTransport(),
      runTimeout: const Duration(milliseconds: 200),
    );

    final first = await runtime
        .run(SyncTrigger.startup)
        .timeout(const Duration(seconds: 3));
    expect(first.errorCode, 'timeout');

    // 真正的回归点：run 之间串行在 `_operationTail` 上，一次挂死的运行如果不
    // 释放队列，此后每一次同步（含用户手动点的「立即同步」）都会永远排队。
    final second = await runtime
        .run(SyncTrigger.manual)
        .timeout(const Duration(seconds: 3));
    expect(second.errorCode, 'timeout');

    // 状态必须被刷新，否则界面会一直停在上一次运行遗留的陈旧错误上。
    final scan = await repo.sync.loadScanState();
    expect(scan.lastErrorCode, 'timeout');

    final messages = logger.records.reversed
        .where((record) => record.source == 'sync')
        .map((record) => record.message)
        .toList(growable: false);
    expect(
      messages.where((m) => m.startsWith('同步结束')),
      hasLength(2),
      reason: '挂死的运行也必须留下收尾日志，否则日志只剩一个无结尾的阶段',
    );
  });

  test('AES-GCM envelope authenticates and round trips payload', () async {
    final clock = SyncClock.createWithDeviceId('codec');
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
      payloadHash: computeSyncPayloadHash({'name': 'private'}),
      payload: {'name': 'private'},
      batchId: 'batch',
      keyFingerprint: 'none',
    );
    const codec = SyncCodec(passphrase: 'secret');
    final encoded = await codec.encode(event, syncProtocolVersion);
    expect(await codec.decode(encoded), event.payload);
    encoded['mac'] = 'AAAAAAAAAAAAAAAAAAAAAA==';
    await expectLater(
      codec.decode(encoded),
      throwsA(isA<SyncCodecException>()),
    );
  });

  test(
    'restarted encrypted engine uploads a complete event readable by another SQLite Controller',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'verifin-sync-two-device-',
      );
      final firstDb = await AppDatabase.open(
        factory: databaseFactoryFfi,
        path: '${directory.path}/a.db',
      );
      final secondDb = await AppDatabase.open(
        factory: databaseFactoryFfi,
        path: '${directory.path}/b.db',
      );
      final firstRepo = SqliteLedgerRepository(firstDb);
      final secondRepo = SqliteLedgerRepository(secondDb);
      final source = await VeriFinController.create(
        LocalKeyValueStore(),
        repository: firstRepo,
      );
      final target = await VeriFinController.create(
        LocalKeyValueStore(),
        repository: secondRepo,
      );
      addTearDown(() async {
        source.dispose();
        target.dispose();
        await firstDb.close();
        await secondDb.close();
        directory.deleteSync(recursive: true);
      });
      const config = WebdavConfig(
        url: 'https://example.com',
        username: 'u',
        password: 'p',
      );
      final clock = SyncClock.createWithDeviceId('sender');
      final entry = LedgerEntry(
        id: 'encrypted-entry',
        bookId: defaultLedgerBookId,
        type: EntryType.expense,
        amount: 19,
        categoryId: 'dining',
        accountId: '',
        note: 'private-note',
        occurredAt: DateTime(2026, 9, 16),
      );
      final event = SyncEvent(
        protocolVersion: syncProtocolVersion,
        operationId: clock.nextOperationId(),
        version: clock.nextVersion(),
        entity: const SyncEntityKey(
          scope: 'ledger',
          type: 'entries',
          id: 'encrypted-entry',
        ),
        operation: SyncOperationKind.upsert,
        payloadHash: computeSyncPayloadHash(entry.toJson()),
        payload: entry.toJson(),
        batchId: 'persisted-batch',
        keyFingerprint: 'none',
      );
      await firstRepo.sync.enqueueBatch(
        SyncBatchRecord(
          batchId: event.batchId,
          events: [event],
          manifest: SyncBatchManifest(
            batchId: event.batchId,
            operationIds: [event.operationId],
            blobHashes: const [],
            manifestHash: 'test',
          ),
        ),
      );
      final transport = StubWebdavSyncTransport()..failCommitUploads = true;
      final restarted = SyncEngine(
        repository: firstRepo.sync,
        controller: source,
        transport: transport,
        config: config,
        passphrase: 'secret',
      );
      expect(
        (await restarted.run(trigger: SyncTrigger.manual)).errorCode,
        isNotNull,
      );
      transport.failCommitUploads = false;
      expect(
        (await restarted.run(trigger: SyncTrigger.manual)).errorCode,
        isNull,
      );
      final paths = transport.files.keys.toList();
      expect(paths.every((p) => p.contains('/sender/')), isTrue);
      final bytes = transport.files.entries
          .firstWhere((f) => f.key.endsWith('.vfsync'))
          .value;
      expect(utf8.decode(bytes), isNot(contains('private-note')));
      final wrong = SyncEngine(
        repository: secondRepo.sync,
        controller: target,
        transport: transport,
        config: config,
        passphrase: 'wrong',
      );
      expect((await wrong.run(trigger: SyncTrigger.manual)).errorCode, 'auth');
      expect(await secondRepo.loadEntries(), isEmpty);
      final receiver = SyncEngine(
        repository: secondRepo.sync,
        controller: target,
        transport: transport,
        config: config,
        passphrase: 'secret',
      );
      expect(
        (await receiver.run(trigger: SyncTrigger.manual)).errorCode,
        isNull,
      );
      expect((await secondRepo.loadEntries()).single.note, 'private-note');
      expect((target.exportDataForSync()['entries'] as List), hasLength(1));
    },
  );

  test(
    'fresh tracker and clock reserve a higher sequence after reopening durable state',
    () async {
      final db = await AppDatabase.open(
        factory: databaseFactoryFfi,
        path: inMemoryDatabasePath,
      );
      final repo = SqliteLedgerRepository(db);
      final store = LocalKeyValueStore();
      final controller = await VeriFinController.create(
        store,
        repository: repo,
      );
      addTearDown(() async {
        controller.dispose();
        await db.close();
      });
      final clock = SyncClock.createWithDeviceId('stable');
      final first = SyncChangeTracker(
        controller: controller,
        repository: repo.sync,
        clock: clock,
      );
      await first.reconcile(alignShadowOnly: true);
      controller.setThemePreference(ThemePreference.dark);
      await first.reconcile();
      final before =
          (await repo.sync.loadOutbox()).single.event!.version.dot.sequence;
      first.dispose();
      final second = SyncChangeTracker(
        controller: controller,
        repository: repo.sync,
        clock: SyncClock.createWithDeviceId('stable'),
      );
      controller.setHapticsEnabled(false);
      await second.reconcile();
      final sequences = (await repo.sync.loadOutbox())
          .map((r) => r.event!.version.dot.sequence)
          .toSet();
      expect(sequences, contains(before + 1));
      expect(sequences, hasLength(2));
      second.dispose();
    },
  );
}

/// 传输层对一个永不完成的请求的最小复现：服务器收下请求后既不回数据也不断开。
class _HangingTransport extends StubWebdavSyncTransport {
  final Completer<WebdavRootListing> _never = Completer<WebdavRootListing>();

  @override
  Future<WebdavRootListing> listRoot(WebdavConfig config) => _never.future;
}

class _DiagnosticFailureTransport extends StubWebdavSyncTransport {
  @override
  Future<WebdavRootListing> listRoot(WebdavConfig config) {
    throw const WebdavException(
      'https://private-user:private-password@dav.example.com/private/path '
      'Authorization ledger-body',
      diagnostic: WebdavDiagnostic(
        method: 'GET',
        operation: 'download',
        fileKind: 'manifest',
        statusCode: 302,
        redirectCount: 0,
        redirectRelation: 'downgrade',
        reason: 'redirect_downgrade',
      ),
    );
  }

  @override
  Future<List<WebdavSyncFile>> listSyncFiles(WebdavConfig config) {
    throw const WebdavException(
      'https://private-user:private-password@dav.example.com/private/path '
      'Authorization ledger-body',
      diagnostic: WebdavDiagnostic(
        method: 'GET',
        operation: 'download',
        fileKind: 'manifest',
        statusCode: 302,
        redirectCount: 0,
        redirectRelation: 'downgrade',
        reason: 'redirect_downgrade',
      ),
    );
  }
}

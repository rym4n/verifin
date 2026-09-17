import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:verifin/app/backup/webdav_config.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/sync/sync_change_tracker.dart';
import 'package:verifin/app/sync/sync_engine.dart';
import 'package:verifin/app/sync/sync_codec.dart';
import 'package:verifin/app/sync/sync_clock.dart';
import 'package:verifin/app/sync/sync_models.dart';
import 'package:verifin/app/sync/webdav_sync_transport_stub.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/data/app_database.dart';
import 'package:verifin/data/ledger_repository.dart';
import 'package:verifin/local_storage/local_storage.dart';

void main() {
  setUpAll(sqfliteFfiInit);
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

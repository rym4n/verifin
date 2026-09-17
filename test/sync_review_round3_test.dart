import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/sync/sync_codec.dart';
import 'package:verifin/app/sync/sync_conflict.dart';
import 'package:verifin/app/sync/sync_engine.dart';
import 'package:verifin/app/sync/sync_models.dart';
import 'package:verifin/app/sync/sync_wire.dart';
import 'package:verifin/app/sync/webdav_sync_transport_stub.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/data/app_database.dart';
import 'package:verifin/data/ledger_repository.dart';
import 'package:verifin/local_storage/local_storage.dart';
import 'support/sync_test_harness.dart';

class FailedJournalStore extends LocalKeyValueStore {
  bool fail = false;
  @override
  Future<void> writeAndFlush(String key, String value) async {
    if (fail && (key == 'verifin.theme.v1' || key == 'verifin.haptics.v1')) {
      throw StateError('injected KV failure');
    }
    await super.writeAndFlush(key, value);
  }
}

void main() {
  setUpAll(sqfliteFfiInit);
  late StubWebdavSyncTransport transport;
  late SyncTestDevice device;
  setUp(() async {
    transport = StubWebdavSyncTransport();
    device = await SyncTestDevice.create(
      deviceId: 'local',
      transport: transport,
    );
  });
  tearDown(() => device.dispose());
  SyncEvent event(
    SyncTestRemote remote,
    String type,
    String id,
    Object? payload, {
    String batch = 'batch',
  }) => SyncEvent(
    protocolVersion: syncProtocolVersion,
    operationId: remote.clock.nextOperationId(),
    version: remote.clock.nextVersion(),
    entity: SyncEntityKey(
      scope: ['profile', 'themePreference', 'hapticsEnabled'].contains(type)
          ? 'global'
          : 'ledger',
      type: type,
      id: id,
    ),
    operation: SyncOperationKind.upsert,
    payloadHash: computeSyncPayloadHash(payload),
    payload: payload,
    batchId: batch,
    keyFingerprint: 'none',
  );

  test(
    'R3-1 prepared multi-key choices survive reopening without replacing prepared plan',
    () async {
      final store = FailedJournalStore();
      final controller = await VeriFinController.create(
        store,
        repository: device.repository,
      );
      final engine = SyncEngine(
        repository: device.repository.sync,
        controller: controller,
        transport: transport,
        config: syncTestConfig,
      );
      final remote = SyncTestRemote('remote');
      final events = [
        event(remote, 'themePreference', 'singleton', 'dark'),
        event(remote, 'hapticsEnabled', 'singleton', false),
      ];
      final shadow = await device.repository.sync.loadShadow();
      for (final e in events) {
        shadow.remove(e.entity);
      }
      await device.repository.sync.saveShadow(shadow);
      await transport.simulateRemoteBatch('remote', 1, events);
      store.fail = true;
      expect(
        (await engine.run(trigger: SyncTrigger.manual)).errorCode,
        isNotNull,
      );
      store.fail = false;
      controller.setThemePreference(ThemePreference.light);
      controller.setHapticsEnabled(false);
      controller.setHapticsEnabled(true);
      await controller.flushPendingWrites();
      await expectLater(
        controller.applySyncPreferenceJournal(),
        throwsA(isA<Exception>()),
      );
      final conflicts = await device.repository.sync.loadConflicts();
      expect(conflicts, hasLength(2));
      final before = await device.repository.sync.loadOutbox();
      await engine.resolveConflict(
        conflicts.first.id,
        ConflictResolution.keepLocal,
      );
      expect(
        await device.repository.sync.loadOutbox(),
        hasLength(before.length),
      );
      controller.dispose();
      await device.db.close();
      final reopened = await AppDatabase.open(
        factory: databaseFactoryFfi,
        path: '${device.directory.path}/ledger.db',
      );
      addTearDown(reopened.close);
      final repo = SqliteLedgerRepository(reopened);
      expect(
        (await repo.sync.loadPendingBatches()).single.choices,
        hasLength(1),
      );
      final reloaded = await VeriFinController.create(store, repository: repo);
      addTearDown(reloaded.dispose);
      final resumed = SyncEngine(
        repository: repo.sync,
        controller: reloaded,
        transport: transport,
        config: syncTestConfig,
      );
      await resumed.resolveConflict(
        conflicts.last.id,
        ConflictResolution.keepLocal,
      );
      expect(await repo.sync.loadPendingBatches(), isEmpty);
      expect(await repo.sync.loadPendingKvJournal(), isEmpty);
      expect(await repo.sync.loadConflicts(), isEmpty);
      expect(reloaded.themePreference, ThemePreference.light);
      expect(reloaded.hapticsEnabled, isTrue);
    },
  );

  test(
    'R3-2 old inline event uploaded before crash resumes without rewriting immutable bytes',
    () async {
      await device.addExpense('legacy', 10);
      device.controller.addAttachment('legacy', 'data:image/png;base64,AQID');
      await device.controller.waitForPendingWrites();
      await device.tracker!.reconcile();
      final queued = await device.repository.sync.loadOutbox();
      final attachment = queued.singleWhere(
        (r) => r.event?.entity.type == 'attachments',
      );
      final path = 'verifin-sync/v1/${attachment.relativePath}';
      final inline = syncJsonBytes(attachment.event!.toJson());
      transport.files[path] = inline;
      expect(
        (await device.engine.run(trigger: SyncTrigger.manual)).errorCode,
        isNull,
      );
      expect(transport.files[path], inline);
      expect(await device.repository.sync.loadOutbox(), isEmpty);
    },
  );

  test(
    'R3-2 legacy 9 MiB inline event uses whole-blob manifest semantics',
    () async {
      final remote = SyncTestRemote('remote');
      final bytes = Uint8List(9 * 1024 * 1024);
      final hash = sha256.convert(bytes).toString();
      final expense = remote.expense(
        'legacy-large',
        10,
        batchId: 'legacy-large',
      );
      final attachment = event(remote, 'attachments', 'legacy-attachment', {
        'id': 'legacy-attachment',
        'entryId': 'legacy-large',
        'dataUrl': 'data:image/png;base64,${base64Encode(bytes)}',
      }, batch: 'legacy-large');
      final events = [expense, attachment];
      for (final e in events) {
        final sequence = e.version.dot.sequence.toString().padLeft(20, '0');
        transport.files['verifin-sync/v1/events/remote/'
            '$sequence-${e.operationId}.vfsync'] = syncJsonBytes(
          e.toJson(),
        );
      }
      final body = {
        'batchId': 'legacy-large',
        'operationIds': events.map((e) => e.operationId).toList()..sort(),
        'blobHashes': [hash],
        'payloadHashes': {for (final e in events) e.operationId: e.payloadHash},
      };
      final manifest = {
        'protocolVersion': syncProtocolVersion,
        ...body,
        'manifestHash': computeSyncPayloadHash(body),
      };
      final manifestBytes = syncJsonBytes(manifest);
      transport.files['verifin-sync/v1/batches/remote/legacy-large.manifest'] =
          manifestBytes;
      transport.files['verifin-sync/v1/batches/remote/legacy-large.commit'] =
          syncJsonBytes(syncCommit(manifest, manifestBytes));
      transport.files['verifin-sync/v1/blobs/$hash.blob'] = syncJsonBytes({
        'protocolVersion': syncProtocolVersion,
        'hash': hash,
        'data': base64Encode(bytes),
      });
      expect(
        (await device.engine.run(trigger: SyncTrigger.manual)).errorCode,
        isNull,
      );
      expect(
        (await device.repository.loadAttachments()).single.id,
        'legacy-attachment',
      );
    },
  );

  test(
    'R3-3 incomplete join remains enrolling until final C arrives',
    () async {
      final joining = await SyncTestDevice.create(
        deviceId: 'join',
        transport: transport,
        trackLocalChanges: false,
      );
      addTearDown(joining.dispose);
      final remote = SyncTestRemote('remote');
      final a = remote.expense('same', 10, batchId: 'a'),
          b = remote.expense('same', 20, batchId: 'b'),
          c = remote.expense('same', 30, batchId: 'c');
      joining.controller.addEntry(
        LedgerEntry.fromJson(Map<String, Object?>.from(c.payload as Map)),
      );
      await joining.controller.waitForPendingWrites();
      await transport.simulateRemoteBatch('remote', 1, [a]);
      await transport.simulateRemoteBatch('remote', 2, [b]);
      await transport.simulateRemoteBatch('remote', 3, [
        c,
      ], includeCommit: false);
      await joining.engine.initializeFromRestoredData();
      expect(await joining.repository.sync.loadEnrollmentState(), 'enrolling');
      expect(await joining.engine.conflicts(), isEmpty);
      await transport.simulateRemoteBatch('remote', 3, [c]);
      final fresh = SyncEngine(
        repository: joining.repository.sync,
        controller: joining.controller,
        transport: transport,
        config: syncTestConfig,
        clock: joining.clock,
      );
      await fresh.initializeFromRestoredData();
      expect(await joining.repository.sync.loadEnrollmentState(), 'enrolled');
      expect(await fresh.conflicts(), isEmpty);
      expect(joining.entries.single.amount, 30);
    },
  );

  test(
    'R3-4 invalid profile is rejected before KV or applied changes',
    () async {
      final remote = SyncTestRemote('remote');
      final e = event(remote, 'profile', 'singleton', {'nickname': 37});
      final shadow = await device.repository.sync.loadShadow();
      shadow.remove(e.entity);
      await device.repository.sync.saveShadow(shadow);
      final before = device.controller.exportDataForSync()['profile'];
      await transport.simulateRemoteBatch('remote', 1, [e]);
      expect(
        (await device.engine.run(trigger: SyncTrigger.manual)).errorCode,
        'validation',
      );
      expect(device.controller.exportDataForSync()['profile'], before);
      expect(await device.db.db.query('sync_applied_ops'), isEmpty);
      expect(await device.repository.sync.loadPendingKvJournal(), isEmpty);
    },
  );
  for (final day in [5.9, 0, 32]) {
    test(
      'R3-4 invalid account day $day is not truncated or accepted',
      () async {
        final remote = SyncTestRemote('remote');
        final payload =
            Account(
                id: 'card',
                bookId: 'default',
                name: 'Card',
                type: AccountType.cash,
                groupId: null,
                initialBalance: 0,
                iconCode: 'cash',
                note: '',
                includeInAssets: true,
                hidden: false,
              ).toJson()
              ..['statementDay'] = day
              ..['dueDay'] = day;
        await transport.simulateRemoteBatch('remote', 1, [
          event(remote, 'accounts', 'card', payload),
        ]);
        expect(
          (await device.engine.run(trigger: SyncTrigger.manual)).errorCode,
          'validation',
        );
        expect(await device.repository.loadAccounts(), isEmpty);
        expect(await device.db.db.query('sync_applied_ops'), isEmpty);
      },
    );
  }

  test(
    'encrypted manifest authenticates the plaintext commit content and ciphertext binding',
    () async {
      await device.addExpense('authenticated', 10);
      device.engine.updatePassphrase('secret');
      expect(
        (await device.engine.run(trigger: SyncTrigger.manual)).errorCode,
        isNull,
      );
      final manifestPath = transport.files.keys.firstWhere(
        (p) => p.endsWith('.manifest'),
      );
      final commitPath = manifestPath.replaceFirst('.manifest', '.commit');
      final envelope = Map<String, Object?>.from(
        jsonDecode(utf8.decode(transport.files[manifestPath]!)) as Map,
      );
      expect(envelope['ciphertext'], isNotNull);
      final decoded = await const SyncCodec(
        passphrase: 'secret',
      ).decode(envelope);
      final expected = syncCommit(
        Map<String, Object?>.from(decoded as Map),
        transport.files[manifestPath]!,
      );
      expect(jsonDecode(utf8.decode(transport.files[commitPath]!)), expected);
      final tampered = {...expected, 'manifestHash': 'forged'};
      transport.files[commitPath] = syncJsonBytes(tampered);
      final receiver = await SyncTestDevice.create(
        deviceId: 'receiver',
        transport: transport,
        trackLocalChanges: false,
      );
      addTearDown(receiver.dispose);
      receiver.engine.updatePassphrase('secret');
      expect(
        (await receiver.engine.run(trigger: SyncTrigger.manual)).errorCode,
        'protocol',
      );
      expect(receiver.entries, isEmpty);
    },
  );
}

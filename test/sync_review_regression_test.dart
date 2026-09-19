import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:verifin/app/backup/webdav_config.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/sync/sync_engine.dart';
import 'package:verifin/app/sync/sync_models.dart';
import 'package:verifin/app/sync/sync_codec.dart';
import 'package:verifin/app/sync/sync_conflict.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/local_storage/local_storage.dart';
import 'package:verifin/app/sync/sync_change_tracker.dart';
import 'package:verifin/app/sync/sync_clock.dart';
import 'package:verifin/app/sync/webdav_sync_transport_stub.dart';
import 'support/sync_test_harness.dart';

class PausedDownload extends StubWebdavSyncTransport {
  Completer<void>? reached;
  Completer<void>? release;
  @override
  Future<Uint8List> downloadSyncFile(
    WebdavConfig config,
    String path, {
    required int maxBytes,
  }) async {
    if (reached != null && path.endsWith('.vfsync')) {
      final entered = reached!;
      reached = null;
      entered.complete();
      await release!.future;
    }
    return super.downloadSyncFile(config, path, maxBytes: maxBytes);
  }
}

class FailingPreferenceStore extends LocalKeyValueStore {
  bool failTheme = false;
  @override
  Future<void> writeAndFlush(String key, String value) async {
    if (failTheme && key == 'verifin.theme.v1') {
      throw StateError('injected KV failure');
    }
    await super.writeAndFlush(key, value);
  }
}

void main() {
  setUpAll(sqfliteFfiInit);
  late PausedDownload transport;
  late SyncTestDevice device;
  setUp(() async {
    transport = PausedDownload();
    device = await SyncTestDevice.create(
      deviceId: 'local',
      transport: transport,
    );
  });
  tearDown(() => device.dispose());

  test(
    'I4 same payload operations are acknowledged before the next local edit',
    () async {
      final a = SyncTestRemote('a');
      final b = SyncTestRemote('b');
      final first = a.expense('same-payload', 10, batchId: 'a');
      final same = b.expense('same-payload', 10, batchId: 'b');
      await transport.simulateRemoteBatch('a', 1, [first]);
      await device.engine.run(trigger: SyncTrigger.manual);
      await transport.simulateRemoteBatch('b', 1, [same]);
      expect(
        (await device.engine.run(trigger: SyncTrigger.manual)).conflicts,
        0,
      );
      expect(
        await device.repository.sync.loadAppliedOperationHashes([
          first.operationId,
          same.operationId,
        ]),
        hasLength(2),
      );
      await device.editExpense('same-payload', 20);
      final event = (await device.repository.sync.loadOutbox()).last.event!;
      expect(event.version.context.values['a'], 1);
      expect(event.version.context.values['b'], 1);
    },
  );

  SyncEvent entity(
    SyncTestRemote remote,
    String type,
    String id,
    Object? payload,
    String batch,
  ) => SyncEvent(
    protocolVersion: syncProtocolVersion,
    operationId: remote.clock.nextOperationId(),
    version: remote.clock.nextVersion(),
    entity: SyncEntityKey(
      scope: type == 'profile' ? 'global' : 'ledger',
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
    'C1 local addition during GET is captured before remote alignment',
    () async {
      final remote = SyncTestRemote('remote');
      await transport.simulateRemoteBatch('remote', 1, [
        remote.expense('remote-entry', 12, batchId: 'remote'),
      ]);
      final reached = transport.reached = Completer<void>();
      transport.release = Completer<void>();
      final run = device.engine.run(trigger: SyncTrigger.manual);
      await reached.future;
      device.controller.addEntry(
        LedgerEntry(
          id: 'local-during-get',
          bookId: 'default',
          type: EntryType.expense,
          amount: 7,
          categoryId: 'dining',
          accountId: '',
          note: '',
          occurredAt: DateTime(2026, 9, 16),
        ),
      );
      await device.controller.waitForPendingWrites();
      transport.release!.complete();
      expect((await run).errorCode, isNull);
      expect(
        (await device.repository.sync.loadOutbox()).any(
          (r) => r.event?.entity.id == 'local-during-get',
        ),
        isTrue,
      );
    },
  );

  test(
    'C2 one conflicted expense blocks the complete expense and attachment batch',
    () async {
      await device.addExpense('expense', 10);
      final remote = SyncTestRemote('remote');
      final expense = remote.expense('expense', 20, batchId: 'aggregate');
      final attachment = entity(remote, 'attachments', 'attachment', {
        'id': 'attachment',
        'entryId': 'expense',
        'dataUrl': 'data:image/png;base64,AQID',
      }, 'aggregate');
      await transport.simulateRemoteBatch('remote', 1, [expense, attachment]);
      await device.engine.run(trigger: SyncTrigger.manual);
      expect(await device.repository.loadAttachments(), isEmpty);
      expect(
        await device.db.db.query(
          'sync_applied_ops',
          where: 'batch_id = ?',
          whereArgs: ['aggregate'],
        ),
        isEmpty,
      );
      expect(await device.db.db.query('sync_pending'), isNotEmpty);
    },
  );

  test(
    'I4 unrelated remote entity does not make a causal successor conflict',
    () async {
      final a = SyncTestRemote('a');
      final b = SyncTestRemote('b');
      await transport.simulateRemoteBatch('a', 1, [
        a.expense('entry-a', 10, batchId: 'a1'),
      ]);
      await device.engine.run(trigger: SyncTrigger.manual);
      await transport.simulateRemoteBatch('b', 1, [
        b.expense('entry-b', 20, batchId: 'b1'),
      ]);
      await device.engine.run(trigger: SyncTrigger.manual);
      await transport.simulateRemoteBatch('a', 2, [
        a.expense('entry-a', 30, batchId: 'a2'),
      ]);
      final result = await device.engine.run(trigger: SyncTrigger.manual);
      expect(result.errorCode, isNull);
      expect(result.conflicts, 0);
      expect(device.entries.singleWhere((e) => e.id == 'entry-a').amount, 30);
    },
  );

  test(
    'I5 configured encryption rejects plaintext and unknown protocol',
    () async {
      final remote = SyncTestRemote('remote');
      await transport.simulateRemoteBatch('remote', 1, [
        remote.expense('plain', 1, batchId: 'plain'),
      ]);
      device.engine.updatePassphrase('secret');
      expect(
        (await device.engine.run(trigger: SyncTrigger.manual)).errorCode,
        'auth',
      );
      expect(device.entries, isEmpty);
    },
  );

  test('I5 codec rejects an envelope payload hash mismatch', () async {
    const codec = SyncCodec(passphrase: '');
    final value = await codec.encodeValue({
      'private': 'payload',
    }, syncProtocolVersion);
    value['payloadHash'] = 'bad';
    await expectLater(codec.decode(value), throwsA(isA<SyncCodecException>()));
  });

  test(
    'C1 same entity edited during GET becomes a conflict without losing its local event',
    () async {
      final remote = SyncTestRemote('remote');
      await transport.simulateRemoteBatch('remote', 1, [
        remote.expense('shared', 10, batchId: 'initial'),
      ]);
      await device.engine.run(trigger: SyncTrigger.manual);
      await transport.simulateRemoteBatch('remote', 2, [
        remote.expense('shared', 20, batchId: 'edit'),
      ]);
      final reached = transport.reached = Completer<void>();
      transport.release = Completer<void>();
      final run = device.engine.run(trigger: SyncTrigger.manual);
      await reached.future;
      device.controller.updateEntry(
        device.entries.single.copyWith(amount: 30, baseAmount: 30),
      );
      await device.controller.waitForPendingWrites();
      transport.release!.complete();
      final result = await run;
      expect(result.conflicts, 1);
      expect(device.entries.single.amount, 30);
      expect(
        (await device.repository.sync.loadOutbox()).any(
          (r) => r.event?.entity.id == 'shared',
        ),
        isTrue,
      );
    },
  );

  test(
    'C2 resolving conflict applies the entire retained attachment aggregate',
    () async {
      await device.addExpense('expense', 10);
      final remote = SyncTestRemote('remote');
      await transport.simulateRemoteBatch('remote', 1, [
        remote.expense('expense', 20, batchId: 'aggregate'),
        entity(remote, 'attachments', 'attach', {
          'id': 'attach',
          'entryId': 'expense',
          'dataUrl': 'data:image/png;base64,AQID',
        }, 'aggregate'),
      ]);
      await device.engine.run(trigger: SyncTrigger.manual);
      final conflict = (await device.engine.conflicts()).single;
      await device.engine.resolveConflict(
        conflict.id,
        ConflictResolution.keepRemote,
      );
      expect(device.entries.single.amount, 20);
      expect(await device.repository.loadAttachments(), hasLength(1));
      expect(await device.repository.sync.loadPendingBatches(), isEmpty);
      expect(await device.engine.conflicts(), isEmpty);
    },
  );

  test(
    'I3 missing blob defers complete batch and a corrupt blob fails hash validation',
    () async {
      final remote = SyncTestRemote('remote');
      await transport.simulateRemoteBatch('remote', 1, [
        remote.expense('expense', 20, batchId: 'blob'),
        entity(remote, 'attachments', 'attach', {
          'id': 'attach',
          'entryId': 'expense',
          'dataUrl': 'data:image/png;base64,AQID',
        }, 'blob'),
      ]);
      final blobPath = transport.files.keys.singleWhere(
        (p) => p.endsWith('.blob'),
      );
      final bytes = transport.files.remove(blobPath)!;
      final pending = await device.engine.run(trigger: SyncTrigger.manual);
      expect(pending.pending, 1);
      expect(device.entries, isEmpty);
      expect(await device.repository.sync.loadPendingBatches(), hasLength(1));
      final changed = jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;
      changed['data'] = 'BAUG';
      transport.files[blobPath] = Uint8List.fromList(
        utf8.encode(jsonEncode(changed)),
      );
      expect(
        (await device.engine.run(trigger: SyncTrigger.manual)).errorCode,
        isNotNull,
      );
      expect(device.entries, isEmpty);
      transport.files[blobPath] = bytes;
      expect(
        (await device.engine.run(trigger: SyncTrigger.manual)).errorCode,
        isNull,
      );
      expect(device.entries, hasLength(1));
      expect(await device.repository.sync.loadPendingBatches(), isEmpty);
    },
  );

  test(
    'I4 delete edit concurrency retains tombstone and does not resurrect history',
    () async {
      final remote = SyncTestRemote('remote');
      final first = remote.expense('deleted', 10, batchId: 'first');
      await transport.simulateRemoteBatch('remote', 1, [first]);
      await device.engine.run(trigger: SyncTrigger.manual);
      await device.deleteExpense('deleted');
      await transport.simulateRemoteBatch('remote', 2, [
        remote.expense('deleted', 20, batchId: 'edit'),
      ]);
      expect(
        (await device.engine.run(trigger: SyncTrigger.manual)).conflicts,
        1,
      );
      expect(device.entries, isEmpty);
      expect(
        (await device.repository.sync.loadConflicts()).single.local.deleted,
        isTrue,
      );
    },
  );

  test(
    'I3 attachment upload includes content-addressed encrypted blob and encrypted manifest',
    () async {
      await device.addExpense('attached', 8);
      device.controller.addAttachment(
        'attached',
        'data:image/png;base64,AQIDBA==',
      );
      device.controller.addAttachment(
        'attached',
        'data:image/png;base64,AQIDBA==',
      );
      await device.controller.waitForPendingWrites();
      await device.tracker!.reconcile();
      device.engine.updatePassphrase('secret');
      expect(
        (await device.engine.run(trigger: SyncTrigger.manual)).errorCode,
        isNull,
      );
      final blobs = transport.files.entries
          .where((e) => e.key.endsWith('.blob'))
          .toList();
      expect(blobs, hasLength(1));
      final decoded = jsonDecode(utf8.decode(blobs.single.value)) as Map;
      expect(decoded['ciphertext'], isNotNull);
      for (final manifest in transport.files.entries.where(
        (e) => e.key.endsWith('.manifest'),
      )) {
        expect(
          (jsonDecode(utf8.decode(manifest.value)) as Map)['ciphertext'],
          isNotNull,
        );
      }
    },
  );

  test(
    'I7 KV failure keeps a prepared batch unapplied until restart replay finalizes it',
    () async {
      final store = FailingPreferenceStore();
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
      final theme = SyncEvent(
        protocolVersion: syncProtocolVersion,
        operationId: remote.clock.nextOperationId(),
        version: remote.clock.nextVersion(),
        entity: const SyncEntityKey(
          scope: 'global',
          type: 'themePreference',
          id: 'singleton',
        ),
        operation: SyncOperationKind.upsert,
        payloadHash: computeSyncPayloadHash('dark'),
        payload: 'dark',
        batchId: 'prepared',
        keyFingerprint: 'none',
      );
      await transport.simulateRemoteBatch('remote', 1, [theme]);
      final shadow = await device.repository.sync.loadShadow();
      shadow.remove(theme.entity);
      await device.repository.sync.saveShadow(shadow);
      store.failTheme = true;
      expect(
        (await engine.run(trigger: SyncTrigger.manual)).errorCode,
        isNotNull,
      );
      expect(await device.db.db.query('sync_applied_ops'), isEmpty);
      expect(
        (await device.repository.sync.loadDeviceState())
            .knownVector
            .values['remote'],
        isNull,
      );
      expect(
        (await device.repository.sync.loadPendingBatches()).single.reason,
        'prepared',
      );
      controller.dispose();
      store.failTheme = false;
      final restarted = await VeriFinController.create(
        store,
        repository: device.repository,
      );
      addTearDown(restarted.dispose);
      expect(restarted.themePreference, ThemePreference.dark);
      expect(await device.db.db.query('sync_applied_ops'), hasLength(1));
      expect(await device.repository.sync.loadPendingBatches(), isEmpty);
      final tracker = SyncChangeTracker(
        controller: restarted,
        repository: device.repository.sync,
        clock: SyncClock.createWithDeviceId('local'),
      );
      await tracker.reconcile();
      expect(await device.repository.sync.loadOutbox(), isEmpty);
      tracker.dispose();
    },
  );

  test(
    'I6 incomplete commit is durable pending and not a successful scan',
    () async {
      final remote = SyncTestRemote('remote');
      await transport.simulateRemoteBatch('remote', 1, [
        remote.expense('pending', 1, batchId: 'pending'),
      ], includeCommit: false);
      final result = await device.engine.run(trigger: SyncTrigger.manual);
      expect(result.pending, 1);
      expect(await device.db.db.query('sync_pending'), hasLength(1));
      expect(
        (await device.repository.sync.loadScanState()).lastSuccess,
        isNull,
      );
    },
  );

  test(
    'I8 invalid conflict resolution leaves no outbox and keeps conflict',
    () async {
      final remote = SyncTestRemote('remote');
      final event = remote.expense('bad', 1, batchId: 'bad');
      final invalid = {
        ...event.payload as Map<String, Object?>,
        'categoryId': 'missing',
      };
      SyncEntityVersion version(String op, Object? payload) =>
          SyncEntityVersion(
            entity: event.entity,
            version: event.version,
            payloadHash: computeSyncPayloadHash(payload),
            payload: payload,
            deleted: false,
            operationId: op,
          );
      await device.repository.sync.storeConflict(
        SyncConflictRecord(
          id: 'invalid',
          entity: event.entity,
          local: version('left', event.payload),
          remote: version('right', invalid),
        ),
      );
      await expectLater(
        device.engine.resolveConflict('invalid', ConflictResolution.keepRemote),
        throwsA(anything),
      );
      expect(await device.repository.sync.loadOutbox(), isEmpty);
      expect(await device.repository.sync.loadConflicts(), hasLength(1));
    },
  );

  test(
    'I9 joining compares local data to final remote version rather than history',
    () async {
      final joining = await SyncTestDevice.create(
        deviceId: 'join',
        transport: transport,
        trackLocalChanges: false,
      );
      addTearDown(joining.dispose);
      final remote = SyncTestRemote('remote');
      final a = remote.expense('same', 10, batchId: 'a');
      final b = remote.expense('same', 20, batchId: 'b');
      final c = remote.expense('same', 30, batchId: 'c');
      joining.controller.addEntry(
        LedgerEntry.fromJson(Map<String, Object?>.from(c.payload as Map)),
      );
      await joining.controller.waitForPendingWrites();
      await transport.simulateRemoteBatch('remote', 3, [c]);
      await transport.simulateRemoteBatch('remote', 1, [a]);
      await transport.simulateRemoteBatch('remote', 2, [b]);
      await joining.engine.initializeFromRestoredData();
      expect(await joining.engine.conflicts(), isEmpty);
      expect(joining.entries.single.amount, 30);
    },
  );

  test(
    'I9 multi-batch join preserves source pending ids and creates only final-version conflicts',
    () async {
      final joining = await SyncTestDevice.create(
        deviceId: 'join-final',
        transport: transport,
        trackLocalChanges: false,
      );
      addTearDown(joining.dispose);
      joining.controller.addEntry(
        LedgerEntry(
          id: 'same',
          bookId: 'default',
          type: EntryType.expense,
          amount: 99,
          categoryId: 'dining',
          accountId: '',
          note: 'local',
          occurredAt: DateTime(2026, 9, 16),
        ),
      );
      await joining.controller.waitForPendingWrites();
      final remote = SyncTestRemote('remote');
      final a = remote.expense('same', 10, batchId: 'a');
      final b = remote.expense('same', 20, batchId: 'b');
      final c = remote.expense('same', 30, batchId: 'c');
      await transport.simulateRemoteBatch('remote', 3, [c]);
      await transport.simulateRemoteBatch('remote', 1, [a]);
      await transport.simulateRemoteBatch('remote', 2, [b]);
      await joining.engine.initializeFromRestoredData();
      final conflicts = await joining.repository.sync.loadConflicts();
      expect(conflicts, hasLength(1));
      expect((conflicts.single.remote.payload as Map)['amount'], 30);
      final pending = await joining.repository.sync.loadPendingBatches();
      expect(pending.map((p) => p.batchId), containsAll(['a', 'b', 'c']));
      await joining.engine.run(trigger: SyncTrigger.manual);
      expect(await joining.engine.conflicts(), hasLength(1));
      await joining.engine.resolveConflict(
        conflicts.single.id,
        ConflictResolution.keepRemote,
      );
      expect(joining.entries.single.amount, 30);
      expect(await joining.repository.sync.loadPendingBatches(), isEmpty);
      await joining.engine.run(trigger: SyncTrigger.manual);
      expect(await joining.engine.conflicts(), isEmpty);
    },
  );

  test(
    'C2 multiple choices remain prepared until the entire aggregate can commit',
    () async {
      await device.addExpense('one', 10);
      await device.addExpense('two', 10);
      final remote = SyncTestRemote('remote');
      await transport.simulateRemoteBatch('remote', 1, [
        remote.expense('one', 20, batchId: 'two-conflicts'),
        remote.expense('two', 30, batchId: 'two-conflicts'),
      ]);
      await device.engine.run(trigger: SyncTrigger.manual);
      final conflicts = await device.repository.sync.loadConflicts();
      expect(conflicts, hasLength(2));
      final before = await device.repository.sync.loadOutbox();
      await device.engine.resolveConflict(
        conflicts.first.id,
        ConflictResolution.keepRemote,
      );
      expect(device.entries.every((e) => e.amount == 10), isTrue);
      expect(
        await device.repository.sync.loadOutbox(),
        hasLength(before.length),
      );
      await device.engine.resolveConflict(
        conflicts.last.id,
        ConflictResolution.keepRemote,
      );
      expect(device.entries.map((e) => e.amount), containsAll([20, 30]));
      expect(await device.engine.conflicts(), isEmpty);
      expect(await device.repository.sync.loadPendingBatches(), isEmpty);
    },
  );
}

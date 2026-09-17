import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:verifin/app/sync/sync_engine.dart';
import 'package:verifin/app/sync/webdav_sync_transport_stub.dart';

import 'support/sync_test_harness.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  group('Sync integration · two production controllers', () {
    late StubWebdavSyncTransport transport;
    late SyncTestDevice a;
    late SyncTestDevice b;

    setUp(() async {
      transport = StubWebdavSyncTransport();
      a = await SyncTestDevice.create(
        deviceId: 'device-a',
        transport: transport,
      );
      b = await SyncTestDevice.create(
        deviceId: 'device-b',
        transport: transport,
      );
    });

    tearDown(() async {
      await a.dispose();
      await b.dispose();
    });

    test('offline additions converge to both typed entries', () async {
      await a.addExpense('entry-a', 50);
      await b.addExpense('entry-b', 75);

      expect(await a.repository.sync.loadOutbox(), isNotEmpty);
      expect(await b.repository.sync.loadOutbox(), isNotEmpty);
      final syncedA = await a.engine.run(trigger: SyncTrigger.manual);
      expect(syncedA.errorCode, isNull, reason: a.lastSyncError.toString());
      final syncedB = await b.engine.run(trigger: SyncTrigger.manual);
      expect(syncedB.errorCode, isNull, reason: b.lastSyncError.toString());
      expect(
        (await a.engine.run(trigger: SyncTrigger.manual)).errorCode,
        isNull,
      );

      expect(
        a.entries.map((entry) => entry.id),
        containsAll(['entry-a', 'entry-b']),
      );
      expect(
        b.entries.map((entry) => entry.id),
        containsAll(['entry-a', 'entry-b']),
      );
      expect(await a.repository.loadEntries(), hasLength(2));
      expect(await b.repository.loadEntries(), hasLength(2));
    });

    test('causal edit replaces the entry without a conflict', () async {
      await a.addExpense('causal-entry', 100);
      await a.engine.run(trigger: SyncTrigger.manual);
      await b.engine.run(trigger: SyncTrigger.manual);

      await a.editExpense('causal-entry', 150);
      await a.engine.run(trigger: SyncTrigger.manual);
      final result = await b.engine.run(trigger: SyncTrigger.manual);

      expect(result.errorCode, isNull);
      expect(result.conflicts, 0);
      expect(b.entries.single.amount, 150);
      expect(await b.engine.conflicts(), isEmpty);
    });

    test(
      'concurrent edits retain a conflict instead of silently overwriting',
      () async {
        await a.addExpense('concurrent-entry', 100);
        await a.engine.run(trigger: SyncTrigger.manual);
        await b.engine.run(trigger: SyncTrigger.manual);

        await a.editExpense('concurrent-entry', 200);
        await b.editExpense('concurrent-entry', 300);
        await a.engine.run(trigger: SyncTrigger.manual);
        await b.engine.run(trigger: SyncTrigger.manual);
        await a.engine.run(trigger: SyncTrigger.manual);

        final conflicts = [
          ...await a.engine.conflicts(),
          ...await b.engine.conflicts(),
        ];
        expect(conflicts, isNotEmpty);
        expect(
          conflicts.every(
            (conflict) => conflict.entity.id == 'concurrent-entry',
          ),
          isTrue,
        );
      },
    );

    test('concurrent delete and edit retain a conflict', () async {
      await a.addExpense('delete-edit-entry', 100);
      await a.engine.run(trigger: SyncTrigger.manual);
      await b.engine.run(trigger: SyncTrigger.manual);

      await a.deleteExpense('delete-edit-entry');
      await b.editExpense('delete-edit-entry', 200);
      await a.engine.run(trigger: SyncTrigger.manual);
      await b.engine.run(trigger: SyncTrigger.manual);
      await a.engine.run(trigger: SyncTrigger.manual);

      final conflicts = [
        ...await a.engine.conflicts(),
        ...await b.engine.conflicts(),
      ];
      expect(conflicts, isNotEmpty);
      expect(
        conflicts.any((conflict) => conflict.entity.id == 'delete-edit-entry'),
        isTrue,
      );
    });

    test(
      'replaying an already scanned remote event leaves one SQLite entry',
      () async {
        await a.addExpense('replay-entry', 100);
        await a.engine.run(trigger: SyncTrigger.manual);
        await b.engine.run(trigger: SyncTrigger.manual);

        final replay = await b.engine.run(trigger: SyncTrigger.manual);

        expect(replay.errorCode, isNull);
        expect(replay.downloaded, 0);
        expect(
          b.entries.where((entry) => entry.id == 'replay-entry'),
          hasLength(1),
        );
        expect(
          (await b.repository.loadEntries()).where(
            (entry) => entry.id == 'replay-entry',
          ),
          hasLength(1),
        );
      },
    );

    test('failed commit upload retains durable outbox before retry', () async {
      await a.addExpense('retry-entry', 25);
      final queued = await a.repository.sync.loadOutbox();
      expect(queued, isNotEmpty);
      expect(queued.every((record) => record.event != null), isTrue);

      transport.failCommitUploads = true;
      final failed = await a.engine.run(trigger: SyncTrigger.manual);
      expect(failed.errorCode, isNotNull);
      expect(await a.repository.sync.loadOutbox(), isNotEmpty);

      transport.failCommitUploads = false;
      final retried = await a.engine.run(trigger: SyncTrigger.manual);
      expect(retried.errorCode, isNull);
      expect(retried.uploaded, 1);
      expect(await a.repository.sync.loadOutbox(), isEmpty);
    });
  });
}

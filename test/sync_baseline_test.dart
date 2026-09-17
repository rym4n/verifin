import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/sync/sync_engine.dart';
import 'package:verifin/app/sync/webdav_sync_transport_stub.dart';

import 'support/sync_test_harness.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  group('SyncEngine · production baseline', () {
    late StubWebdavSyncTransport transport;
    late SyncTestDevice device;

    setUp(() async {
      transport = StubWebdavSyncTransport();
      device = await SyncTestDevice.create(
        deviceId: 'baseline-local',
        transport: transport,
        trackLocalChanges: false,
      );
    });

    tearDown(() => device.dispose());

    test(
      'empty remote uploads one complete baseline from real controller data',
      () async {
        await device.engine.initializeFromRestoredData();
        final outbox = await device.repository.sync.loadOutbox();
        expect(outbox, isNotEmpty);
        expect(outbox.every((record) => record.event != null), isTrue);
        expect(
          outbox.any((record) => record.event!.entity.type == 'ledgerBook'),
          isTrue,
        );
        expect(
          outbox.any((record) => record.event!.entity.type == 'categories'),
          isTrue,
        );

        final result = await device.engine.run(trigger: SyncTrigger.startup);
        expect(result.errorCode, isNull);
        expect(result.uploaded, 1);
        expect(await device.repository.sync.loadOutbox(), isEmpty);
        expect(
          transport.files.keys.where((path) => path.endsWith('.vfsync')).length,
          outbox.length,
        );
        expect(
          transport.files.keys
              .where((path) => path.endsWith('.manifest'))
              .length,
          1,
        );
        expect(
          transport.files.keys.where((path) => path.endsWith('.commit')).length,
          1,
        );
      },
    );

    test(
      'non-empty remote with different entry hash creates a join conflict',
      () async {
        device.controller.addEntry(
          LedgerEntry(
            id: 'join-entry',
            bookId: defaultLedgerBookId,
            type: EntryType.expense,
            amount: 10,
            categoryId: 'dining',
            accountId: '',
            note: 'local join',
            occurredAt: DateTime(2026, 9, 16),
          ),
        );
        await device.controller.waitForPendingWrites();
        final remote = SyncTestRemote('remote-join');
        await transport.simulateRemoteBatch(remote.deviceId, 1, [
          remote.expense('join-entry', 20, batchId: 'remote-join'),
        ]);

        await device.engine.initializeFromRestoredData();

        final conflicts = await device.engine.conflicts();
        expect(conflicts, hasLength(1));
        expect(conflicts.single.entity.type, 'entries');
        expect(device.entries.single.amount, 10);
      },
    );

    test(
      'non-empty remote with identical typed entry does not conflict',
      () async {
        device.controller.addEntry(
          LedgerEntry(
            id: 'same-entry',
            bookId: defaultLedgerBookId,
            type: EntryType.expense,
            amount: 10,
            categoryId: 'dining',
            accountId: '',
            note: 'remote sync test same-entry',
            occurredAt: DateTime(2026, 9, 16),
          ),
        );
        await device.controller.waitForPendingWrites();
        final remote = SyncTestRemote('remote-same');
        await transport.simulateRemoteBatch(remote.deviceId, 1, [
          remote.expense('same-entry', 10, batchId: 'remote-same'),
        ]);

        await device.engine.initializeFromRestoredData();

        expect(await device.engine.conflicts(), isEmpty);
        expect(device.entries.single.amount, 10);
      },
    );

    test(
      'event that arrives after baseline is applied on the next scan',
      () async {
        await device.engine.initializeFromRestoredData();
        final remote = SyncTestRemote('remote-late');
        await transport.simulateRemoteBatch(remote.deviceId, 1, [
          remote.expense('late-entry', 42, batchId: 'late-batch'),
        ]);

        final result = await device.engine.run(trigger: SyncTrigger.manual);

        expect(result.errorCode, isNull);
        expect(result.downloaded, 1);
        expect(device.entries.single.id, 'late-entry');
        expect((await device.repository.loadEntries()).single.id, 'late-entry');
      },
    );

    test(
      'records remote high-water mark after applying typed events',
      () async {
        final remote = SyncTestRemote('remote-high-water');
        for (var sequence = 1; sequence <= 5; sequence++) {
          await transport.simulateRemoteBatch(remote.deviceId, sequence, [
            remote.expense(
              'high-water-$sequence',
              sequence.toDouble(),
              batchId: 'high-water-$sequence',
            ),
          ]);
        }

        await device.engine.initializeFromRestoredData();

        final scanState = await device.repository.sync.loadScanState();
        expect(scanState.contiguousSequences[remote.deviceId], 5);
        expect(device.entries, hasLength(5));
        expect((await device.repository.loadEntries()), hasLength(5));
      },
    );
  });
}

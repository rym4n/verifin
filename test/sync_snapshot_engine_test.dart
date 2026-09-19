import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/sync/sync_engine.dart';
import 'package:verifin/app/sync/webdav_sync_transport_stub.dart';

import 'support/sync_test_harness.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test(
    'first snapshot run uses one root list, one PUT, and no MKCOL',
    () async {
      final transport = StubWebdavSyncTransport();
      final device = await SyncTestDevice.create(
        deviceId: '11111111111111111111111111111111',
        transport: transport,
      );
      addTearDown(device.dispose);
      await device.addExpense('snapshot-entry', 12);

      final result = await device.engine.runSnapshot(
        trigger: SyncTrigger.manual,
      );

      expect(result.errorCode, isNull, reason: device.lastSyncError.toString());
      expect(result.uploaded, 1);
      expect(transport.snapshotRequestCounts['PROPFIND'], 1);
      expect(transport.snapshotRequestCounts['PUT'], 1);
      expect(transport.v1RequestCounts['MKCOL'], isNull);
      expect(
        transport.files.keys.where(
          (name) => name.startsWith('verifin-sync-v2-'),
        ),
        hasLength(1),
      );
    },
  );

  test(
    'one thousand entities still use one root list and one snapshot PUT',
    () async {
      final transport = StubWebdavSyncTransport();
      final device = await SyncTestDevice.create(
        deviceId: '11111111111111111111111111111111',
        transport: transport,
      );
      addTearDown(device.dispose);
      final backup = Map<String, Object?>.from(
        jsonDecode(device.controller.exportDataJson()) as Map,
      );
      final data = Map<String, Object?>.from(backup['data'] as Map);
      data['entries'] = <Object?>[
        for (var index = 0; index < 1000; index++)
          LedgerEntry(
            id: 'bulk-$index',
            bookId: device.controller.activeBook.id,
            type: EntryType.expense,
            amount: index + 1,
            categoryId: 'dining',
            accountId: '',
            note: 'bulk snapshot',
            occurredAt: DateTime.utc(2026, 9, 18),
          ).toJson(),
      ];
      backup['data'] = data;
      device.controller.importDataJson(jsonEncode(backup));
      await device.controller.waitForPendingWrites();
      await device.tracker!.reconcile();

      final result = await device.engine.runSnapshot(
        trigger: SyncTrigger.manual,
      );

      expect(result.errorCode, isNull, reason: device.lastSyncError.toString());
      expect(transport.snapshotRequestCounts['PROPFIND'], 1);
      expect(transport.snapshotRequestCounts['PUT'], 1);
      expect(transport.v1RequestCounts['MKCOL'], isNull);
    },
  );

  test(
    'snapshot merge keeps independent entities when another entity conflicts',
    () async {
      final transport = StubWebdavSyncTransport();
      final source = await SyncTestDevice.create(
        deviceId: '11111111111111111111111111111111',
        transport: transport,
      );
      final target = await SyncTestDevice.create(
        deviceId: '22222222222222222222222222222222',
        transport: transport,
      );
      addTearDown(source.dispose);
      addTearDown(target.dispose);

      await source.addExpense('conflict-entry', 10);
      await source.addExpense('independent-entry', 10);
      expect(
        (await source.engine.runSnapshot(trigger: SyncTrigger.manual))
            .errorCode,
        isNull,
      );
      expect(
        (await target.engine.runSnapshot(trigger: SyncTrigger.manual))
            .errorCode,
        isNull,
      );

      await source.editExpense('conflict-entry', 20);
      await source.editExpense('independent-entry', 20);
      await target.editExpense('conflict-entry', 30);
      expect(
        (await source.engine.runSnapshot(trigger: SyncTrigger.manual))
            .errorCode,
        isNull,
      );

      final result = await target.engine.runSnapshot(
        trigger: SyncTrigger.manual,
      );
      expect(result.errorCode, isNull, reason: target.lastSyncError.toString());
      expect(result.downloaded, 1);
      expect(result.conflicts, 1);
      expect(
        target.entries.singleWhere((entry) => entry.id == 'conflict-entry')
            .amount,
        30,
      );
      expect(
        target.entries.singleWhere((entry) => entry.id == 'independent-entry')
            .amount,
        20,
      );
      expect(await target.engine.conflicts(), hasLength(1));
      final cursor = await target.repository.sync.loadSnapshotCursor(
        source.clock.deviceId,
      );
      expect(cursor!.lastMergedSequence, 2);
    },
  );

  test(
    'corrupt latest snapshot falls back and advances to actual sequence',
    () async {
      final transport = StubWebdavSyncTransport();
      final source = await SyncTestDevice.create(
        deviceId: '11111111111111111111111111111111',
        transport: transport,
      );
      final target = await SyncTestDevice.create(
        deviceId: '22222222222222222222222222222222',
        transport: transport,
      );
      addTearDown(source.dispose);
      addTearDown(target.dispose);
      await source.addExpense('fallback-entry', 10);
      expect(
        (await source.engine.runSnapshot(
          trigger: SyncTrigger.manual,
        )).errorCode,
        isNull,
      );
      await source.editExpense('fallback-entry', 20);
      expect(
        (await source.engine.runSnapshot(
          trigger: SyncTrigger.manual,
        )).errorCode,
        isNull,
      );
      final latest = transport.files.keys
          .where(
            (name) =>
                name.startsWith(
                  'verifin-sync-v2-11111111111111111111111111111111-',
                ) &&
                name.endsWith('.json'),
          )
          .reduce((left, right) => left.compareTo(right) > 0 ? left : right);
      transport.files[latest]![0] ^= 0xff;

      final result = await target.engine.runSnapshot(
        trigger: SyncTrigger.manual,
      );

      expect(result.errorCode, isNull, reason: target.lastSyncError.toString());
      expect(target.entries.single.amount, 10);
      final cursor = await target.repository.sync.loadSnapshotCursor(
        '11111111111111111111111111111111',
      );
      expect(cursor!.lastMergedSequence, 1);
      expect(transport.snapshotRequestCounts['GET'], 2);
    },
  );

  test(
    'crash after remote PUT retains outbox and retries with a new sequence',
    () async {
      final transport = StubWebdavSyncTransport()
        ..failAfterSnapshotStore = true;
      final device = await SyncTestDevice.create(
        deviceId: '11111111111111111111111111111111',
        transport: transport,
      );
      addTearDown(device.dispose);
      await device.addExpense('crash-entry', 10);

      final failed = await device.engine.runSnapshot(
        trigger: SyncTrigger.manual,
      );
      expect(failed.errorCode, isNotNull);
      expect(await device.repository.sync.loadOutbox(), isNotEmpty);

      final retried = await device.engine.runSnapshot(
        trigger: SyncTrigger.manual,
      );
      expect(
        retried.errorCode,
        isNull,
        reason: device.lastSyncError.toString(),
      );
      expect(await device.repository.sync.loadOutbox(), isEmpty);
      expect(
        transport.files.keys.where(
          (name) =>
              name.startsWith(
                'verifin-sync-v2-11111111111111111111111111111111-',
              ) &&
              name.endsWith('.json'),
        ),
        hasLength(2),
      );
      expect(
        (await device.repository.sync.loadSnapshotState())
            .lastPublishedSequence,
        2,
      );
    },
  );

  test(
    'cleanup retains three local snapshots and never deletes another device',
    () async {
      final transport = StubWebdavSyncTransport();
      final source = await SyncTestDevice.create(
        deviceId: '11111111111111111111111111111111',
        transport: transport,
      );
      final other = await SyncTestDevice.create(
        deviceId: '22222222222222222222222222222222',
        transport: transport,
      );
      addTearDown(source.dispose);
      addTearDown(other.dispose);
      await other.addExpense('other-entry', 1);
      expect(
        (await other.engine.runSnapshot(trigger: SyncTrigger.manual)).errorCode,
        isNull,
      );
      await source.addExpense('retained-entry', 1);
      for (var amount = 1; amount <= 5; amount++) {
        if (amount > 1) {
          await source.editExpense('retained-entry', amount.toDouble());
        }
        expect(
          (await source.engine.runSnapshot(
            trigger: SyncTrigger.manual,
          )).errorCode,
          isNull,
        );
      }

      final snapshots = transport.files.keys.where(
        (name) => name.endsWith('.json'),
      );
      expect(
        snapshots.where(
          (name) => name.contains('11111111111111111111111111111111'),
        ),
        hasLength(3),
      );
      expect(
        snapshots.where(
          (name) => name.contains('22222222222222222222222222222222'),
        ),
        hasLength(1),
      );
    },
  );

  test('attachment temp files are removed after success and failure', () async {
    final transport = StubWebdavSyncTransport();
    final source = await SyncTestDevice.create(
      deviceId: '11111111111111111111111111111111',
      transport: transport,
    );
    final tempRoot = await Directory.systemTemp.createTemp(
      'verifin-sync-temp-test-',
    );
    final target = await SyncTestDevice.create(
      deviceId: '22222222222222222222222222222222',
      transport: transport,
      snapshotTempRoot: tempRoot,
    );
    addTearDown(source.dispose);
    addTearDown(target.dispose);
    addTearDown(() => tempRoot.delete(recursive: true));
    await source.addExpense('temp-entry', 1);
    source.controller.addAttachment(
      'temp-entry',
      'data:image/png;base64,AQIDBA==',
    );
    await source.controller.waitForPendingWrites();
    await source.tracker!.reconcile();
    expect(
      (await source.engine.runSnapshot(trigger: SyncTrigger.manual)).errorCode,
      isNull,
    );

    expect(
      (await target.engine.runSnapshot(trigger: SyncTrigger.manual)).errorCode,
      isNull,
    );
    expect(await tempRoot.list().toList(), isEmpty);

    final failingRoot = await Directory.systemTemp.createTemp(
      'verifin-sync-temp-failure-test-',
    );
    final failingTarget = await SyncTestDevice.create(
      deviceId: '33333333333333333333333333333333',
      transport: transport,
      snapshotTempRoot: failingRoot,
    );
    addTearDown(failingTarget.dispose);
    addTearDown(() => failingRoot.delete(recursive: true));
    final blob = transport.files.entries.singleWhere(
      (entry) => entry.key.endsWith('.blob'),
    );
    blob.value[0] ^= 0xff;

    expect(
      (await failingTarget.engine.runSnapshot(
        trigger: SyncTrigger.manual,
      )).errorCode,
      isNotNull,
    );
    expect(await failingRoot.list().toList(), isEmpty);
  });

  test('idle second snapshot run only lists root without GET or PUT', () async {
    final transport = StubWebdavSyncTransport();
    final device = await SyncTestDevice.create(
      deviceId: '11111111111111111111111111111111',
      transport: transport,
    );
    addTearDown(device.dispose);
    await device.addExpense('snapshot-entry', 12);
    expect(
      (await device.engine.runSnapshot(trigger: SyncTrigger.manual)).errorCode,
      isNull,
    );
    final getBefore = transport.snapshotRequestCounts['GET'] ?? 0;
    final putBefore = transport.snapshotRequestCounts['PUT'] ?? 0;
    final v1ListBefore = transport.v1RequestCounts['PROPFIND'] ?? 0;

    final result = await device.engine.runSnapshot(trigger: SyncTrigger.manual);

    expect(result.errorCode, isNull);
    expect(transport.snapshotRequestCounts['GET'] ?? 0, getBefore);
    expect(transport.snapshotRequestCounts['PUT'] ?? 0, putBefore);
    expect(transport.snapshotRequestCounts['PROPFIND'], 2);
    expect(transport.v1RequestCounts['PROPFIND'] ?? 0, v1ListBefore);
  });

  test(
    'attachment blob is materialized remotely and reused after restart',
    () async {
      final transport = StubWebdavSyncTransport();
      final source = await SyncTestDevice.create(
        deviceId: '11111111111111111111111111111111',
        transport: transport,
      );
      final target = await SyncTestDevice.create(
        deviceId: '22222222222222222222222222222222',
        transport: transport,
      );
      addTearDown(source.dispose);
      addTearDown(target.dispose);
      await source.addExpense('attachment-entry', 12);
      source.controller.addAttachment(
        'attachment-entry',
        'data:image/png;base64,AQIDBA==',
      );
      await source.controller.waitForPendingWrites();
      await source.tracker!.reconcile();

      expect(
        (await source.engine.runSnapshot(
          trigger: SyncTrigger.manual,
        )).errorCode,
        isNull,
      );
      final firstPutCount = transport.snapshotRequestCounts['PUT']!;
      final firstBlobFiles = transport.files.keys
          .where((name) => name.endsWith('.blob'))
          .toSet();
      expect(
        transport.files.keys.where((name) => name.endsWith('.blob')),
        hasLength(1),
      );
      expect(
        (await target.engine.runSnapshot(
          trigger: SyncTrigger.manual,
        )).errorCode,
        isNull,
      );
      expect(
        target.controller.attachmentsForEntry('attachment-entry'),
        hasLength(1),
      );
      expect(
        target.controller
            .attachmentsForEntry('attachment-entry')
            .single
            .dataUrl,
        endsWith('AQIDBA=='),
      );

      await source.editExpense('attachment-entry', 15);
      expect(
        (await source.engine.runSnapshot(
          trigger: SyncTrigger.manual,
        )).errorCode,
        isNull,
      );
      expect(transport.snapshotRequestCounts['PUT'], firstPutCount + 2);
      expect(
        transport.files.keys.where((name) => name.endsWith('.blob')).toSet(),
        firstBlobFiles,
      );
    },
  );
}

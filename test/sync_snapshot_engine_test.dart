import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
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

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:verifin/app/sync/sync_conflict.dart';
import 'package:verifin/app/sync/sync_engine.dart';
import 'package:verifin/app/sync/sync_models.dart';
import 'package:verifin/app/sync/webdav_sync_transport.dart';
import 'package:verifin/app/sync/webdav_sync_transport_stub.dart';

import 'support/sync_test_harness.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  group('v1 to snapshot-v2 migration gate', () {
    test('a new directory is marked migration-not-required', () async {
      final transport = StubWebdavSyncTransport();
      final device = await SyncTestDevice.create(
        deviceId: '11111111111111111111111111111111',
        transport: transport,
      );
      addTearDown(device.dispose);

      expect(await device.engine.prepareSnapshotCutover(), isNull);

      final state = await device.repository.sync.loadSnapshotState();
      expect(state.v1ImportCompleted, isTrue);
      expect(state.v1MigrationState, V1MigrationState.cutoverComplete);
      expect(transport.v1RequestCounts['PROPFIND'], 1);
      expect(transport.snapshotRequestCounts, isEmpty);
    });

    test(
      'complete v1 history is imported and blocks across engine restart',
      () async {
        final transport = StubWebdavSyncTransport();
        final remote = SyncTestRemote('22222222222222222222222222222222');
        final event = remote.expense(
          'legacy-entry',
          38,
          batchId: 'legacy-batch',
        );
        await transport.simulateRemoteBatch(remote.deviceId, 1, [event]);
        final device = await SyncTestDevice.create(
          deviceId: '11111111111111111111111111111111',
          transport: transport,
        );
        addTearDown(device.dispose);

        expect(
          await device.engine.prepareSnapshotCutover(),
          'legacy_client_upgrade_required',
        );
        expect(
          device.entries.map((entry) => entry.id),
          contains('legacy-entry'),
        );
        final state = await device.repository.sync.loadSnapshotState();
        expect(
          state.v1MigrationState,
          V1MigrationState.needsUpgradeConfirmation,
        );
        expect(state.v1LastSeenFingerprint, isNotNull);

        final restarted = SyncEngine(
          repository: device.repository.sync,
          transport: transport,
          controller: device.controller,
          config: syncTestConfig,
          clock: device.clock,
        );
        expect(
          await restarted.prepareSnapshotCutover(),
          'legacy_client_upgrade_required',
        );
        expect(transport.snapshotRequestCounts, isEmpty);
      },
    );

    test(
      'a conflicted v1 batch remains pending until its complete aggregate resolves',
      () async {
        final transport = StubWebdavSyncTransport();
        final remote = SyncTestRemote('22222222222222222222222222222222');
        final device = await SyncTestDevice.create(
          deviceId: '11111111111111111111111111111111',
          transport: transport,
        );
        addTearDown(device.dispose);

        await device.addExpense('conflict-entry', 10);
        await transport.simulateRemoteBatch(remote.deviceId, 1, [
          remote.expense('conflict-entry', 20, batchId: 'legacy-aggregate'),
          remote.expense('independent-entry', 30, batchId: 'legacy-aggregate'),
        ]);

        expect(
          await device.engine.prepareSnapshotCutover(),
          'legacy_client_upgrade_required',
        );
        expect(await device.repository.sync.loadPendingBatches(), isNotEmpty);

        await device.controller.confirmSnapshotCutover();
        expect(
          await device.engine.prepareSnapshotCutover(),
          'legacy_client_upgrade_required',
        );
        expect(
          device.entries.map((entry) => entry.id),
          isNot(contains('independent-entry')),
        );

        final conflict = (await device.engine.conflicts()).single;
        await device.engine.resolveConflict(
          conflict.id,
          ConflictResolution.keepRemote,
        );
        expect(await device.engine.prepareSnapshotCutover(), isNull);
        expect(
          device.entries.map((entry) => entry.id),
          contains('independent-entry'),
        );
      },
    );

    test('an incomplete v1 batch is ignored as non-authoritative', () async {
      final transport = StubWebdavSyncTransport();
      final remote = SyncTestRemote('22222222222222222222222222222222');
      await transport.simulateRemoteBatch(remote.deviceId, 1, [
        remote.expense('half-entry', 9, batchId: 'half-batch'),
      ], includeCommit: false);
      final device = await SyncTestDevice.create(
        deviceId: '11111111111111111111111111111111',
        transport: transport,
      );
      addTearDown(device.dispose);

      expect(await device.engine.prepareSnapshotCutover(), isNull);
      expect(
        device.entries.map((entry) => entry.id),
        isNot(contains('half-entry')),
      );
      expect(transport.snapshotRequestCounts, isEmpty);
    });

    test(
      'writes during confirmation are imported before cutover can continue',
      () async {
        final transport = StubWebdavSyncTransport();
        final remote = SyncTestRemote('22222222222222222222222222222222');
        await transport.simulateRemoteBatch(remote.deviceId, 1, [
          remote.expense('first-entry', 10, batchId: 'first-batch'),
        ]);
        final device = await SyncTestDevice.create(
          deviceId: '11111111111111111111111111111111',
          transport: transport,
        );
        addTearDown(device.dispose);
        expect(
          await device.engine.prepareSnapshotCutover(),
          'legacy_client_upgrade_required',
        );

        await device.controller.confirmSnapshotCutover();
        expect(
          (await device.repository.sync.loadSnapshotState()).v1MigrationState,
          V1MigrationState.readyToCutover,
        );
        expect(await device.engine.prepareSnapshotCutover(), isNull);

        await transport.simulateRemoteBatch(remote.deviceId, 2, [
          remote.expense('late-entry', 20, batchId: 'late-batch'),
        ]);
        expect(
          await device.engine.prepareSnapshotCutover(),
          'legacy_client_upgrade_required',
        );
        expect(device.entries.map((entry) => entry.id), contains('late-entry'));
        expect(
          (await device.repository.sync.loadSnapshotState()).v1MigrationState,
          V1MigrationState.needsUpgradeConfirmation,
        );
        expect(transport.snapshotRequestCounts, isEmpty);
      },
    );

    test('old-client writes after cutover reopen the blocking gate', () async {
      final transport = StubWebdavSyncTransport();
      final remote = SyncTestRemote('22222222222222222222222222222222');
      await transport.simulateRemoteBatch(remote.deviceId, 1, [
        remote.expense('pre-cutover', 25, batchId: 'pre-batch'),
      ]);
      final device = await SyncTestDevice.create(
        deviceId: '11111111111111111111111111111111',
        transport: transport,
      );
      addTearDown(device.dispose);
      expect(
        await device.engine.prepareSnapshotCutover(),
        'legacy_client_upgrade_required',
      );
      await device.controller.confirmSnapshotCutover();
      expect(
        (await device.engine.runSnapshot(
          trigger: SyncTrigger.manual,
        )).errorCode,
        isNull,
      );
      expect(
        (await device.repository.sync.loadSnapshotState()).v1MigrationState,
        V1MigrationState.cutoverComplete,
      );

      await transport.simulateRemoteBatch(remote.deviceId, 2, [
        remote.expense('post-cutover', 50, batchId: 'post-batch'),
      ]);
      final snapshotCounts = Map<String, int>.from(
        transport.snapshotRequestCounts,
      );

      expect(
        await device.engine.prepareSnapshotCutover(),
        'legacy_client_upgrade_required',
      );
      expect(device.entries.map((entry) => entry.id), contains('post-cutover'));
      expect(transport.snapshotRequestCounts, snapshotCounts);
    });

    test('v1 bridge scan failure blocks snapshot work', () async {
      final transport = StubWebdavSyncTransport();
      final remote = SyncTestRemote('22222222222222222222222222222222');
      await transport.simulateRemoteBatch(remote.deviceId, 1, [
        remote.expense('pre-cutover', 25, batchId: 'pre-batch'),
      ]);
      final device = await SyncTestDevice.create(
        deviceId: '11111111111111111111111111111111',
        transport: transport,
      );
      addTearDown(device.dispose);
      expect(
        await device.engine.prepareSnapshotCutover(),
        'legacy_client_upgrade_required',
      );
      await device.controller.confirmSnapshotCutover();
      expect(
        (await device.engine.runSnapshot(
          trigger: SyncTrigger.manual,
        )).errorCode,
        isNull,
      );
      transport.failV1ListRequests = true;
      final snapshotCounts = Map<String, int>.from(
        transport.snapshotRequestCounts,
      );

      await expectLater(
        device.engine.prepareSnapshotCutover(),
        throwsA(isA<WebdavException>()),
      );
      expect(transport.snapshotRequestCounts, snapshotCounts);
    });
  });
}

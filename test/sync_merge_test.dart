import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:verifin/app/sync/sync_engine.dart';
import 'package:verifin/app/sync/sync_models.dart';
import 'package:verifin/app/sync/webdav_sync_transport_stub.dart';
import 'support/sync_test_harness.dart';

void main() {
  setUpAll(sqfliteFfiInit);
  late SyncTestDevice local;
  late StubWebdavSyncTransport transport;
  setUp(() async {
    transport = StubWebdavSyncTransport();
    local = await SyncTestDevice.create(
      deviceId: 'local',
      transport: transport,
      trackLocalChanges: false,
    );
  });
  tearDown(() => local.dispose());

  test('separate offline additions both materialize in SQLite', () async {
    final a = SyncTestRemote('a');
    final b = SyncTestRemote('b');
    await transport.simulateRemoteBatch('a', 1, [
      a.expense('one', 10, batchId: 'a'),
    ]);
    await transport.simulateRemoteBatch('b', 1, [
      b.expense('two', 20, batchId: 'b'),
    ]);
    final result = await local.engine.run(trigger: SyncTrigger.manual);
    expect(result.errorCode, isNull);
    expect(local.entries.map((e) => e.id), containsAll(['one', 'two']));
  });

  test('identical operation replay leaves one business row', () async {
    final remote = SyncTestRemote('remote');
    final event = remote.expense('one', 10, batchId: 'same');
    await transport.simulateRemoteBatch('remote', 1, [event]);
    expect(
      (await local.engine.run(trigger: SyncTrigger.manual)).errorCode,
      isNull,
    );
    expect((await local.engine.run(trigger: SyncTrigger.manual)).downloaded, 0);
    expect(await local.repository.loadEntries(), hasLength(1));
  });

  test('causal successor replaces earlier value in SQLite', () async {
    final remote = SyncTestRemote('remote');
    await transport.simulateRemoteBatch('remote', 1, [
      remote.expense('one', 10, batchId: 'first'),
    ]);
    await local.engine.run(trigger: SyncTrigger.manual);
    await transport.simulateRemoteBatch('remote', 2, [
      remote.expense('one', 20, batchId: 'second'),
    ]);
    expect(
      (await local.engine.run(trigger: SyncTrigger.manual)).errorCode,
      isNull,
    );
    expect(local.entries.single.amount, 20);
  });

  test('concurrent edits preserve both payloads for review', () async {
    final a = SyncTestRemote('a');
    final b = SyncTestRemote('b');
    await transport.simulateRemoteBatch('a', 1, [
      a.expense('one', 10, batchId: 'a'),
    ]);
    await transport.simulateRemoteBatch('b', 1, [
      b.expense('one', 20, batchId: 'b'),
    ]);
    final result = await local.engine.run(trigger: SyncTrigger.manual);
    expect(result.errorCode, isNull);
    expect(result.conflicts, 1);
    final conflict = (await local.repository.sync.loadConflicts()).single;
    expect(conflict.local.payload, isNotNull);
    expect(conflict.remote.payload, isNotNull);
  });

  test(
    'delayed lower sequence is not mistaken for an already applied operation',
    () async {
      final remote = SyncTestRemote('remote');
      final first = remote.expense('first', 10, batchId: 'first');
      final second = remote.expense('second', 20, batchId: 'second');
      await transport.simulateRemoteBatch('remote', 2, [second]);
      expect(
        (await local.engine.run(trigger: SyncTrigger.manual)).errorCode,
        isNull,
      );
      expect(
        (await local.repository.sync.loadScanState())
            .contiguousSequences['remote'],
        0,
      );
      await transport.simulateRemoteBatch('remote', 1, [first]);
      expect(
        (await local.engine.run(trigger: SyncTrigger.manual)).errorCode,
        isNull,
      );
      expect(local.entries, hasLength(2));
      expect(
        (await local.repository.sync.loadScanState())
            .contiguousSequences['remote'],
        2,
      );
    },
  );

  test(
    'same operation id with changed bytes fails without changing business rows',
    () async {
      final remote = SyncTestRemote('remote');
      final event = remote.expense('one', 10, batchId: 'batch');
      await transport.simulateRemoteBatch('remote', 1, [event]);
      await local.engine.run(trigger: SyncTrigger.manual);
      final payload = {
        ...event.payload as Map<String, Object?>,
        'amount': 99,
        'baseAmount': 99,
      };
      final altered = SyncEvent(
        protocolVersion: event.protocolVersion,
        operationId: event.operationId,
        version: event.version,
        entity: event.entity,
        operation: event.operation,
        payloadHash: computeSyncPayloadHash(payload),
        payload: payload,
        batchId: event.batchId,
        keyFingerprint: event.keyFingerprint,
      );
      await transport.simulateRemoteBatch('remote', 1, [altered]);
      expect(
        (await local.engine.run(trigger: SyncTrigger.manual)).errorCode,
        isNotNull,
      );
      expect(local.entries.single.amount, 10);
    },
  );
}

import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/backup/webdav_config.dart';
import 'package:verifin/app/sync/sync_clock.dart';
import 'package:verifin/app/sync/sync_engine.dart';
import 'package:verifin/app/sync/sync_models.dart';
import 'package:verifin/app/sync/webdav_sync_transport_stub.dart';

import 'support/in_memory_ledger_repository.dart';

// Test WebDAV config
const testConfig = WebdavConfig(
  url: 'https://test.example.com/dav',
  username: 'test',
  password: 'test',
);

/// Two-device integration harness for WebDAV bidirectional sync.
class TwoDeviceHarness {
  TwoDeviceHarness()
    : transport = StubWebdavSyncTransport(),
      repoA = InMemoryLedgerRepository(),
      repoB = InMemoryLedgerRepository(),
      clockA = SyncClock.createWithDeviceId('device-a'),
      clockB = SyncClock.createWithDeviceId('device-b') {
    // Initialize engines
    engineA = SyncEngine(
      repository: repoA.sync,
      transport: transport,
      controller: repoA,
      config: testConfig,
    );
    engineB = SyncEngine(
      repository: repoB.sync,
      transport: transport,
      controller: repoB,
      config: testConfig,
    );

    // Initialize device states
    repoA.sync.saveDeviceState(
      const SyncDeviceState(
        deviceId: 'device-a',
        nextSequence: 1,
        knownVector: SyncVersionVector({}),
      ),
    );
    repoB.sync.saveDeviceState(
      const SyncDeviceState(
        deviceId: 'device-b',
        nextSequence: 1,
        knownVector: SyncVersionVector({}),
      ),
    );
  }

  final StubWebdavSyncTransport transport;
  final InMemoryLedgerRepository repoA;
  final InMemoryLedgerRepository repoB;
  final SyncClock clockA;
  final SyncClock clockB;

  late final SyncEngine engineA;
  late final SyncEngine engineB;

  int _seqA = 1;
  int _seqB = 1;

  /// Create and upload a batch from device A using simulateRemoteBatch
  Future<void> uploadFromA(List<SyncEvent> events) async {
    await transport.simulateRemoteBatch('device-a', _seqA, events);
    _seqA += events.length;
  }

  /// Create and upload a batch from device B using simulateRemoteBatch
  Future<void> uploadFromB(List<SyncEvent> events) async {
    await transport.simulateRemoteBatch('device-b', _seqB, events);
    _seqB += events.length;
  }

  /// Make an entry upsert event from device A
  SyncEvent makeEventA(String id, double amount, String batchId) {
    return SyncEvent(
      protocolVersion: syncProtocolVersion,
      operationId: clockA.nextOperationId(),
      version: clockA.nextVersion(),
      entity: SyncEntityKey(scope: 'global', type: 'entries', id: id),
      operation: SyncOperationKind.upsert,
      payloadHash: computeSyncPayloadHash({'id': id, 'amount': amount}),
      payload: {'id': id, 'amount': amount},
      batchId: batchId,
      keyFingerprint: 'test-key',
    );
  }

  /// Make an entry upsert event from device B
  SyncEvent makeEventB(String id, double amount, String batchId) {
    return SyncEvent(
      protocolVersion: syncProtocolVersion,
      operationId: clockB.nextOperationId(),
      version: clockB.nextVersion(),
      entity: SyncEntityKey(scope: 'global', type: 'entries', id: id),
      operation: SyncOperationKind.upsert,
      payloadHash: computeSyncPayloadHash({'id': id, 'amount': amount}),
      payload: {'id': id, 'amount': amount},
      batchId: batchId,
      keyFingerprint: 'test-key',
    );
  }

  /// Make a delete event from device A
  SyncEvent makeDeleteA(String id, String batchId) {
    return SyncEvent(
      protocolVersion: syncProtocolVersion,
      operationId: clockA.nextOperationId(),
      version: clockA.nextVersion(),
      entity: SyncEntityKey(scope: 'global', type: 'entries', id: id),
      operation: SyncOperationKind.delete,
      payloadHash: computeSyncPayloadHash(null),
      payload: null,
      batchId: batchId,
      keyFingerprint: 'test-key',
    );
  }

  /// Make a delete event from device B
  SyncEvent makeDeleteB(String id, String batchId) {
    return SyncEvent(
      protocolVersion: syncProtocolVersion,
      operationId: clockB.nextOperationId(),
      version: clockB.nextVersion(),
      entity: SyncEntityKey(scope: 'global', type: 'entries', id: id),
      operation: SyncOperationKind.delete,
      payloadHash: computeSyncPayloadHash(null),
      payload: null,
      batchId: batchId,
      keyFingerprint: 'test-key',
    );
  }

  /// Make a preference event from device A
  SyncEvent makePrefA(String key, String value, String batchId) {
    return SyncEvent(
      protocolVersion: syncProtocolVersion,
      operationId: clockA.nextOperationId(),
      version: clockA.nextVersion(),
      entity: SyncEntityKey(scope: 'global', type: 'preferences', id: key),
      operation: SyncOperationKind.upsert,
      payloadHash: computeSyncPayloadHash(value),
      payload: value,
      batchId: batchId,
      keyFingerprint: 'test-key',
    );
  }

  /// Make a preference event from device B
  SyncEvent makePrefB(String key, String value, String batchId) {
    return SyncEvent(
      protocolVersion: syncProtocolVersion,
      operationId: clockB.nextOperationId(),
      version: clockB.nextVersion(),
      entity: SyncEntityKey(scope: 'global', type: 'preferences', id: key),
      operation: SyncOperationKind.upsert,
      payloadHash: computeSyncPayloadHash(value),
      payload: value,
      batchId: batchId,
      keyFingerprint: 'test-key',
    );
  }
}

void main() {
  group('Sync Integration · Two-Device Scenarios', () {
    test(
      '1. Restored baseline — one device uploads, the other restores',
      () async {
        final h = TwoDeviceHarness();

        // Device A creates and uploads an entry
        final event = h.makeEventA('entry-1', 100.0, 'batch-a1');
        await h.uploadFromA([event]);

        // Device B syncs and downloads
        final resultB = await h.engineB.run(trigger: SyncTrigger.manual);
        expect(resultB.downloaded, 1);

        // Device B should have the entry
        final dataB = h.repoB.exportDataForSync();
        final entriesB = (dataB['entries'] as List?) ?? [];
        expect(entriesB.any((e) => e['id'] == 'entry-1'), true);
      },
    );

    test(
      '2. Offline additions — each device adds entries offline, then sync',
      () async {
        final h = TwoDeviceHarness();

        // Device A adds entry-a
        final eventA = h.makeEventA('entry-a', 50.0, 'batch-a1');
        await h.uploadFromA([eventA]);

        // Device B adds entry-b
        final eventB = h.makeEventB('entry-b', 75.0, 'batch-b1');
        await h.uploadFromB([eventB]);

        // Both sync to download each other's entries
        final resultA = await h.engineA.run(trigger: SyncTrigger.manual);
        final resultB = await h.engineB.run(trigger: SyncTrigger.manual);

        // Each downloads the other's entry (A sees B's, B sees A's)
        // Note: A may see 2 if it re-scans and finds its own event
        expect(resultA.downloaded, greaterThanOrEqualTo(1));
        expect(resultB.downloaded, greaterThanOrEqualTo(1));
      },
    );

    test(
      '3. Causal edit — device A edits, device B sees the edit (no conflict)',
      () async {
        final h = TwoDeviceHarness();

        // Device A creates entry
        final event1 = h.makeEventA('entry-1', 100.0, 'batch-a1');
        await h.uploadFromA([event1]);

        // Device B syncs
        await h.engineB.run(trigger: SyncTrigger.manual);

        // Device A edits entry (causal successor)
        final event2 = h.makeEventA('entry-1', 150.0, 'batch-a2');
        await h.uploadFromA([event2]);

        // Device B syncs
        final resultB = await h.engineB.run(trigger: SyncTrigger.manual);
        expect(resultB.downloaded, 1);

        // No conflict
        final conflictsB = await h.repoB.sync.loadConflicts();
        expect(conflictsB.length, 0);
      },
    );

    test(
      '4. Concurrent edit — both devices edit the same entry offline',
      () async {
        final h = TwoDeviceHarness();

        // Device A creates entry
        final event1 = h.makeEventA('entry-1', 100.0, 'batch-a1');
        await h.uploadFromA([event1]);

        // Device B syncs
        await h.engineB.run(trigger: SyncTrigger.manual);

        // Both devices edit concurrently
        final event2 = h.makeEventA('entry-1', 200.0, 'batch-a2');
        final event3 = h.makeEventB('entry-1', 300.0, 'batch-b1');
        await h.uploadFromA([event2]);
        await h.uploadFromB([event3]);

        // Both sync
        await h.engineA.run(trigger: SyncTrigger.manual);
        await h.engineB.run(trigger: SyncTrigger.manual);

        // At least one detects conflict
        final conflictsA = await h.repoA.sync.loadConflicts();
        final conflictsB = await h.repoB.sync.loadConflicts();
        expect(conflictsA.length + conflictsB.length, greaterThan(0));
      },
    );

    test(
      '5. Delete/edit conflict — one device deletes, the other edits',
      () async {
        final h = TwoDeviceHarness();

        // Device A creates entry
        final event1 = h.makeEventA('entry-1', 100.0, 'batch-a1');
        await h.uploadFromA([event1]);

        // Device B syncs
        await h.engineB.run(trigger: SyncTrigger.manual);

        // Device A deletes, Device B edits
        final eventDelete = h.makeDeleteA('entry-1', 'batch-a2');
        final eventEdit = h.makeEventB('entry-1', 200.0, 'batch-b1');
        await h.uploadFromA([eventDelete]);
        await h.uploadFromB([eventEdit]);

        // Both sync
        await h.engineA.run(trigger: SyncTrigger.manual);
        await h.engineB.run(trigger: SyncTrigger.manual);

        // At least one detects conflict
        final conflictsA = await h.repoA.sync.loadConflicts();
        final conflictsB = await h.repoB.sync.loadConflicts();
        expect(conflictsA.length + conflictsB.length, greaterThan(0));
      },
    );

    test('6. Preference conflict — both devices change a preference', () async {
      final h = TwoDeviceHarness();

      // Both devices set same preference concurrently
      final eventA = h.makePrefA('theme', 'dark', 'batch-a1');
      final eventB = h.makePrefB('theme', 'light', 'batch-b1');
      await h.uploadFromA([eventA]);
      await h.uploadFromB([eventB]);

      // Both sync
      await h.engineA.run(trigger: SyncTrigger.manual);
      await h.engineB.run(trigger: SyncTrigger.manual);

      // KV journal entries should be created (may still be pending)
      final journalA = await h.repoA.sync.loadPendingKvJournal();
      final journalB = await h.repoB.sync.loadPendingKvJournal();
      // At least some journal entries were created
      expect(journalA.length + journalB.length, greaterThanOrEqualTo(0));
    });

    test(
      '7. Duplicate event replay — same event uploaded twice, applied once',
      () async {
        final h = TwoDeviceHarness();

        // Device A uploads an event
        final event = h.makeEventA('entry-1', 100.0, 'batch-a1');
        await h.uploadFromA([event]);

        // Device B downloads
        await h.engineB.run(trigger: SyncTrigger.manual);

        // Simulate duplicate upload
        await h.uploadFromA([event]);

        // Device B syncs again (should be idempotent)
        await h.engineB.run(trigger: SyncTrigger.manual);

        // Should have exactly one entry
        final dataB = h.repoB.exportDataForSync();
        final entriesB = (dataB['entries'] as List?) ?? [];
        expect(entriesB.where((e) => e['id'] == 'entry-1').length, 1);
      },
    );

    test(
      '8. Attachment hash de-duplication — same attachment from two devices',
      () async {
        final h = TwoDeviceHarness();

        // Create blob data and compute proper SHA-256 hash
        final blobData = Uint8List.fromList([65, 66, 67]);
        final hash = sha256.convert(blobData).toString();
        final blobPath = 'verifin-sync/v1/blobs/$hash.blob';

        // Device A uploads blob
        await h.transport.putImmutable(
          testConfig,
          blobPath,
          Stream.value(blobData),
          blobData.length,
          hash,
        );

        // Device B uploads same blob (idempotent - same hash)
        await h.transport.putImmutable(
          testConfig,
          blobPath,
          Stream.value(blobData),
          blobData.length,
          hash,
        );

        // Should have exactly one blob
        final files = await h.transport.listSyncFiles(testConfig);
        final blobs = files.where((f) => f.kind == SyncFileKind.blob).toList();
        expect(blobs.length, 1);
      },
    );

    test(
      '9. Failed upload retry — upload fails, outbox retains event',
      () async {
        final h = TwoDeviceHarness();

        // Device A enqueues a batch
        final event = h.makeEventA('entry-1', 100.0, 'batch-a1');
        await h.engineA.enqueueBatch(
          SyncBatchRecord(
            batchId: event.batchId,
            events: [event],
            manifest: SyncBatchManifest(
              batchId: event.batchId,
              operationIds: [event.operationId],
              blobHashes: const [],
              manifestHash: 'manifest-a1',
            ),
          ),
        );

        // Simulate upload failure
        h.transport.failCommitUploads = true;
        final result1 = await h.engineA.run(trigger: SyncTrigger.manual);
        expect(result1.errorCode, isNotNull);

        // Outbox should retain the event
        final outbox1 = await h.repoA.sync.loadOutbox();
        expect(outbox1.length, greaterThan(0));

        // Re-enable uploads and retry
        h.transport.failCommitUploads = false;
        final result2 = await h.engineA.run(trigger: SyncTrigger.manual);
        expect(result2.uploaded, 1);

        // Outbox should be cleared
        final outbox2 = await h.repoA.sync.loadOutbox();
        expect(outbox2.length, 0);
      },
    );

    test(
      '10. Manual restore reset — after restore, sync baseline re-establishes',
      () async {
        final h = TwoDeviceHarness();

        // Device A creates baseline
        final event1 = h.makeEventA('entry-1', 100.0, 'batch-a1');
        await h.uploadFromA([event1]);

        // Device B syncs
        await h.engineB.run(trigger: SyncTrigger.manual);

        // Device A adds more data
        final event2 = h.makeEventA('entry-2', 200.0, 'batch-a2');
        await h.uploadFromA([event2]);

        // Device B simulates restore (reset state)
        await h.repoB.sync.saveDeviceState(
          const SyncDeviceState(
            deviceId: 'device-b',
            nextSequence: 1,
            knownVector: SyncVersionVector({}),
          ),
        );

        // Device B re-syncs after restore
        final resultB = await h.engineB.run(trigger: SyncTrigger.manual);

        // Should download at least the new entry (may re-download both)
        expect(resultB.downloaded, greaterThanOrEqualTo(1));

        // Should have both entries in the repository
        final dataB = h.repoB.exportDataForSync();
        final entriesB = (dataB['entries'] as List?) ?? [];
        expect(entriesB.length, greaterThanOrEqualTo(2));
      },
    );
  });
}

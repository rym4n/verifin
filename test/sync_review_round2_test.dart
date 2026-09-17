import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:verifin/app/backup/backup_settings.dart';
import 'package:verifin/app/backup/webdav_config.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/sync/sync_conflict.dart';
import 'package:verifin/app/sync/sync_coordinator.dart';
import 'package:verifin/app/sync/sync_engine.dart';
import 'package:verifin/app/sync/sync_models.dart';
import 'package:verifin/app/sync/sync_wire.dart';
import 'package:verifin/app/sync/sync_codec.dart';
import 'package:verifin/app/sync/webdav_sync_transport_stub.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'sync_review_regression_test.dart' show FailingPreferenceStore;
import 'support/sync_test_harness.dart';

class FailedFirstDownload extends StubWebdavSyncTransport {
  bool fail = true;
  @override
  Future<Uint8List> downloadSyncFile(
    WebdavConfig config,
    String path, {
    required int maxBytes,
  }) async {
    if (fail && path.endsWith('.vfsync')) {
      fail = false;
      throw StateError('injected first GET failure');
    }
    return super.downloadSyncFile(config, path, maxBytes: maxBytes);
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

  test(
    'R2-1 resolving old aggregate never overwrites a later local edit of another entity',
    () async {
      await device.addExpense('conflict', 10);
      final remote = SyncTestRemote('remote');
      await transport.simulateRemoteBatch('remote', 1, [
        remote.expense('conflict', 20, batchId: 'batch'),
        remote.expense('later-local', 20, batchId: 'batch'),
      ]);
      await device.engine.run(trigger: SyncTrigger.manual);
      final first = (await device.engine.conflicts()).single;
      await device.addExpense('later-local', 99);
      await device.engine.resolveConflict(
        first.id,
        ConflictResolution.keepRemote,
      );
      expect(
        device.entries.singleWhere((e) => e.id == 'later-local').amount,
        99,
      );
      expect(
        (await device.engine.conflicts()).any(
          (c) => c.entity.id == 'later-local',
        ),
        isTrue,
      );
    },
  );

  test(
    'R2-1 saved choice becomes invalid after a newer local edit of that entity',
    () async {
      await device.addExpense('one', 10);
      await device.addExpense('two', 10);
      final remote = SyncTestRemote('remote');
      await transport.simulateRemoteBatch('remote', 1, [
        remote.expense('one', 20, batchId: 'batch'),
        remote.expense('two', 20, batchId: 'batch'),
      ]);
      await device.engine.run(trigger: SyncTrigger.manual);
      final conflicts = await device.engine.conflicts();
      await device.engine.resolveConflict(
        conflicts.singleWhere((c) => c.entity.id == 'one').id,
        ConflictResolution.keepRemote,
      );
      await device.editExpense('one', 77);
      await device.engine.resolveConflict(
        conflicts.singleWhere((c) => c.entity.id == 'two').id,
        ConflictResolution.keepRemote,
      );
      expect(device.entries.singleWhere((e) => e.id == 'one').amount, 77);
      expect(
        (await device.engine.conflicts()).any((c) => c.entity.id == 'one'),
        isTrue,
      );
    },
  );

  test(
    'R2-2 failed prepared preference cannot overwrite a subsequent successful local save',
    () async {
      final store = FailingPreferenceStore();
      final controller = await VeriFinController.create(
        store,
        repository: device.repository,
      );
      addTearDown(controller.dispose);
      final engine = SyncEngine(
        repository: device.repository.sync,
        controller: controller,
        transport: transport,
        config: syncTestConfig,
      );
      final remote = SyncTestRemote('remote');
      final event = SyncEvent(
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
        batchId: 'theme',
        keyFingerprint: 'none',
      );
      final shadow = await device.repository.sync.loadShadow();
      shadow.remove(event.entity);
      await device.repository.sync.saveShadow(shadow);
      await transport.simulateRemoteBatch('remote', 1, [event]);
      store.failTheme = true;
      expect(
        (await engine.run(trigger: SyncTrigger.manual)).errorCode,
        isNotNull,
      );
      store.failTheme = false;
      controller.setThemePreference(ThemePreference.light);
      await controller.flushPendingWrites();
      try {
        await controller.applySyncPreferenceJournal();
      } catch (_) {
        /* A visible unresolved conflict is allowed; overwriting is not. */
      }
      expect(controller.themePreference, ThemePreference.light);
      expect(store.read('verifin.theme.v1'), 'light');
      expect(await device.repository.sync.loadPendingBatches(), isNotEmpty);
      final conflicts = await device.repository.sync.loadConflicts();
      expect(conflicts, hasLength(1));
      expect(
        (await device.repository.sync.loadOutbox()).any(
          (r) =>
              r.event?.entity.type == 'themePreference' &&
              r.event?.payload == 'light',
        ),
        isTrue,
      );
      await engine.resolveConflict(
        conflicts.single.id,
        ConflictResolution.keepLocal,
      );
      expect(controller.themePreference, ThemePreference.light);
      expect(await device.repository.sync.loadPendingKvJournal(), isEmpty);
      expect(await device.repository.sync.loadPendingBatches(), isEmpty);
    },
  );

  test(
    'R2-3 attachment event carries a blob reference without dataUrl',
    () async {
      await device.addExpense('entry', 10);
      device.controller.addAttachment(
        'entry',
        'data:image/png;base64,AQIDBA==',
      );
      await device.controller.waitForPendingWrites();
      await device.tracker!.reconcile();
      expect(
        (await device.engine.run(trigger: SyncTrigger.manual)).errorCode,
        isNull,
      );
      final events = transport.files.entries
          .where((f) => f.key.endsWith('.vfsync'))
          .map((f) => jsonDecode(utf8.decode(f.value)) as Map)
          .where((e) => (e['entity'] as Map)['type'] == 'attachments');
      final payload = events.single['payload'] as Map;
      expect(payload.containsKey('dataUrl'), isFalse);
      expect(payload['blobHash'], isA<String>());
    },
  );

  test('R2-3 legacy inline attachment event remains readable', () {
    const dataUrl = 'data:image/png;base64,AQIDBA==';
    final payload = <String, Object?>{
      'id': 'legacy-attachment',
      'entryId': 'legacy-entry',
      'dataUrl': dataUrl,
    };
    final event = SyncEvent(
      protocolVersion: syncProtocolVersion,
      operationId: 'legacy-operation',
      version: const SyncVersion(
        dot: SyncDot(deviceId: 'legacy-device', sequence: 1),
        context: SyncVersionVector(<String, int>{}),
        logicalTime: 1,
      ),
      entity: const SyncEntityKey(
        scope: 'ledger',
        type: 'attachments',
        id: 'legacy-attachment',
      ),
      operation: SyncOperationKind.upsert,
      payloadHash: computeSyncPayloadHash(payload),
      payload: payload,
      batchId: 'legacy-batch',
      keyFingerprint: 'none',
    );

    final materialized = materializeSyncEvent(event, const {});

    expect(materialized.payload, payload);
    expect(materialized.payloadHash, event.payloadHash);
  });

  test(
    'R2-4 failed initial join resumes final-state reconstruction after process restart',
    () async {
      final failing = FailedFirstDownload();
      final joining = await SyncTestDevice.create(
        deviceId: 'join',
        transport: failing,
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
      await failing.simulateRemoteBatch('remote', 1, [a]);
      await failing.simulateRemoteBatch('remote', 3, [c]);
      await failing.simulateRemoteBatch('remote', 2, [b]);
      await expectLater(
        joining.engine.initializeFromRestoredData(),
        throwsA(anything),
      );
      final fresh = SyncEngine(
        repository: joining.repository.sync,
        controller: joining.controller,
        transport: failing,
        config: syncTestConfig,
        clock: joining.clock,
      );
      await fresh.initializeFromRestoredData();
      await fresh.run(trigger: SyncTrigger.manual);
      expect(await fresh.conflicts(), isEmpty);
      expect(joining.entries.single.amount, 30);
    },
  );

  for (final invalid in ['occurredAt', 'type']) {
    test(
      'R2-5 strict entry rejects invalid $invalid before any business write',
      () async {
        final remote = SyncTestRemote('remote');
        final original = remote.expense('invalid', 10, batchId: 'invalid');
        final payload = {
          ...original.payload as Map<String, Object?>,
          invalid: 'definitely-invalid',
        };
        final event = SyncEvent(
          protocolVersion: original.protocolVersion,
          operationId: original.operationId,
          version: original.version,
          entity: original.entity,
          operation: original.operation,
          payloadHash: computeSyncPayloadHash(payload),
          payload: payload,
          batchId: original.batchId,
          keyFingerprint: original.keyFingerprint,
        );
        await transport.simulateRemoteBatch('remote', 1, [event]);
        expect(
          (await device.engine.run(trigger: SyncTrigger.manual)).errorCode,
          'validation',
        );
        expect(device.entries, isEmpty);
        expect(await device.db.db.query('sync_applied_ops'), isEmpty);
      },
    );
  }

  test(
    'R2-6 budget period setters trigger the real coordinator debounce',
    () async {
      final run = Completer<void>();
      final coordinator = SyncCoordinator(
        getTransportMode: () => BackupTransportMode.autoSync,
        debounceDuration: const Duration(milliseconds: 5),
        runSync: (trigger) async {
          if (!run.isCompleted) run.complete();
          return const SyncRunResult(
            uploaded: 0,
            downloaded: 0,
            conflicts: 0,
            pending: 0,
          );
        },
      );
      addTearDown(coordinator.dispose);
      device.controller.onSyncChanged = coordinator.onLocalMutation;
      device.controller.setBudgetCycleStartDay(8);
      device.controller.setBudgetPeriodKind(BudgetPeriodKind.year);
      await expectLater(
        run.future.timeout(const Duration(milliseconds: 150)),
        completes,
      );
    },
  );

  test(
    'R2-6 due recurring generation triggers coordinator after the aggregate is persisted',
    () async {
      device.controller.addRecurringRule(
        RecurringRule(
          id: 'due',
          bookId: 'default',
          type: EntryType.expense,
          amount: 10,
          categoryId: 'dining',
          accountId: '',
          note: '',
          frequency: RecurringFrequency.daily,
          startDate: DateTime(2026, 9, 16),
          nextRunDate: DateTime(2026, 9, 16),
        ),
      );
      await device.controller.waitForPendingWrites();
      final run = Completer<void>();
      final coordinator = SyncCoordinator(
        getTransportMode: () => BackupTransportMode.autoSync,
        debounceDuration: const Duration(milliseconds: 5),
        runSync: (trigger) async {
          expect(await device.repository.loadEntries(), hasLength(1));
          if (!run.isCompleted) run.complete();
          return const SyncRunResult(
            uploaded: 0,
            downloaded: 0,
            conflicts: 0,
            pending: 0,
          );
        },
      );
      addTearDown(coordinator.dispose);
      device.controller.onSyncChanged = coordinator.onLocalMutation;
      expect(
        await device.controller.applyDueRecurring(DateTime(2026, 9, 16)),
        1,
      );
      await expectLater(
        run.future.timeout(const Duration(milliseconds: 200)),
        completes,
      );
    },
  );

  for (final passphrase in ['', 'secret']) {
    test(
      'R2-3 near-limit ${passphrase.isEmpty ? 'plaintext' : 'encrypted'} attachment crosses devices in bounded chunks',
      () async {
        const limits = SyncWireLimits(
          maxAttachmentBytes: 8192,
          maxEnvelopeBytes: 4096,
        );
        final receiver = await SyncTestDevice.create(
          deviceId: 'receiver',
          transport: transport,
          trackLocalChanges: false,
        );
        addTearDown(receiver.dispose);
        final raw = Uint8List.fromList(
          List.generate(
            limits.maxAttachmentBytes,
            (i) => (i * 37 + i ~/ 256) % 256,
          ),
        );
        final dataUrl = 'data:image/png;base64,${base64Encode(raw)}';
        await device.addExpense('large', 10);
        device.controller.addAttachment('large', dataUrl);
        await device.controller.waitForPendingWrites();
        await device.tracker!.reconcile();
        final errors = <Object>[];
        final sender = SyncEngine(
          repository: device.repository.sync,
          controller: device.controller,
          transport: transport,
          config: syncTestConfig,
          clock: device.clock,
          passphrase: passphrase,
          wireLimits: limits,
          onError: errors.add,
        );
        expect(
          (await sender.run(trigger: SyncTrigger.manual)).errorCode,
          isNull,
        );
        expect(
          transport.files.keys.where((p) => p.endsWith('.blob')).length,
          greaterThan(1),
        );
        expect(
          transport.files.values.every(
            (bytes) => bytes.length <= limits.maxEnvelopeBytes,
          ),
          isTrue,
        );
        final engine = SyncEngine(
          repository: receiver.repository.sync,
          controller: receiver.controller,
          transport: transport,
          config: syncTestConfig,
          clock: receiver.clock,
          passphrase: passphrase,
          wireLimits: limits,
          onError: errors.add,
        );
        expect(
          (await engine.run(trigger: SyncTrigger.manual)).errorCode,
          isNull,
          reason: errors.toString(),
        );
        expect(
          (await receiver.repository.loadAttachments()).single.dataUrl,
          dataUrl,
        );
      },
    );
  }

  test(
    'R2-5 unknown rate currency and mismatched book base reject the whole batch',
    () async {
      final remote = SyncTestRemote('remote');
      for (final code in ['ZZZ', 'USD']) {
        final payload = ExchangeRate(
          id: 'rate-$code',
          bookId: 'default',
          baseCurrencyCode: code == 'USD' ? 'EUR' : 'CNY',
          currencyCode: code,
          effectiveDate: DateTime(2026, 9, 16),
          rateToBase: 7,
          source: ExchangeRateSource.manual,
          createdAt: DateTime(2026, 9, 16),
          updatedAt: DateTime(2026, 9, 16),
        ).toJson();
        final event = SyncEvent(
          protocolVersion: syncProtocolVersion,
          operationId: remote.clock.nextOperationId(),
          version: remote.clock.nextVersion(),
          entity: SyncEntityKey(
            scope: 'ledger',
            type: 'exchangeRates',
            id: 'rate-$code',
          ),
          operation: SyncOperationKind.upsert,
          payloadHash: computeSyncPayloadHash(payload),
          payload: payload,
          batchId: 'rate-$code',
          keyFingerprint: 'none',
        );
        await transport.simulateRemoteBatch(
          'remote',
          event.version.dot.sequence,
          [event],
        );
        expect(
          (await device.engine.run(trigger: SyncTrigger.manual)).errorCode,
          'validation',
        );
        expect(await device.repository.loadExchangeRates(), isEmpty);
      }
    },
  );

  test(
    'I5 actual unknown event protocol is rejected without business or applied rows',
    () async {
      final remote = SyncTestRemote('remote');
      final original = remote.expense('unknown', 10, batchId: 'unknown');
      final invalid = SyncEvent(
        protocolVersion: '999',
        operationId: original.operationId,
        version: original.version,
        entity: original.entity,
        operation: original.operation,
        payloadHash: original.payloadHash,
        payload: original.payload,
        batchId: original.batchId,
        keyFingerprint: 'none',
      );
      await transport.simulateRemoteBatch('remote', 1, [invalid]);
      expect(
        (await device.engine.run(trigger: SyncTrigger.manual)).errorCode,
        'protocol',
      );
      expect(device.entries, isEmpty);
      expect(await device.db.db.query('sync_applied_ops'), isEmpty);
    },
  );

  test(
    'I5 wrong encrypted fingerprint is rejected before business or applied writes',
    () async {
      final remote = SyncTestRemote('remote');
      final event = remote.expense('fingerprint', 10, batchId: 'fingerprint');
      await transport.simulateRemoteBatch('remote', 1, [event]);
      final path = transport.files.keys.singleWhere(
        (p) => p.endsWith('.vfsync'),
      );
      final envelope = await const SyncCodec(
        passphrase: 'secret',
      ).encodeValue(event.toJson(), syncProtocolVersion);
      envelope['keyFingerprint'] = 'wrong-fingerprint';
      transport.files[path] = syncJsonBytes(envelope);
      device.engine.updatePassphrase('secret');
      expect(
        (await device.engine.run(trigger: SyncTrigger.manual)).errorCode,
        'auth',
      );
      expect(device.entries, isEmpty);
      expect(await device.db.db.query('sync_applied_ops'), isEmpty);
    },
  );
}

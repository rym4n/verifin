import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:verifin/app/backup/webdav_config.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/sync/sync_change_tracker.dart';
import 'package:verifin/app/sync/sync_clock.dart';
import 'package:verifin/app/sync/sync_engine.dart';
import 'package:verifin/app/sync/sync_models.dart';
import 'package:verifin/app/sync/sync_projection.dart';
import 'package:verifin/app/sync/webdav_sync_transport_stub.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/data/app_database.dart';
import 'package:verifin/data/ledger_repository.dart';
import 'package:verifin/local_storage/local_storage.dart';

void main() {
  setUpAll(sqfliteFfiInit);
  late AppDatabase db;
  late SqliteLedgerRepository repository;
  late VeriFinController controller;
  late StubWebdavSyncTransport transport;
  late SyncEngine engine;
  late SyncClock remote;
  setUp(() async {
    db = await AppDatabase.open(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    repository = SqliteLedgerRepository(db);
    controller = await VeriFinController.create(
      LocalKeyValueStore(),
      repository: repository,
    );
    await controller.waitForPendingWrites();
    transport = StubWebdavSyncTransport();
    remote = SyncClock.createWithDeviceId('remote');
    engine = SyncEngine(
      repository: repository.sync,
      controller: controller,
      transport: transport,
      config: const WebdavConfig(
        url: 'https://example.com',
        username: 'u',
        password: 'p',
      ),
      remoteApply: controller.runRemoteApply,
    );
  });
  tearDown(() async {
    controller.dispose();
    await db.close();
  });

  SyncEvent event(
    String type,
    String id,
    Object? payload, {
    String batch = 'batch',
    bool deleted = false,
  }) => SyncEvent(
    protocolVersion: syncProtocolVersion,
    operationId: remote.nextOperationId(),
    version: remote.nextVersion(),
    entity: SyncEntityKey(
      scope: type == 'ledgerBook' || type == 'monthlyBudgets'
          ? 'global'
          : 'ledger',
      type: type,
      id: id,
    ),
    operation: deleted ? SyncOperationKind.delete : SyncOperationKind.upsert,
    payloadHash: computeSyncPayloadHash(payload),
    payload: payload,
    batchId: batch,
    keyFingerprint: 'test',
  );

  List<SyncEvent> aggregate({bool invalid = false}) {
    final data = controller.exportDataForSync();
    final book = Map<String, Object?>.from(
      (data['ledgerBooks'] as List).first as Map,
    )..['id'] = 'remote-book';
    final category =
        Map<String, Object?>.from((data['categories'] as List).first as Map)
          ..['id'] = 'remote-category'
          ..['bookId'] = 'remote-book'
          ..['parentId'] = null;
    final account = Account(
      id: 'remote-account',
      bookId: 'remote-book',
      name: 'Remote',
      type: AccountType.cash,
      groupId: null,
      initialBalance: 0,
      iconCode: 'cash',
      note: '',
      includeInAssets: true,
      hidden: false,
    ).toJson();
    final entry = LedgerEntry(
      id: 'remote-entry',
      bookId: 'remote-book',
      type: EntryType.expense,
      amount: 23,
      categoryId: 'remote-category',
      accountId: invalid ? 'missing-account' : 'remote-account',
      note: '',
      occurredAt: DateTime(2026, 9, 16),
    ).toJson();
    return [
      event('entries', 'remote-entry', entry),
      event('accounts', 'remote-account', account),
      event('ledgerBook', 'remote-book', book),
      event('categories', 'remote-category', category),
      event('monthlyBudgets', 'remote-book:2026-09', 500),
    ];
  }

  test(
    'remote complete aggregate is immediately visible in SQLite and Controller without echo',
    () async {
      final tracker = SyncChangeTracker(
        controller: controller,
        repository: repository.sync,
        clock: SyncClock.createWithDeviceId('local'),
      );
      controller.syncChangeTracker = tracker;
      await tracker.reconcile(alignShadowOnly: true);
      await transport.simulateRemoteBatch('remote', 1, aggregate());
      final result = await engine.run(trigger: SyncTrigger.manual);
      expect(result.errorCode, isNull);
      expect((await repository.loadEntries()).single.id, 'remote-entry');
      expect(
        ((controller.exportDataForSync()['entries'] as List).single
            as Map)['id'],
        'remote-entry',
      );
      expect(
        (await repository.loadMonthlyBudgets())['remote-book:2026-09'],
        500,
      );
      await tracker.reconcile();
      expect(await repository.sync.loadOutbox(), isEmpty);
    },
  );

  test(
    'invalid reference rejects the whole aggregate and metadata without advancing scan',
    () async {
      await transport.simulateRemoteBatch(
        'remote',
        1,
        aggregate(invalid: true),
      );
      final result = await engine.run(trigger: SyncTrigger.manual);
      expect(result.errorCode, isNotNull);
      expect(await repository.loadEntries(), isEmpty);
      expect(
        (await repository.loadBooks()).any((b) => b.id == 'remote-book'),
        isFalse,
      );
      expect(await db.db.query('sync_applied_ops'), isEmpty);
      expect(await db.db.query('sync_entity_versions'), isEmpty);
      expect((await repository.sync.loadScanState()).lastSuccess, isNull);
    },
  );

  test('remote tombstone removes the business entry', () async {
    await transport.simulateRemoteBatch('remote', 1, aggregate());
    expect((await engine.run(trigger: SyncTrigger.manual)).errorCode, isNull);
    expect(await repository.loadEntries(), hasLength(1));
    await transport.simulateRemoteBatch('remote', 6, [
      event('entries', 'remote-entry', null, batch: 'delete', deleted: true),
    ]);
    expect((await engine.run(trigger: SyncTrigger.manual)).errorCode, isNull);
    expect(await repository.loadEntries(), isEmpty);
    expect(controller.exportDataForSync()['entries'], isEmpty);
  });

  test('manifest order cannot assign an event to a different batch', () async {
    final first = aggregate();
    final nextEntry = {
      ...first.first.payload as Map<String, Object?>,
      'id': 'second-entry',
    };
    final later = event('entries', 'second-entry', nextEntry, batch: 'later');
    // The later batch is listed first. Earlier code assigned the first N files
    // to whichever manifest happened to be listed first.
    await transport.simulateRemoteBatch('remote', 6, [later]);
    await transport.simulateRemoteBatch(
      'remote',
      1,
      first,
      includeCommit: false,
    );
    final result = await engine.run(trigger: SyncTrigger.manual);
    expect(result.errorCode, 'validation');
    expect(await repository.loadEntries(), isEmpty);
    expect(await db.db.query('sync_applied_ops'), isEmpty);
  });

  test(
    'SQLite metadata failure rolls back the complete business transaction',
    () async {
      await db.db.execute(
        "CREATE TRIGGER fail_remote BEFORE INSERT ON sync_applied_ops BEGIN SELECT RAISE(ABORT, 'injected metadata failure'); END",
      );
      await transport.simulateRemoteBatch('remote', 1, aggregate());
      expect(
        (await engine.run(trigger: SyncTrigger.manual)).errorCode,
        isNotNull,
      );
      expect(await repository.loadEntries(), isEmpty);
      expect(
        (await repository.loadBooks()).any((b) => b.id == 'remote-book'),
        isFalse,
      );
      expect(await db.db.query('sync_entity_versions'), isEmpty);
      expect(await db.db.query('sync_shadow'), isEmpty);
    },
  );

  test(
    'every whitelisted preference is materialized and same-key fragments survive one batch',
    () async {
      final current = controller.exportDataForSync();
      final prefs = <String, Object?>{
        'activeBookId': 'remote-book',
        'profile': {...current['profile'] as Map, 'nickname': 'Remote'},
        'themePreference': 'dark',
        'assetCoverUrl': 'local-cover',
        'hapticsEnabled': false,
        'assetAccountViewMode': 'group',
        'collapsedAssetSections': ['remote-book:group:none'],
        'assetAccountOrders': {
          'remote-book:group:none': ['remote-account'],
        },
        'assetSectionOrders': {
          'remote-book:group': ['none', 'cash'],
        },
        'homePanels': [(current['homePanels'] as List).first],
        'reportPanels': [(current['reportPanels'] as List).first],
        'defaultAccountIds': {'remote-book': 'remote-account'},
        'fabActionMode': 'ai',
        'amountForceTwoDecimals': true,
        'currencyFractionStyle': 'standard',
        'moneyUnitStyle': 'code',
        'hideUnitInSingleCurrency': false,
        'autoSuggestEnabled': false,
        'showRunningBalance': true,
        'homeTrendConfig': current['homeTrendConfig'],
        'budgetCycleStartDays': {'default': 3, 'remote-book': 7},
        'budgetPeriodKinds': {'default': 'year', 'remote-book': 'year'},
      };
      final events = aggregate();
      for (final item in SyncProjection.fromExportData(prefs).entities.values) {
        events.add(
          SyncEvent(
            protocolVersion: syncProtocolVersion,
            operationId: remote.nextOperationId(),
            version: remote.nextVersion(),
            entity: item.key,
            operation: SyncOperationKind.upsert,
            payloadHash: item.payloadHash,
            payload: item.payload,
            batchId: 'batch',
            keyFingerprint: 'none',
          ),
        );
      }
      await transport.simulateRemoteBatch('remote', 1, events);
      expect((await engine.run(trigger: SyncTrigger.manual)).errorCode, isNull);
      final actual = controller.exportDataForSync();
      for (final key in prefs.keys.where(
        (k) => k != 'homePanels' && k != 'reportPanels',
      )) {
        expect(actual[key], prefs[key], reason: key);
      }
      expect(controller.themePreferenceListenable.value, ThemePreference.dark);
      expect(await repository.sync.loadPendingKvJournal(), isEmpty);
    },
  );

  test(
    'local async save waits through remote apply and preserves both changes',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      final apply = controller.runRemoteApply(() async {
        entered.complete();
        await release.future;
      });
      await entered.future;
      var finished = false;
      final save = controller
          .saveProfileDraft(
            const UserProfile(
              nickname: 'Local after remote',
              bio: '',
              avatarDataUrl: '',
            ),
          )
          .then((value) {
            finished = true;
            return value;
          });
      await Future<void>.delayed(Duration.zero);
      expect(finished, isFalse);
      release.complete();
      await apply;
      expect(await save, isTrue);
      expect(
        (controller.exportDataForSync()['profile'] as Map)['nickname'],
        'Local after remote',
      );
    },
  );

  test(
    'new tracker reconciles changes persisted before process death',
    () async {
      final clock = SyncClock.createWithDeviceId('local');
      final first = SyncChangeTracker(
        controller: controller,
        repository: repository.sync,
        clock: clock,
      );
      await first.reconcile(alignShadowOnly: true);
      first.dispose();
      controller.addEntry(
        LedgerEntry(
          id: 'offline',
          bookId: controller.activeBook.id,
          type: EntryType.expense,
          amount: 9,
          categoryId: 'dining',
          accountId: '',
          note: '',
          occurredAt: DateTime(2026, 9, 16),
        ),
      );
      await controller.waitForPendingWrites();
      final restarted = SyncChangeTracker(
        controller: controller,
        repository: repository.sync,
        clock: SyncClock.createWithDeviceId('local'),
      );
      await restarted.reconcile();
      expect(
        (await repository.sync.loadOutbox()).any(
          (r) => r.event?.entity.id == 'offline',
        ),
        isTrue,
      );
      restarted.dispose();
    },
  );
}

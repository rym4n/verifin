import 'dart:io';
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

const syncTestConfig = WebdavConfig(
  url: 'https://sync.test.example/dav',
  username: 'sync-test',
  password: 'sync-test',
);

/// A production-shaped device: its data is owned by SQLite and only mutated
/// through [VeriFinController]. The shared transport is the only test double.
class SyncTestDevice {
  SyncTestDevice._({
    required this.db,
    required this.repository,
    required this.controller,
    required this.clock,
    required this.tracker,
    required this.engine,
    required this.directory,
  });

  final AppDatabase db;
  final SqliteLedgerRepository repository;
  final VeriFinController controller;
  final SyncClock clock;
  final SyncChangeTracker? tracker;
  final SyncEngine engine;
  final Directory directory;
  Object? lastSyncError;

  static Future<SyncTestDevice> create({
    required String deviceId,
    required StubWebdavSyncTransport transport,
    bool trackLocalChanges = true,
    Directory? snapshotTempRoot,
  }) async {
    final directory = Directory.systemTemp.createTempSync(
      'verifin-sync-device-',
    );
    final db = await AppDatabase.open(
      factory: databaseFactoryFfi,
      path: '${directory.path}/ledger.db',
    );
    final repository = SqliteLedgerRepository(db);
    final controller = await VeriFinController.create(
      LocalKeyValueStore(),
      repository: repository,
    );
    await controller.waitForPendingWrites();
    final clock = SyncClock.createWithDeviceId(deviceId);
    final tracker = trackLocalChanges
        ? SyncChangeTracker(
            controller: controller,
            repository: repository.sync,
            clock: clock,
          )
        : null;
    if (tracker != null) {
      controller.syncChangeTracker = tracker;
      await tracker.reconcile(alignShadowOnly: true);
    }
    late SyncTestDevice device;
    final engine = SyncEngine(
      repository: repository.sync,
      transport: transport,
      controller: controller,
      config: syncTestConfig,
      clock: clock,
      snapshotTempRoot: snapshotTempRoot,
      onError: (error) => device.lastSyncError = error,
    );
    device = SyncTestDevice._(
      db: db,
      repository: repository,
      controller: controller,
      clock: clock,
      tracker: tracker,
      engine: engine,
      directory: directory,
    );
    return device;
  }

  List<LedgerEntry> get entries => controller.entries;

  Future<void> addExpense(String id, double amount) async {
    controller.addEntry(
      LedgerEntry(
        id: id,
        bookId: controller.activeBook.id,
        type: EntryType.expense,
        amount: amount,
        categoryId: 'dining',
        accountId: '',
        note: 'sync test $id',
        occurredAt: DateTime.utc(2026, 9, 16),
      ),
    );
    await controller.waitForPendingWrites();
    await tracker!.reconcile();
  }

  Future<void> editExpense(String id, double amount) async {
    final entry = entries.singleWhere((item) => item.id == id);
    controller.updateEntry(entry.copyWith(amount: amount, baseAmount: amount));
    await controller.waitForPendingWrites();
    await tracker!.reconcile();
  }

  Future<void> deleteExpense(String id) async {
    if (tracker == null) throw StateError('local change tracking is disabled');
    final deleted = await controller.deleteEntry(id);
    if (!deleted) throw StateError('test entry was not deleted: $id');
    await controller.waitForPendingWrites();
    await tracker!.reconcile();
  }

  Future<void> dispose() async {
    controller.dispose();
    await db.close();
    directory.deleteSync(recursive: true);
  }
}

class SyncTestRemote {
  SyncTestRemote(this.deviceId)
    : clock = SyncClock.createWithDeviceId(deviceId);

  final String deviceId;
  final SyncClock clock;

  SyncEvent expense(String id, double amount, {required String batchId}) {
    final entry = LedgerEntry(
      id: id,
      bookId: defaultLedgerBookId,
      type: EntryType.expense,
      amount: amount,
      categoryId: 'dining',
      accountId: '',
      note: 'remote sync test $id',
      occurredAt: DateTime(2026, 9, 16),
    );
    final payload = SyncProjection.fromExportData({
      'entries': [entry.toJson()],
    }).entities.values.single.payload;
    return SyncEvent(
      protocolVersion: syncProtocolVersion,
      operationId: clock.nextOperationId(),
      version: clock.nextVersion(),
      entity: SyncEntityKey(scope: 'ledger', type: 'entries', id: id),
      operation: SyncOperationKind.upsert,
      payloadHash: computeSyncPayloadHash(payload),
      payload: payload,
      batchId: batchId,
      keyFingerprint: 'sync-test',
    );
  }

  SyncEvent delete(String id, {required String batchId}) => SyncEvent(
    protocolVersion: syncProtocolVersion,
    operationId: clock.nextOperationId(),
    version: clock.nextVersion(),
    entity: SyncEntityKey(scope: 'ledger', type: 'entries', id: id),
    operation: SyncOperationKind.delete,
    payloadHash: computeSyncPayloadHash(null),
    payload: null,
    batchId: batchId,
    keyFingerprint: 'sync-test',
  );
}

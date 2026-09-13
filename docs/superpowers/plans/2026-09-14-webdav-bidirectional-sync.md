# WebDAV 双向同步实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在不新增服务端的前提下，让多个设备使用同一 WebDAV 配置，对当前自动备份范围内的数据进行可合并的前台双向同步，并在并发修改时保留冲突版本供用户选择。

**Architecture:** 保留现有 `BackupService`、`BackupCoordinator` 和整包手动恢复协议；新增独立的同步协议、SQLite 同步元数据和本地 outbox。设备把实体级变更作为不可变事件追加到 WebDAV，使用 dotted version vector 判断因果关系，远端事件在本地合并后以 SQLite 事务和可恢复 KV journal 提交。同步目录只保存事件、批次提交标记和内容寻址附件，不使用“最新快照”互相覆盖。

**Tech Stack:** Flutter/Dart、现有 `sqflite`/`sqflite_common_ffi`、`SharedPreferences` 封装的 `LocalKeyValueStore`、`dart:io HttpClient` WebDAV、现有 AES-GCM/PBKDF2 备份加密、Flutter widget tests 和 ffi SQLite tests。

**Spec:** `docs/superpowers/specs/2026-09-13-webdav-bidirectional-sync-design.md`

## Global Constraints

- 只使用现有 WebDAV 地址、账号和密码，不新增同步服务器、账号、成员管理、邀请或权限系统。
- 自动同步与“自动上传到 WebDAV”互斥；规范值为单一 `backupTransportMode`，手动上传和手动恢复继续可用。
- 同步白名单必须逐键覆盖当前 `exportDataJson()`：`ledgerBooks`、`activeBookId`、`entries`、`accounts`、`accountGroups`、`categories`、`tags`、`attachments`、`recurringRules`、`exchangeRates`、`monthlyBudgets`、`categoryBudgets`、`dailyBudgets`、`budgetCycleStartDays`、`profile`、`themePreference`、`assetCoverUrl`、`hapticsEnabled`、`assetAccountViewMode`、`collapsedAssetSections`、`assetAccountOrders`、`assetSectionOrders`、`homePanels`、`reportPanels`、`defaultAccountIds`、`fabActionMode`、`amountForceTwoDecimals`、`currencyFractionStyle`、`moneyUnitStyle`、`hideUnitInSingleCurrency`、`autoSuggestEnabled`、`showRunningBalance`、`homeTrendConfig`、`userWidgetDefinitions`。
- 当前备份排除的 WebDAV/AI 凭证、备份口令、应用锁、备份目录、日志、AI 聊天历史和设备授权不进入同步事件；备份口令本身不传输。
- 不能把现有整包恢复改成自动合并；不能按自动备份 retention 清理同步事件；不能依赖 ETag/If-Match/LOCK。
- 并发判断使用 dotted version vector；HLC 仅用于展示和稳定排序，不能用设备墙上时间决定覆盖。
- 删除必须写 tombstone；远端应用不得再次生成本地 outbox；退款派生字段 `refundedBaseAmount` 不作为独立竞争字段，应用聚合后统一重算。
- 任何远端批次必须通过金额、引用、schema 和附件 hash 校验后，才以事务提交；KV 变更通过可恢复 journal 与 SQLite 状态协调。
- 新增用户可见文案必须同步修改 `lib/l10n/app_zh.arb` 和 `lib/l10n/app_en.arb`，不得手改生成文件；界面使用现有 `VeriPage`、`VeriHeader`、`VeriCard`、`VeriFeedbackHost` 和 `showConfirmDialog`。
- 每个任务完成后运行其列出的测试并单独提交；最终必须运行 `dart format .`、`flutter analyze`、`flutter test`，Android/网络/附件改动还要列出 release/R8 真机验收项。

## File Boundaries

### New synchronization modules

- `lib/app/sync/sync_models.dart`: 事件、批次、实体键、版本向量、冲突和同步结果的纯数据类型。
- `lib/app/sync/sync_clock.dart`: `deviceId`、sequence、operationId、HLC 和 dotted version vector 生成/比较。
- `lib/app/sync/sync_codec.dart`: 同步事件/批次 envelope 的 JSON、hash 和加密编解码；不复用备份文件格式判断。
- `lib/app/sync/sync_projection.dart`: 将导出白名单投影为规范化实体 map，计算 shadow 差异和显式 tombstone。
- `lib/app/sync/sync_store.dart`: 同步元数据读写端口和 SQLite 实现适配。
- `lib/app/sync/sync_engine.dart`: outbox 上传、远端扫描、解码、合并、pending、事务应用和状态结果。
- `lib/app/sync/sync_coordinator.dart`: 应用生命周期/本地变更触发的防抖、互斥和错误回调。
- `lib/app/sync/sync_conflict.dart`: 冲突查询、版本选择和决议事件逻辑。

### Existing files to extend

- `lib/data/app_database.dart`: schema version、同步表和迁移。
- `lib/data/ledger_repository.dart`、`test/support/in_memory_ledger_repository.dart`: 同步元数据/批量远端应用接口。
- `lib/app/veri_fin_controller.dart`、`lib/app/veri_fin_controller_state.dart`、`lib/app/veri_fin_controller_ops.dart`: 同步配置、projection hook、远端应用入口和 KV 变更追踪。
- `lib/app/backup/backup_settings.dart`、`lib/app/backup/webdav_config.dart`: 传输模式和旧配置迁移。
- `lib/app/backup/webdav_client.dart`、`lib/app/backup/webdav_client_io.dart`、`lib/app/backup/webdav_client_stub.dart`: 同步目录创建、逐级 PROPFIND、分段 URL、幂等写和流式附件传输。
- `lib/pages/data_management_page.dart`、`lib/pages/data_management_dialogs.dart`、新增 `lib/pages/sync_conflicts_page.dart`：设置、同步状态、恢复前置检查和冲突决议。
- `docs/dev/components.md`：登记新增冲突列表/卡片组件及其复用边界。
- `lib/main.dart`: 启动、回前台、变更防抖和同步协调器接线。
- `lib/l10n/app_zh.arb`、`lib/l10n/app_en.arb`：同步设置、状态、错误和冲突文案。
- `docs/dev/tech-decisions.md`、`docs/acceptance-checklist.md`、`README.md`、`CHANGELOG.md`：同步协议、范围和用户可见行为。

## Task 1: Define Protocol Types and Causal Clock

**Files:**
- Create: `lib/app/sync/sync_models.dart`
- Create: `lib/app/sync/sync_clock.dart`
- Create: `lib/app/sync/sync_codec.dart`
- Test: `test/sync_protocol_test.dart`

**Interfaces:**
- `enum SyncCausality { before, after, equal, concurrent }`
- `class SyncDot { const SyncDot({required String deviceId, required int sequence}); }`
- `class SyncVersionVector { const SyncVersionVector(Map<String, int> values); SyncCausality compare(SyncVersionVector other); SyncVersionVector merged(SyncVersionVector other); }`
- `class SyncVersion { const SyncVersion({required SyncDot dot, required SyncVersionVector context, required int logicalTime}); }`
- `class SyncEntityVersion { const SyncEntityVersion({required SyncVersion version, required String payloadHash, required Object? payload, required bool deleted, required String operationId}); }`
- `class SyncEntityKey { const SyncEntityKey({required String scope, required String type, required String id}); }`
- `enum SyncOperationKind { upsert, delete, resolve }`
- `class SyncEvent { const SyncEvent({required String protocolVersion, required String operationId, required SyncVersion version, required SyncEntityKey entity, required SyncOperationKind operation, required String payloadHash, required Object? payload, required String batchId, required String keyFingerprint}); Map<String, Object?> toJson(); static SyncEvent fromJson(Map<String, Object?> json); }`
- `class SyncBatchManifest { const SyncBatchManifest({required String batchId, required List<String> operationIds, required List<String> blobHashes, required String manifestHash}); }`
- `class SyncProjectedEntity { const SyncProjectedEntity({required SyncEntityKey key, required Object? payload, required String payloadHash}); }`
- `class SyncLocalMutation { const SyncLocalMutation({required SyncEntityKey entity, required SyncOperationKind operation, required Object? payload, required String batchId}); }`
- `class SyncDeviceState { const SyncDeviceState({required String deviceId, required int nextSequence, required SyncVersionVector knownVector}); }`
- `class SyncOutboxRecord { const SyncOutboxRecord({required String batchId, required String operationId, required String relativePath, required String payloadHash, required int retryCount}); }`
- `class SyncBatchRecord { const SyncBatchRecord({required String batchId, required List<SyncEvent> events, required SyncBatchManifest manifest}); }`
- `class SyncScanState { const SyncScanState({required Map<String, int> contiguousSequences, required Map<String, List<int>> gaps, required DateTime? lastSuccess, required String? lastErrorCode, required int retryCount}); }`
- `class SyncConflictRecord { const SyncConflictRecord({required String id, required SyncEntityKey entity, required SyncEntityVersion local, required SyncEntityVersion remote}); }`
- `class RemoteApplyPlan { const RemoteApplyPlan({required String batchId, required List<SyncEntityVersion> entityVersions, required List<String> appliedOperationIds, required Map<String, String> shadowHashes, required Map<String, String> kvJournalValues}); }`

- [ ] **Step 1: Write failing tests for vector comparison and codec round-trips**

```dart
test('dotted vectors distinguish causal and concurrent edits', () {
  const a = SyncVersionVector({'phone': 2, 'tablet': 1});
  const b = SyncVersionVector({'phone': 2, 'tablet': 2});
  const c = SyncVersionVector({'phone': 3, 'tablet': 1});
  expect(a.compare(b), SyncCausality.before);
  expect(b.compare(a), SyncCausality.after);
  expect(b.compare(c), SyncCausality.concurrent);
});

test('event JSON preserves operation, vector, batch and hash', () {
  final event = makeTestEvent();
  expect(SyncEvent.fromJson(event.toJson()), event);
});
```

- [ ] **Step 2: Run the focused tests and verify they fail**

Run: `flutter test test/sync_protocol_test.dart`

Expected: FAIL because the sync types and vector comparison are not defined.

- [ ] **Step 3: Implement immutable protocol types**

Implement strict JSON validation: reject missing protocol version, empty IDs, negative sequence, non-finite payload values, unknown operation kinds and mismatched payload hash. `SyncVersionVector.compare` must compare every key in the union; an equal vector is not concurrent. `SyncEvent` equality must include all serialized fields so deduplication tests are meaningful.

- [ ] **Step 4: Implement device clock helpers and encryption envelope shape**

Expose `SyncClock.nextVersion({required SyncVersionVector known})`, `SyncClock.nextOperationId()`, and `SyncClock.deviceId`. Define codec output as `{protocolVersion, keyFingerprint, nonce, ciphertext, payloadHash}` when a passphrase is present, and as `{protocolVersion, keyFingerprint: 'none', payload, payloadHash}` otherwise. The codec must never serialize the passphrase.

- [ ] **Step 5: Run tests, format, and commit**

Run: `dart format lib/app/sync test/sync_protocol_test.dart` and `flutter test test/sync_protocol_test.dart`

Expected: PASS. Commit with `git add lib/app/sync test/sync_protocol_test.dart && git commit -m "feat: define sync protocol types"`.

## Task 2: Add SQLite Sync Metadata and Repository Transactions

**Files:**
- Modify: `lib/data/app_database.dart`
- Modify: `lib/data/ledger_repository.dart`
- Modify: `test/support/in_memory_ledger_repository.dart`
- Test: `test/sync_repository_test.dart`, `test/migration_matrix_test.dart`, `test/repository_contract_test.dart`

**Interfaces:**
- `abstract interface class SyncRepository { Future<SyncDeviceState> loadDeviceState(); Future<void> saveDeviceState(SyncDeviceState state); Future<List<SyncOutboxRecord>> loadOutbox(); Future<void> enqueueBatch(SyncBatchRecord batch); Future<void> markBatchUploaded(String batchId); Future<void> applyRemoteBatch(RemoteApplyPlan plan); Future<SyncScanState> loadScanState(); Future<void> saveScanState(SyncScanState state); Future<List<SyncConflictRecord>> loadConflicts(); }`
- `SqliteLedgerRepository.sync` returns the production `SyncRepository`; `InMemoryLedgerRepository.sync` provides the same contract for widget tests.
- `RemoteApplyPlan` is defined in `lib/app/sync/sync_models.dart` and contains validated SQLite mutations, `sync_entity_versions`, `sync_applied_ops`, `sync_shadow` changes and KV journal rows. It is immutable and cannot contain an incomplete aggregate batch.

- [ ] **Step 1: Add migration tests for the complete metadata schema**

Add a migration assertion that the current schema includes `sync_device`, `sync_shadow`, `sync_entity_versions`, `sync_outbox`, `sync_applied_ops`, `sync_pending`, `sync_scan_state`, `sync_apply_journal`, and `sync_conflicts`, with primary keys that prevent duplicate `(device_id, sequence)` and duplicate `operation_id`.

- [ ] **Step 2: Run migration tests before implementation**

Run: `flutter test test/migration_matrix_test.dart test/sync_repository_test.dart`

Expected: FAIL because schema version 16 has no synchronization tables.

- [ ] **Step 3: Raise schema version and register migration**

In `AppDatabase`, raise `schemaVersion` to 17, append the tables in `_schemaCurrent`, and add a v16→v17 migration. Store vector/context as validated JSON text, payloads as encrypted envelope bytes/text, retry count and timestamps as integers, and conflict versions as separate rows rather than overwriting the current entity.

- [ ] **Step 4: Implement repository transaction methods**

Add an `_enqueueWrite`-protected method that applies `RemoteApplyPlan` to business tables and sync metadata in one SQLite transaction. Reject a plan when any operation is already applied with a different hash, when a tombstone regresses causality, or when an attachment/blob dependency is missing. Keep the existing `saveX` full-table contract unchanged.

- [ ] **Step 5: Mirror the contract in the in-memory repository**

Implement deterministic in-memory maps for device state, outbox, applied operations, pending batches, scan state and conflicts. Make `applyRemoteBatch` atomic by validating the complete plan before replacing any collection.

- [ ] **Step 6: Run all repository and migration tests and commit**

Run: `flutter test test/migration_matrix_test.dart test/repository_contract_test.dart test/repository_test.dart test/sync_repository_test.dart`

Expected: PASS with existing repository tests unchanged. Commit with `git add lib/data test/support/in_memory_ledger_repository.dart test/migration_matrix_test.dart test/repository_contract_test.dart test/sync_repository_test.dart && git commit -m "feat: add sync metadata storage"`.

## Task 3: Build Export Projection and Local Change Capture

**Files:**
- Create: `lib/app/sync/sync_projection.dart`
- Create: `lib/app/sync/sync_change_tracker.dart`
- Modify: `lib/app/veri_fin_controller.dart`
- Modify: `lib/app/veri_fin_controller_state.dart`
- Modify: `lib/app/veri_fin_controller_ops.dart`
- Test: `test/sync_projection_test.dart`, `test/sync_change_tracker_test.dart`

**Interfaces:**
- `class SyncProjectionSnapshot { const SyncProjectionSnapshot({required Map<SyncEntityKey, SyncProjectedEntity> entities}); }`
- `class SyncProjection { static const Set<String> exportKeys; static SyncProjectionSnapshot fromExportData(Map<String, Object?> root); static List<SyncLocalMutation> diff(SyncProjectionSnapshot before, SyncProjectionSnapshot after); }`
- `class SyncChangeTracker { Future<void> reconcile(); void markLocalMutation(); void markRemoteApply(); bool get remoteApplyActive; }`
- `VeriFinController.onSyncChanged` is a `VoidCallback?` invoked after every successful local mutation and after recovery/reset state has been reconciled.

- [ ] **Step 1: Test exact whitelist, normalization, additions and tombstones**

```dart
test('projection includes every approved export key and excludes credentials', () {
  final snapshot = SyncProjection.fromExportData(sampleExportData());
  expect(SyncProjection.exportKeys, contains('userWidgetDefinitions'));
  expect(SyncProjection.exportKeys, contains('activeBookId'));
  expect(snapshot.entities.keys.any((key) => key.type == 'webdav'), isFalse);
});

test('projection diff emits delete tombstone instead of inferring absence remotely', () {
  final previous = projectionWithEntry('e1');
  final next = projectionWithoutEntry('e1');
  final mutation = SyncProjection.diff(previous, next).single;
  expect(mutation.operation, SyncOperationKind.delete);
  expect(mutation.entity.id, 'e1');
});
```

- [ ] **Step 2: Run focused tests and verify they fail**

Run: `flutter test test/sync_projection_test.dart test/sync_change_tracker_test.dart`

Expected: FAIL because no projection or mutation tracker exists.

- [ ] **Step 3: Implement canonical projection**

Parse `exportDataJson()` once, extract only `SyncProjection.exportKeys`, normalize map ordering and JSON number representations, split budget maps into stable key entities, split order into position-token entities, omit `refundedBaseAmount` from competitive entry payloads, and include the full aggregate reference needed to recompute it.

- [ ] **Step 4: Wire a single mutation tracker into every local write path**

Call `markLocalMutation()` after successful entry add/update/delete, refund changes, imports, recurring generation, account/group/category/tag/book changes, budget saves, exchange-rate saves, attachment saves, resets and all approved synchronized KV preference setters. The tracker schedules a debounced `reconcile()`; it must also run on startup and after recovery. During remote apply, `markRemoteApply()` suppresses outbox generation.

- [ ] **Step 5: Add crash-recovery behavior**

Persist the last `sync_shadow` only after the projection and outbox rows are committed. If business data changed but outbox insertion failed, the next startup comparison emits the missing event. Tests must simulate the failure by using a repository that throws on enqueue while allowing the business save.

- [ ] **Step 6: Run controller/projection tests and commit**

Run: `dart format lib/app/sync lib/app/veri_fin_controller*.dart test/sync_projection_test.dart test/sync_change_tracker_test.dart` and `flutter test test/sync_projection_test.dart test/sync_change_tracker_test.dart test/controller_persistence_test.dart test/entry_added_hook_test.dart`

Expected: PASS, including no events for excluded credentials and no duplicate events during remote apply. Commit with `git add lib/app/sync lib/app/veri_fin_controller.dart lib/app/veri_fin_controller_state.dart lib/app/veri_fin_controller_ops.dart test/sync_projection_test.dart test/sync_change_tracker_test.dart && git commit -m "feat: track local changes for sync"`.

## Task 4: Implement WebDAV Sync Transport

**Files:**
- Modify: `lib/app/backup/webdav_client.dart`
- Modify: `lib/app/backup/webdav_client_io.dart`
- Modify: `lib/app/backup/webdav_client_stub.dart`
- Create: `lib/app/sync/webdav_sync_transport.dart`
- Test: `test/webdav_sync_transport_test.dart`

**Interfaces:**
- `abstract interface class WebdavSyncTransport { Future<void> ensureSyncTree(WebdavConfig config); Future<void> putImmutable(WebdavConfig config, String relativePath, Stream<List<int>> bytes, int length, String expectedHash); Future<List<WebdavSyncFile>> listSyncFiles(WebdavConfig config); Future<Uint8List> downloadSyncFile(WebdavConfig config, String relativePath, {required int maxBytes}); }`
- `WebdavSyncFile` contains relative path, file kind (`event`, `manifest`, `commit`, `blob`), deviceId/sequence when parseable, size and modified time.

- [ ] **Step 1: Test path encoding, directory creation, extension discovery and idempotent collisions**

Use a fake transport/server to assert `events/device%2Fid` is never produced, each directory is created level-by-level, `.vfsync`, `.manifest`, `.commit` and `.blob` are listed, duplicate same-hash PUT succeeds, and duplicate path with a different hash throws `WebdavFileCollision`.

- [ ] **Step 2: Run the transport tests before implementation**

Run: `flutter test test/webdav_sync_transport_test.dart`

Expected: FAIL because the sync transport and file kinds do not exist.

- [ ] **Step 3: Add segmented URL and recursive Depth:1 operations**

Implement path-segment encoding, `MKCOL` for `verifin-sync/v1`, `events`, `blobs`, `batches` and each device directory, then recursively issue `PROPFIND Depth:1`. Do not use the existing backup filename filter or `joinWebdavUrl` for nested paths.

- [ ] **Step 4: Add bounded streaming upload/download**

Upload from a `Stream<List<int>>` with a known content length. Download through `BytesBuilder` only up to `maxBytes`, abort as soon as the limit is exceeded, and verify SHA-256 before returning. Blob limits must be a named constant and covered by tests; no call may use unbounded `readBytes()`.

- [ ] **Step 5: Implement immutable PUT behavior and stub parity**

Before PUT, GET/PROPFIND the target when the server reports an existing path. Same hash is success; different hash is a hard collision. The test stub must expose the same methods and deterministic fake files so engine tests are platform-independent.

- [ ] **Step 6: Run tests and commit**

Run: `dart format lib/app/backup lib/app/sync/webdav_sync_transport.dart test/webdav_sync_transport_test.dart` and `flutter test test/webdav_sync_transport_test.dart test/webdav_config_test.dart`

Expected: PASS. Commit with `git add lib/app/backup lib/app/sync/webdav_sync_transport.dart test/webdav_sync_transport_test.dart && git commit -m "feat: add WebDAV sync transport"`.

## Task 5: Build Sync Engine, Batches, Merge and Baseline

**Files:**
- Create: `lib/app/sync/sync_engine.dart`
- Create: `lib/app/sync/sync_conflict.dart`
- Modify: `lib/app/sync/sync_store.dart`
- Modify: `lib/app/veri_fin_controller.dart`
- Test: `test/sync_engine_test.dart`, `test/sync_merge_test.dart`, `test/sync_baseline_test.dart`

**Interfaces:**
- `enum SyncTrigger { startup, resumed, localMutation, manual }`
- `class SyncRunResult { const SyncRunResult({required int uploaded, required int downloaded, required int conflicts, required int pending, required String? errorCode}); }`
- `class SyncEngine { Future<SyncRunResult> run({required SyncTrigger trigger}); Future<void> initializeFromRestoredData(); Future<List<SyncConflict>> conflicts(); Future<void> resolveConflict(String conflictId, ConflictResolution resolution); }`
- `enum ConflictResolution { keepLocal, keepRemote, keepDelete, keepEdit, cancel }`

- [ ] **Step 1: Write tests for append-only batches and merge semantics**

Cover: two offline additions produce two entries; same operation repeated is ignored; same path with different bytes fails; causal successor replaces predecessor; concurrent versions create two stored versions; delete/edit concurrency creates a conflict; a transaction with entry + refund + attachment + rate is invisible until `.commit` exists; `refundedBaseAmount` is recomputed after apply.

- [ ] **Step 2: Write baseline/join tests**

Test an empty remote directory creates one baseline batch without treating every restored record as a new user edit. Test a non-empty remote directory reconstructs remote state, records the pre-scan per-device high-water and creates “join conflicts” when local restored hashes differ. Events arriving during the scan must be processed on the next scan, not skipped.

- [ ] **Step 3: Run focused tests and verify they fail**

Run: `flutter test test/sync_engine_test.dart test/sync_merge_test.dart test/sync_baseline_test.dart`

Expected: FAIL because no engine, batch commit protocol or conflict store exists.

- [ ] **Step 4: Implement upload phase**

Read outbox rows, group aggregate mutations by `batchId`, upload encrypted event files and blob files, upload the manifest, then upload immutable `batchId.commit`. Mark outbox uploaded only after commit succeeds. Keep failures and retry counts in outbox; never delete remote events.

- [ ] **Step 5: Implement scan/decode/apply phase**

Recursively list per-device files, retain gap sequences in `sync_scan_state`, download unseen manifests/events/commits, verify file size/hash/key fingerprint/protocol version, defer incomplete batches to `sync_pending`, merge by vector causality, and call `applyRemoteBatch` once per complete batch. Advance applied operations and continuous high-water only after SQLite and KV journal completion.

- [ ] **Step 6: Implement conflict storage and resolution events**

Store both payloads and their vectors in `sync_conflicts`/`sync_entity_versions`. `resolveConflict` creates a new local `resolve` event referencing both parent operation IDs, applies the chosen payload through the normal mutation tracker, and leaves the original versions auditable.

- [ ] **Step 7: Implement first-join baseline and manual recovery reset**

`initializeFromRestoredData()` freezes sync writes, scans remote state, chooses empty-remote baseline or non-empty join-conflict flow, then writes shadow and scan state. Add a recovery guard that reports outbox/conflict counts; “overwrite and reset sync state” clears local outbox/applied/scan/shadow and rebuilds a new baseline without deleting remote history.

- [ ] **Step 8: Run engine tests and commit**

Run: `dart format lib/app/sync lib/app/veri_fin_controller.dart test/sync_engine_test.dart test/sync_merge_test.dart test/sync_baseline_test.dart` and `flutter test test/sync_engine_test.dart test/sync_merge_test.dart test/sync_baseline_test.dart test/refund_test.dart test/transfer_fee_test.dart`

Expected: PASS, including aggregate atomicity, conflict preservation, baseline watermarking and no remote-apply echo. Commit with `git add lib/app/sync lib/app/veri_fin_controller.dart test/sync_engine_test.dart test/sync_merge_test.dart test/sync_baseline_test.dart && git commit -m "feat: merge WebDAV sync events"`.

## Task 6: Add KV Journal and Mutually Exclusive Transport Mode

**Files:**
- Modify: `lib/app/backup/backup_settings.dart`
- Modify: `lib/app/backup/webdav_config.dart`
- Modify: `lib/app/veri_fin_controller_state.dart`
- Modify: `lib/app/veri_fin_controller_ops.dart`
- Modify: `lib/app/sync/sync_store.dart`
- Modify: `lib/pages/data_management_page.dart`
- Modify: `lib/pages/data_management_dialogs.dart`
- Modify: `lib/l10n/app_zh.arb`
- Modify: `lib/l10n/app_en.arb`
- Test: `test/transport_mode_test.dart`, `test/sync_kv_journal_test.dart`, `test/data_management_page_test.dart`

**Interfaces:**
- `enum BackupTransportMode { manual, autoUpload, autoSync }`
- `BackupTransportMode get backupTransportMode`
- `Future<bool> setBackupTransportMode(BackupTransportMode mode)`
- `Future<void> applySyncPreferenceJournal()`

- [ ] **Step 1: Test mode migration and crash repair**

Assert old `BackupSettings.frequency`/`WebdavConfig.autoUpload` values migrate to one mode, enabling one mode disables the other, a simulated interrupted write repairs to the last checksummed mode on startup, and reopening the controller never reports both automatic modes active.

- [ ] **Step 2: Run focused tests and verify they fail**

Run: `flutter test test/transport_mode_test.dart test/sync_kv_journal_test.dart`

Expected: FAIL because `BackupTransportMode` and journal replay are absent.

- [ ] **Step 3: Implement single-mode persistence and legacy migration**

Add `verifin.backup_transport_mode.v1` as the canonical value with checksum/version. Keep old keys readable for one migration path, write the canonical mode first, and repair conflicting old values on controller startup. Do not claim SharedPreferences multi-key atomicity.

- [ ] **Step 4: Implement KV journal replay**

For remote profile/theme/panel/order/default/FAB/amount/widget changes, insert a journal row with target key/value hashes before SQLite metadata commit, call `writeAndFlush` in deterministic key order, then mark the row applied. On restart, replay idempotently before projection reconciliation; a failed KV write keeps the batch pending and visible as an error.

- [ ] **Step 5: Update settings controls and copy**

Add the auto-sync switch, mutual-exclusion feedback, sync status row and recovery guard to the existing data-management page. Keep “立即上传” and “从 WebDAV 恢复” separate. Add Chinese and English strings for mode labels, sync status, pending counts, collision/key mismatch, recovery reset and conflict entry.

- [ ] **Step 6: Run settings/journal tests and commit**

Run: `dart format lib/app/backup lib/app/veri_fin_controller*.dart lib/pages/data_management_page.dart lib/pages/data_management_dialogs.dart` and `flutter test test/transport_mode_test.dart test/sync_kv_journal_test.dart test/data_management_page_test.dart test/webdav_config_test.dart`

Expected: PASS with old backup tests unchanged. Commit with `git add lib/app/backup lib/app/veri_fin_controller_state.dart lib/app/veri_fin_controller_ops.dart lib/app/sync/sync_store.dart lib/pages lib/l10n/app_zh.arb lib/l10n/app_en.arb test/transport_mode_test.dart test/sync_kv_journal_test.dart test/data_management_page_test.dart && git commit -m "feat: add exclusive sync transport mode"`.

## Task 7: Build Conflict Review and Resolution UI

**Files:**
- Create: `lib/pages/sync_conflicts_page.dart`
- Modify: `lib/pages/data_management_page.dart`
- Modify: `lib/l10n/app_zh.arb`
- Modify: `lib/l10n/app_en.arb`
- Test: `test/sync_conflicts_page_test.dart`

**Interfaces:**
- `class SyncConflictsPage extends StatelessWidget { const SyncConflictsPage({super.key}); }`
- `SyncConflictCard` displays entity type, scope/ledger, both payload summaries, source device, logical time/sequence, and resolution actions.

- [ ] **Step 1: Write widget tests for list, detail and resolution behavior**

Test empty state, two-version display, field differences, delete-vs-edit labels, keep-local/keep-remote action calls, cancellation leaving both versions untouched, and conflict count refresh after resolution.

- [ ] **Step 2: Run the widget test before implementation**

Run: `flutter test test/sync_conflicts_page_test.dart`

Expected: FAIL because the page and conflict card do not exist.

- [ ] **Step 3: Implement the page using existing UI primitives**

Use `Scaffold > SafeArea > VeriPage > ListView`, `VeriHeader`, `VeriCard`, existing icon boxes and `showConfirmDialog` for destructive/overwrite resolution. Do not use a new modal pattern or expose raw JSON/ciphertext. Render amounts through existing currency helpers and omit derived refund cache fields from the comparison.

- [ ] **Step 4: Wire status entry and feedback**

Make the data-management sync status row navigate to the page, show pending conflict count, keep unresolved conflicts non-blocking for normal bookkeeping, and report resolution failures through `VeriFeedbackHost` plus `AppLogger`.

- [ ] **Step 5: Run tests, format and commit**

Run: `dart format lib/pages/sync_conflicts_page.dart lib/pages/data_management_page.dart` and `flutter test test/sync_conflicts_page_test.dart test/data_management_page_test.dart`

Expected: PASS. Commit with `git add lib/pages/sync_conflicts_page.dart lib/pages/data_management_page.dart lib/l10n/app_zh.arb lib/l10n/app_en.arb test/sync_conflicts_page_test.dart && git commit -m "feat: add sync conflict review"`.

## Task 8: Wire Lifecycle, Debounce and Manual Sync

**Files:**
- Modify: `lib/app/sync/sync_coordinator.dart`
- Modify: `lib/main.dart`
- Modify: `lib/app/veri_fin_controller.dart`
- Modify: `lib/pages/data_management_page.dart`
- Test: `test/sync_lifecycle_test.dart`, `test/sync_trigger_test.dart`

**Interfaces:**
- `class SyncCoordinator { Future<void> onStartup(); Future<void> onResumed(); void onLocalMutation(); Future<SyncRunResult> runManual(); }`

- [ ] **Step 1: Write lifecycle and debounce tests**

Assert startup and resumed trigger one run each, rapid local mutations collapse into one debounced run, manual sync bypasses the debounce, concurrent triggers use one global run, and auto-upload mode never invokes the sync engine.

- [ ] **Step 2: Run focused tests and verify they fail**

Run: `flutter test test/sync_lifecycle_test.dart test/sync_trigger_test.dart`

Expected: FAIL because lifecycle callbacks are not connected.

- [ ] **Step 3: Implement coordinator and root wiring**

In `main.dart`, instantiate one coordinator per app root, call `onStartup` after controller initialization, call `onResumed` after recurring generation and before widget refresh, and connect `onSyncChanged` to `onLocalMutation`. Preserve existing `BackupCoordinator` behavior only for `autoUpload` mode; the two coordinators must not both run automatic network work.

- [ ] **Step 4: Add manual sync action and status refresh**

Add “立即同步” to data management. Await the result, update persisted sync state, show success/error feedback, and leave outbox intact on failure. Do not start a background timer or claim real-time behavior.

- [ ] **Step 5: Run lifecycle tests and commit**

Run: `dart format lib/app/sync/sync_coordinator.dart lib/main.dart lib/app/veri_fin_controller.dart lib/pages/data_management_page.dart` and `flutter test test/sync_lifecycle_test.dart test/sync_trigger_test.dart test/backup_coordinator_test.dart test/entry_added_hook_test.dart`

Expected: PASS with existing backup trigger tests still passing. Commit with `git add lib/app/sync/sync_coordinator.dart lib/main.dart lib/app/veri_fin_controller.dart lib/pages/data_management_page.dart test/sync_lifecycle_test.dart test/sync_trigger_test.dart && git commit -m "feat: trigger foreground WebDAV sync"`.

## Task 9: Complete Integration, Documentation and Verification

**Files:**
- Modify: `docs/dev/tech-decisions.md`
- Modify: `docs/acceptance-checklist.md`
- Modify: `README.md`
- Modify: `CHANGELOG.md`
- Test: `test/sync_integration_test.dart`, `test/backup_test.dart`, `test/model_roundtrip_test.dart`

- [ ] **Step 1: Add two-device integration harness**

Create two controllers with separate in-memory SQLite/KV stores and one fake WebDAV transport. Test restored baseline, offline additions, causal edit, concurrent edit, delete/edit conflict, preference conflict, duplicate event replay, attachment hash de-duplication, failed upload retry, and manual restore reset.

- [ ] **Step 2: Run the integration test before final documentation**

Run: `flutter test test/sync_integration_test.dart`

Expected: FAIL until all prior tasks are connected; any failure is a blocker for the plan.

- [ ] **Step 3: Add documentation and user-facing release notes**

Update `tech-decisions.md` with the separate sync protocol, all-backup-range whitelist, WebDAV event retention, same-account permission boundary, foreground-only guarantee and encryption-key requirement. Update `acceptance-checklist.md` with mutual exclusion, two-device merge, conflict resolution, attachment hash, recovery reset and no-background guarantee. Update `README.md` and `CHANGELOG.md` to describe WebDAV automatic bidirectional sync as eventual foreground sync, not real-time cloud collaboration.

- [ ] **Step 4: Run full static and test verification**

Run:

```bash
dart format .
flutter analyze
flutter test
```

Expected: all commands pass with no new lint suppressions, skipped tests, placeholder branches or unimplemented sync paths.

- [ ] **Step 5: Run Android-specific verification checklist**

Use the repository’s fixed Flutter/Android toolchain to verify a release/R8 APK on a diagnostic flavor: configure WebDAV, restore a backup, enable auto-sync, add records on two test installs, background/foreground the app, resolve a conflict, kill/restart the process, and verify pending outbox replay. Confirm no application data is cleared, no credentials enter sync events, and existing manual backup/restore still round-trips attachments.

- [ ] **Step 6: Inspect diff and commit documentation**

Run `git diff --check`, inspect every changed file for unfinished markers, disabled/focused test directives, placeholder copy and accidental generated-file edits, then commit with `git add docs/dev/tech-decisions.md docs/acceptance-checklist.md README.md CHANGELOG.md test/sync_integration_test.dart && git commit -m "docs: document WebDAV bidirectional sync"`.

## Dependency and Review Gates

- Task 1 must pass before any serialized event or database migration code is written.
- Task 2 must pass before projection or remote merge code can persist data.
- Task 3 must pass before automatic sync is exposed in settings; missing mutation hooks are a release blocker.
- Task 4 must pass before real WebDAV requests are enabled; transport tests must cover path encoding and collision behavior.
- Task 5 must pass before the automatic sync switch is enabled; baseline and aggregate commit semantics are mandatory.
- Tasks 6 and 7 must pass before user-facing conflict resolution is considered complete.
- Task 8 must pass before claiming automatic behavior; no background real-time claim may appear in UI or docs.
- Task 9 is the final completion gate; all existing backup tests and the full Flutter suite must remain green.

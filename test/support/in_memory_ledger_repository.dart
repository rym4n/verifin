import 'package:verifin/app/models.dart';
import 'package:verifin/app/sync/sync_change_tracker.dart';
import 'package:verifin/app/sync/sync_models.dart';
import 'package:verifin/app/sync/sync_snapshot.dart';
import 'package:verifin/app/sync/sync_store.dart';
import 'package:verifin/data/ledger_repository.dart';

/// 纯内存仓储实现，供 widget / 控制器逻辑测试注入。
///
/// saveX 同步更新内部状态（返回已完成的 Future），因此不会引入真实异步 I/O，
/// 避免与 testWidgets 的 fake-async 冲突；同一实例在多个控制器间共享即模拟重启后
/// 从同一存储重新载入。
class InMemoryLedgerRepository
    implements LedgerRepository, SyncProjectionSource {
  Map<String, Object?> _profile = <String, Object?>{};
  List<LedgerEntry> _entries = <LedgerEntry>[];

  List<LedgerBook> _books = <LedgerBook>[];
  List<Account> _accounts = <Account>[];
  List<AccountGroup> _groups = <AccountGroup>[];
  List<Category> _categories = <Category>[];
  List<Tag> _tags = <Tag>[];
  List<Attachment> _attachments = <Attachment>[];
  List<RecurringRule> _recurringRules = <RecurringRule>[];
  List<ExchangeRate> _exchangeRates = <ExchangeRate>[];
  Map<String, double> _monthlyBudgets = <String, double>{};
  Map<String, double> _categoryBudgets = <String, double>{};
  Map<String, double> _dailyBudgets = <String, double>{};

  /// 同步元数据的内存镜像，与 [SqliteLedgerRepository.sync] 同契约。
  @override
  late final SyncRepository sync = _InMemorySyncRepository();

  @override
  Future<List<LedgerEntry>> loadEntries() async =>
      List<LedgerEntry>.of(_entries);

  @override
  Future<void> saveEntries(List<LedgerEntry> entries) async {
    _entries = List<LedgerEntry>.of(entries);
  }

  @override
  Future<List<LedgerBook>> loadBooks() async => List<LedgerBook>.of(_books);

  @override
  Future<void> saveBooks(List<LedgerBook> books) async {
    _books = List<LedgerBook>.of(books);
  }

  @override
  Future<List<Account>> loadAccounts() async => List<Account>.of(_accounts);

  @override
  Future<void> saveAccounts(List<Account> accounts) async {
    _accounts = List<Account>.of(accounts);
  }

  @override
  Future<List<AccountGroup>> loadAccountGroups() async =>
      List<AccountGroup>.of(_groups);

  @override
  Future<void> saveAccountGroups(List<AccountGroup> groups) async {
    _groups = List<AccountGroup>.of(groups);
  }

  @override
  Future<List<Category>> loadCategories() async =>
      List<Category>.of(_categories);

  @override
  Future<void> saveCategories(List<Category> categories) async {
    _categories = List<Category>.of(categories);
  }

  @override
  Future<List<Tag>> loadTags() async => List<Tag>.of(_tags);

  @override
  Future<void> saveTags(List<Tag> tags) async {
    _tags = List<Tag>.of(tags);
  }

  @override
  Future<List<Attachment>> loadAttachments() async =>
      List<Attachment>.of(_attachments);

  @override
  Future<void> saveAttachments(List<Attachment> attachments) async {
    _attachments = List<Attachment>.of(attachments);
  }

  @override
  Future<void> saveEntryAggregate({
    required List<LedgerEntry> entries,
    required List<Attachment> attachments,
    List<ExchangeRate>? exchangeRates,
  }) async {
    _entries = List<LedgerEntry>.of(entries);
    _attachments = List<Attachment>.of(attachments);
    if (exchangeRates != null) {
      _exchangeRates = List<ExchangeRate>.of(exchangeRates);
    }
  }

  @override
  Future<List<RecurringRule>> loadRecurringRules() async =>
      List<RecurringRule>.of(_recurringRules);

  @override
  Future<void> saveRecurringRules(List<RecurringRule> rules) async {
    _recurringRules = List<RecurringRule>.of(rules);
  }

  @override
  Future<void> saveRecurringGeneration({
    required List<LedgerEntry> entries,
    required List<RecurringRule> recurringRules,
  }) async {
    _entries = List<LedgerEntry>.of(entries);
    _recurringRules = List<RecurringRule>.of(recurringRules);
  }

  @override
  Future<List<ExchangeRate>> loadExchangeRates() async =>
      List<ExchangeRate>.of(_exchangeRates);

  @override
  Future<void> saveExchangeRates(List<ExchangeRate> rates) async {
    _exchangeRates = List<ExchangeRate>.of(rates);
  }

  @override
  Future<Map<String, double>> loadMonthlyBudgets() async =>
      Map<String, double>.of(_monthlyBudgets);

  @override
  Future<void> saveMonthlyBudgets(Map<String, double> budgets) async {
    _monthlyBudgets = Map<String, double>.of(budgets);
  }

  @override
  Future<Map<String, double>> loadCategoryBudgets() async =>
      Map<String, double>.of(_categoryBudgets);

  @override
  Future<void> saveCategoryBudgets(Map<String, double> budgets) async {
    _categoryBudgets = Map<String, double>.of(budgets);
  }

  @override
  Future<Map<String, double>> loadDailyBudgets() async =>
      Map<String, double>.of(_dailyBudgets);

  @override
  Future<void> saveDailyBudgets(Map<String, double> budgets) async {
    _dailyBudgets = Map<String, double>.of(budgets);
  }

  @override
  Future<void> saveBudgetSettings({
    required Map<String, double> monthlyBudgets,
    required Map<String, double> categoryBudgets,
    required Map<String, double> dailyBudgets,
  }) async {
    _monthlyBudgets = Map<String, double>.of(monthlyBudgets);
    _categoryBudgets = Map<String, double>.of(categoryBudgets);
    _dailyBudgets = Map<String, double>.of(dailyBudgets);
  }

  @override
  Future<void> replaceAllLedgerData(LedgerDataSnapshot snapshot) async {
    _books = List<LedgerBook>.of(snapshot.books);
    _accounts = List<Account>.of(snapshot.accounts);
    _groups = List<AccountGroup>.of(snapshot.accountGroups);
    _categories = List<Category>.of(snapshot.categories);
    _tags = List<Tag>.of(snapshot.tags);
    _attachments = List<Attachment>.of(snapshot.attachments);
    _entries = List<LedgerEntry>.of(snapshot.entries);
    _recurringRules = List<RecurringRule>.of(snapshot.recurringRules);
    _exchangeRates = List<ExchangeRate>.of(snapshot.exchangeRates);
    _monthlyBudgets = Map<String, double>.of(snapshot.monthlyBudgets);
    _categoryBudgets = Map<String, double>.of(snapshot.categoryBudgets);
    _dailyBudgets = Map<String, double>.of(snapshot.dailyBudgets);
  }

  @override
  Future<void> applyRemoteLedgerData(
    LedgerDataSnapshot snapshot,
    RemoteApplyPlan plan,
  ) async {
    await sync.applyRemoteBatch(plan);
    await replaceAllLedgerData(snapshot);
  }

  @override
  Future<bool> hasAnyData() async =>
      _entries.isNotEmpty ||
      _books.isNotEmpty ||
      _accounts.isNotEmpty ||
      _groups.isNotEmpty ||
      _categories.isNotEmpty ||
      _exchangeRates.isNotEmpty;

  // SyncProjectionSource implementation for testing
  @override
  Map<String, Object?> exportDataForSync() {
    final allEntries = [
      ..._entries.map((e) => <String, Object?>{'id': e.id, 'amount': e.amount}),
    ];
    return {
      if (_profile.isNotEmpty) 'profile': _profile,
      if (allEntries.isNotEmpty) 'entries': allEntries,
    };
  }

  @override
  Future<void> waitForPendingWrites() async {
    // No async writes in memory implementation
  }

  // VeriFinController stub methods for testing
  Future<T> runRemoteApply<T>(Future<T> Function() apply) async {
    // Simple pass-through for testing
    // In real implementation, this would call markRemoteApply, run apply,
    // clearRemoteApply, and reconcile(alignShadowOnly: true)
    return apply();
  }

  // Test helper methods
  void setProfile(Map<String, Object?> profile) {
    _profile = Map<String, Object?>.from(profile);
  }

  void addTestEntry(Map<String, Object?> entryData) {
    final entry = LedgerEntry(
      id: entryData['id'] as String? ?? 'entry-${_entries.length + 1}',
      bookId: entryData['bookId'] as String? ?? 'default',
      type: EntryType.expense,
      amount: (entryData['amount'] as num?)?.toDouble() ?? 0.0,
      currencyCode: entryData['currencyCode'] as String? ?? 'CNY',
      categoryId: entryData['categoryId'] as String? ?? '',
      accountId: entryData['accountId'] as String? ?? '',
      note: entryData['memo'] as String? ?? '',
      occurredAt: entryData['occurredAt'] as DateTime? ?? DateTime.now(),
      tagIds:
          (entryData['tagIds'] as List<dynamic>?)?.cast<String>() ?? const [],
      refundOf: entryData['refundedEntryId'] as String?,
    );
    _entries.add(entry);
  }
}

/// [SyncRepository] 的内存实现。与 SQLite 实现共用 [SyncPlanValidator]，
/// 保证「测试放过的批次生产也放过、测试拒绝的生产也拒绝」。
///
/// [applyRemoteBatch] 先完成全部校验与全部新集合的构造，再一次性替换引用；
/// 中途抛错时没有任何集合被改动，等价于 SQLite 的事务回滚。
class _InMemorySyncRepository implements SyncRepository {
  String? _enrollment;
  SyncSnapshotState _snapshotState = const SyncSnapshotState();
  final Map<int, SnapshotPublication> _snapshotPublications = {};
  final Map<int, List<SyncOutboxRecord>> _snapshotMembers = {};
  final Map<String, SyncSnapshotCursor> _snapshotCursors = {};
  final Map<String, Map<String, SnapshotBlobMapping>> _snapshotBlobs = {};
  @override
  Future<String?> loadEnrollmentState() async => _enrollment;
  @override
  Future<void> saveEnrollmentState(String state) async {
    _enrollment = state;
  }

  @override
  Future<void> saveConflictChoice(
    String batchId,
    String conflictId,
    SyncEvent? event,
  ) async {
    final prior = _pendingBatches[batchId]!;
    _pendingBatches[batchId] = SyncPendingBatch(
      batchId: batchId,
      events: prior.events,
      reason: prior.reason,
      choices: {
        for (final item in prior.choices.entries)
          if (item.key != conflictId) item.key: item.value,
        conflictId: ?event,
      },
    );
  }

  final Map<String, RemoteApplyPlan> _prepared = {};
  final Map<SyncEntityKey, SyncEntityVersion> _heads = {};
  @override
  Future<void> removePendingBatch(String id) async {
    _pendingBatches.remove(id);
  }

  @override
  Future<void> finalizePreparedBatches() async {
    for (final plan in _prepared.values.toList()) {
      if (_kvJournal.any(
        (e) => e.batchId == plan.batchId && !_kvJournalApplied.contains(e.id),
      )) {
        continue;
      }
      _finalize(plan);
      _prepared.remove(plan.batchId);
    }
  }

  void _finalize(RemoteApplyPlan plan) {
    for (final id in plan.appliedOperationIds) {
      _applied[id] = (
        batchId: plan.batchId,
        payloadHash: plan.payloadHashForOperation(id),
      );
    }
    var known = _deviceState.knownVector;
    for (final v in plan.entityVersions) {
      known = known
          .merged(v.version.context)
          .merged(
            SyncVersionVector({v.version.dot.deviceId: v.version.dot.sequence}),
          );
    }
    _deviceState = SyncDeviceState(
      deviceId: _deviceState.deviceId,
      nextSequence: _deviceState.nextSequence,
      knownVector: known,
    );
    for (final e in plan.resolutionEvents) {
      _outbox.add(
        SyncOutboxRecord(
          batchId: e.batchId,
          operationId: e.operationId,
          relativePath:
              'events/${e.version.dot.deviceId}/${e.version.dot.sequence.toString().padLeft(20, '0')}-${e.operationId}.vfsync',
          payloadHash: e.payloadHash,
          retryCount: 0,
          event: e,
        ),
      );
    }
    _conflicts.removeWhere((c) => plan.resolvedConflictIds.contains(c.id));
    for (final id in [plan.batchId, ...plan.completedPendingIds]) {
      _pendingBatches.remove(id);
    }
  }

  @override
  Future<Map<SyncEntityKey, SyncEntityVersion>> loadEntityHeads(
    Set<SyncEntityKey> keys,
  ) async => {
    for (final key in keys)
      if (_heads.containsKey(key)) key: _heads[key]!,
  };
  final Map<String, SyncPendingBatch> _pendingBatches = {};
  @override
  Future<void> savePendingBatch(
    String id,
    List<SyncEvent> events,
    String reason,
  ) async {
    _pendingBatches[id] = SyncPendingBatch(
      batchId: id,
      events: events,
      reason: reason,
      choices: _pendingBatches[id]?.choices ?? const {},
    );
  }

  @override
  Future<List<SyncPendingBatch>> loadPendingBatches() async =>
      _pendingBatches.values.toList();
  @override
  Future<Map<String, String>> loadAppliedOperationHashes(
    List<String> operationIds,
  ) async => {
    for (final id in operationIds)
      if (_applied.containsKey(id)) id: _applied[id]!.payloadHash,
  };

  SyncDeviceState _deviceState = const SyncDeviceState(
    deviceId: '',
    nextSequence: 1,
    knownVector: SyncVersionVector(<String, int>{}),
  );
  final List<SyncOutboxRecord> _outbox = <SyncOutboxRecord>[];
  SyncScanState _scanState = const SyncScanState(
    contiguousSequences: <String, int>{},
    gaps: <String, List<int>>{},
    lastSuccess: null,
    lastErrorCode: null,
    retryCount: 0,
  );
  final List<SyncConflictRecord> _conflicts = <SyncConflictRecord>[];

  /// journal 行的内存镜像，与 SQLite 的 `sync_apply_journal` 同契约：
  /// applyRemoteBatch 插入未应用行，`markKvJournalApplied` 原地翻转其 applied 位
  /// （用 `_applied` 前缀命名的可变字段区分同名的 `_applied` 已应用操作表）。
  final List<KvJournalEntry> _kvJournal = <KvJournalEntry>[];
  final Set<int> _kvJournalApplied = <int>{};
  int _kvJournalNextId = 1;

  /// operationId → (batchId, payloadHash)：等价于 sync_applied_ops 与
  /// sync_entity_versions 的合并视角。
  final Map<String, ({String batchId, String payloadHash})> _applied =
      <String, ({String batchId, String payloadHash})>{};

  /// 已落库实体版本，按实体分桶（一个实体可有多版，冲突两侧都保留）。
  final Map<SyncEntityKey, List<SyncEntityVersion>> _versions =
      <SyncEntityKey, List<SyncEntityVersion>>{};

  @override
  Future<SyncDeviceState> loadDeviceState() async => _deviceState;

  @override
  Future<void> saveDeviceState(SyncDeviceState state) async {
    _deviceState = state;
  }

  @override
  Future<List<SyncOutboxRecord>> loadOutbox() async =>
      List<SyncOutboxRecord>.of(_outbox);

  @override
  Future<void> enqueueBatch(SyncBatchRecord batch) async {
    for (final event in batch.events) {
      final version = SyncEntityVersion(
        entity: event.entity,
        version: event.version,
        payloadHash: event.payloadHash,
        payload: event.payload,
        deleted: event.operation == SyncOperationKind.delete,
        operationId: event.operationId,
      );
      _heads[event.entity] = version;
      _versions.putIfAbsent(event.entity, () => []).add(version);
      _outbox.removeWhere(
        (record) =>
            record.batchId == batch.batchId &&
            record.operationId == event.operationId,
      );
      _outbox.add(
        SyncOutboxRecord(
          batchId: batch.batchId,
          operationId: event.operationId,
          // 与 SqliteSyncRepository._relativePathFor 保持一致：序列零填充到 20 位，
          // 使远端目录的字典序等于序列序。契约测试逐字比对完整路径。
          relativePath:
              'events/${event.version.dot.deviceId}/'
              '${event.version.dot.sequence.toString().padLeft(20, '0')}'
              '-${event.operationId}.vfsync',
          payloadHash: event.payloadHash,
          retryCount: 0,
          event: event,
        ),
      );
    }
  }

  @override
  Future<void> markBatchUploaded(String batchId) async {
    _outbox.removeWhere((record) => record.batchId == batchId);
  }

  @override
  Future<SyncSnapshotState> loadSnapshotState() async => _snapshotState;

  @override
  Future<PreparedSyncSnapshot> prepareSnapshotPublication() async {
    final sequence = _snapshotState.nextSnapshotSequence;
    final publication = SnapshotPublication(
      sequence: sequence,
      state: SnapshotPublicationState.prepared,
    );
    final members = List<SyncOutboxRecord>.of(_outbox);
    final heads = _heads.values.toList();
    final emittedVersions = <SyncEntityVersion>[
      ...heads,
      for (final conflict in _conflicts) ...[conflict.local, conflict.remote],
    ];
    for (final member in members) {
      if (!snapshotVersionsCoverOutbox(member, emittedVersions)) {
        throw StateError('snapshot_outbox_not_represented');
      }
    }
    _snapshotState = SyncSnapshotState(
      nextSnapshotSequence: sequence + 1,
      lastPublishedSequence: _snapshotState.lastPublishedSequence,
      lastPublishedHash: _snapshotState.lastPublishedHash,
      lastPublishedAt: _snapshotState.lastPublishedAt,
      v1ImportCompleted: _snapshotState.v1ImportCompleted,
      v1MigrationState: _snapshotState.v1MigrationState,
      v1LastSeenFingerprint: _snapshotState.v1LastSeenFingerprint,
    );
    _snapshotPublications[sequence] = publication;
    _snapshotMembers[sequence] = members;
    return PreparedSyncSnapshot(
      publication: publication,
      heads: heads,
      conflicts: List<SyncConflictRecord>.of(_conflicts),
      members: members,
    );
  }

  @override
  Future<void> freezeSnapshotBlobMembers(
    int snapshotSequence,
    List<SnapshotBlobMapping> mappings,
  ) async {
    final publication = _snapshotPublications[snapshotSequence];
    if (publication?.state != SnapshotPublicationState.prepared ||
        mappings.any((mapping) => !mapping.verified) ||
        mappings.map((mapping) => mapping.rawHash).toSet().length !=
            mappings.length) {
      throw StateError('snapshot_blob_mapping_invalid');
    }
    for (final mapping in mappings) {
      if (_snapshotBlobs[mapping.rawHash]?[mapping.fileHash]?.verified !=
          true) {
        throw StateError('snapshot_blob_mapping_unverified');
      }
    }
    _snapshotPublications[snapshotSequence] = SnapshotPublication(
      sequence: snapshotSequence,
      state: SnapshotPublicationState.blobsReady,
    );
  }

  @override
  Future<void> markSnapshotPublished(
    int snapshotSequence, {
    required String filename,
    required String snapshotHash,
  }) async => _publishSnapshot(
    snapshotSequence,
    filename: filename,
    snapshotHash: snapshotHash,
    completeV1Cutover: false,
  );

  @override
  Future<void> completeV1CutoverWithPublication(
    int snapshotSequence, {
    required String filename,
    required String snapshotHash,
  }) async => _publishSnapshot(
    snapshotSequence,
    filename: filename,
    snapshotHash: snapshotHash,
    completeV1Cutover: true,
  );

  Future<void> _publishSnapshot(
    int snapshotSequence, {
    required String filename,
    required String snapshotHash,
    required bool completeV1Cutover,
  }) async {
    final publication = _snapshotPublications[snapshotSequence];
    if (publication?.state != SnapshotPublicationState.blobsReady) {
      throw StateError('snapshot_not_blobs_ready');
    }
    final parsedFilename = SnapshotFileName.parse(filename);
    if (parsedFilename.isBlob ||
        parsedFilename.snapshotSequence != snapshotSequence ||
        parsedFilename.fileHash != snapshotHash) {
      throw StateError('snapshot_publication_identity_mismatch');
    }
    if (_snapshotState.lastPublishedSequence != null &&
        snapshotSequence <= _snapshotState.lastPublishedSequence!) {
      throw StateError('snapshot_publication_sequence_regression');
    }
    if (completeV1Cutover &&
        _snapshotState.v1MigrationState != V1MigrationState.readyToCutover) {
      throw StateError('snapshot_v1_cutover_not_ready');
    }
    final ids = _snapshotMembers[snapshotSequence]!
        .map((member) => (member.operationId, member.payloadHash))
        .toSet();
    _outbox.removeWhere(
      (record) => ids.contains((record.operationId, record.payloadHash)),
    );
    _snapshotPublications[snapshotSequence] = SnapshotPublication(
      sequence: snapshotSequence,
      state: SnapshotPublicationState.published,
      filename: filename,
      snapshotHash: snapshotHash,
      publishedAt: DateTime.now(),
    );
    _snapshotState = SyncSnapshotState(
      nextSnapshotSequence: _snapshotState.nextSnapshotSequence,
      lastPublishedSequence: snapshotSequence,
      lastPublishedHash: snapshotHash,
      lastPublishedAt: DateTime.now(),
      v1ImportCompleted: completeV1Cutover || _snapshotState.v1ImportCompleted,
      v1MigrationState: completeV1Cutover
          ? V1MigrationState.cutoverComplete
          : _snapshotState.v1MigrationState,
      v1LastSeenFingerprint: _snapshotState.v1LastSeenFingerprint,
    );
  }

  @override
  Future<void> abandonIncompleteSnapshotPublications() async {
    for (final entry in _snapshotPublications.entries.toList()) {
      if (entry.value.state == SnapshotPublicationState.prepared ||
          entry.value.state == SnapshotPublicationState.blobsReady) {
        _snapshotPublications[entry.key] = SnapshotPublication(
          sequence: entry.key,
          state: SnapshotPublicationState.abandoned,
        );
      }
    }
  }

  @override
  Future<void> recordV1Scan({
    required bool v1HistoryFound,
    required String? fingerprint,
  }) async {
    _snapshotState = SyncSnapshotState(
      nextSnapshotSequence: _snapshotState.nextSnapshotSequence,
      lastPublishedSequence: _snapshotState.lastPublishedSequence,
      lastPublishedHash: _snapshotState.lastPublishedHash,
      lastPublishedAt: _snapshotState.lastPublishedAt,
      v1ImportCompleted: _snapshotState.v1ImportCompleted,
      v1MigrationState: v1HistoryFound
          ? V1MigrationState.needsUpgradeConfirmation
          : _snapshotState.v1MigrationState,
      v1LastSeenFingerprint: fingerprint,
    );
  }

  @override
  Future<void> markV1ReadyToCutover() async {
    if (_snapshotState.v1MigrationState !=
        V1MigrationState.needsUpgradeConfirmation) {
      throw StateError('snapshot_v1_confirmation_not_required');
    }
    _snapshotState = SyncSnapshotState(
      nextSnapshotSequence: _snapshotState.nextSnapshotSequence,
      lastPublishedSequence: _snapshotState.lastPublishedSequence,
      lastPublishedHash: _snapshotState.lastPublishedHash,
      lastPublishedAt: _snapshotState.lastPublishedAt,
      v1ImportCompleted: _snapshotState.v1ImportCompleted,
      v1MigrationState: V1MigrationState.readyToCutover,
      v1LastSeenFingerprint: _snapshotState.v1LastSeenFingerprint,
    );
  }

  @override
  Future<void> markV1MigrationNotRequired() async {
    if (_snapshotState.v1MigrationState != V1MigrationState.notStarted) {
      throw StateError('snapshot_v1_migration_already_started');
    }
    _snapshotState = SyncSnapshotState(
      nextSnapshotSequence: _snapshotState.nextSnapshotSequence,
      lastPublishedSequence: _snapshotState.lastPublishedSequence,
      lastPublishedHash: _snapshotState.lastPublishedHash,
      lastPublishedAt: _snapshotState.lastPublishedAt,
      v1ImportCompleted: true,
      v1MigrationState: V1MigrationState.cutoverComplete,
      v1LastSeenFingerprint: _snapshotState.v1LastSeenFingerprint,
    );
  }

  @override
  Future<SyncSnapshotCursor?> loadSnapshotCursor(String deviceId) async =>
      _snapshotCursors[deviceId];
  @override
  Future<List<SyncSnapshotCursor>> loadSnapshotCursors() async =>
      _snapshotCursors.values.toList();
  @override
  Future<void> saveSnapshotCursor(SnapshotCursorAdvance cursor) async {
    final existing = _snapshotCursors[cursor.deviceId];
    if (existing != null) {
      if (cursor.sequence < existing.lastMergedSequence) {
        throw StateError('snapshot_cursor_regression');
      }
      if (cursor.sequence == existing.lastMergedSequence &&
          cursor.snapshotHash != existing.lastMergedHash) {
        throw StateError('snapshot_sequence_collision');
      }
    }
    _snapshotCursors[cursor.deviceId] = SyncSnapshotCursor(
      deviceId: cursor.deviceId,
      lastMergedSequence: cursor.sequence,
      lastMergedHash: cursor.snapshotHash,
      lastMergedAt: cursor.mergedAt,
    );
  }

  @override
  Future<void> saveVerifiedBlobMapping(SnapshotBlobMapping mapping) async {
    _snapshotBlobs.putIfAbsent(mapping.rawHash, () => {})[mapping.fileHash] =
        mapping;
  }

  @override
  Future<void> markSnapshotBlobMappingInvalid(
    String rawHash,
    String fileHash,
  ) async {
    final mapping = _snapshotBlobs[rawHash]?[fileHash];
    await saveVerifiedBlobMapping(
      SnapshotBlobMapping(
        rawHash: rawHash,
        fileHash: fileHash,
        rawLength: mapping?.rawLength ?? 0,
        verified: false,
        verifiedAt: DateTime.now(),
        source: mapping?.source ?? 'invalid',
      ),
    );
  }

  @override
  Future<List<SnapshotBlobMapping>> loadSnapshotBlobMappings(
    String rawHash,
  ) async =>
      (_snapshotBlobs[rawHash]?.values.toList() ?? [])
        ..sort((a, b) => a.fileHash.compareTo(b.fileHash));

  @override
  Future<List<SnapshotBlobMapping>> loadVerifiedBlobMappings(
    String rawHash,
  ) async =>
      (_snapshotBlobs[rawHash]?.values
                .where((mapping) => mapping.verified)
                .toList() ??
            [])
        ..sort((a, b) => a.fileHash.compareTo(b.fileHash));

  @override
  Future<void> applyRemoteBatch(RemoteApplyPlan plan) async {
    // 1) 校验阶段：只读，不触碰任何状态。
    final knownVersions = <SyncEntityKey, KnownSyncEntityVersion>{};
    for (final key in plan.entityVersions.map((v) => v.entity).toSet()) {
      final latest = _latestVersionFor(key);
      if (latest != null) {
        knownVersions[key] = latest;
      }
    }
    SyncPlanValidator.validate(
      plan: plan,
      appliedHashes: <String, String>{
        for (final entry in _applied.entries)
          entry.key: entry.value.payloadHash,
      },
      knownVersions: knownVersions,
    );
    if (plan.cursorAdvance != null) {
      await saveSnapshotCursor(plan.cursorAdvance!);
    }

    // 2) 构造阶段：全部新状态在本地算好，任何异常都不会留下半批数据。
    final nextVersions = <SyncEntityKey, List<SyncEntityVersion>>{
      for (final entry in _versions.entries)
        entry.key: List<SyncEntityVersion>.of(entry.value),
    };
    for (final version in plan.entityVersions) {
      final bucket = nextVersions.putIfAbsent(
        version.entity,
        () => <SyncEntityVersion>[],
      );
      // 同一 operationId 重放是幂等的：已存在的版本行原样保留。
      if (bucket.every(
        (existing) => existing.operationId != version.operationId,
      )) {
        bucket.add(version);
      }
    }
    // 已应用登记覆盖计划声称的每一个操作（可能不含实体版本），hash 取值与
    // SQLite 路径共用 plan.payloadHashForOperation，避免两条路径结论相反。
    final nextApplied = <String, ({String batchId, String payloadHash})>{
      ..._applied,
      for (final operationId in plan.appliedOperationIds)
        if (!_applied.containsKey(operationId))
          operationId: (
            batchId: plan.batchId,
            payloadHash: plan.payloadHashForOperation(operationId),
          ),
    };

    // 3) 提交阶段：仅做引用替换。
    _versions
      ..clear()
      ..addAll(nextVersions);
    if (plan.kvJournalValues.isEmpty) {
      _applied
        ..clear()
        ..addAll(nextApplied);
    }
    for (final version in plan.entityVersions) {
      _heads[version.entity] = version;
    }
    // Persist conflicts from the plan.
    for (final conflict in plan.conflicts) {
      if (_conflicts.every((c) => c.id != conflict.id)) {
        _conflicts.add(conflict);
      }
    }

    // KV journal：与 SqliteSyncRepository 同步——先记未应用行，重放时才真正
    // 写本地 KV，让 InMemoryLedgerRepository 也能驱动
    // `applySyncPreferenceJournal()` 的测试路径。
    _kvJournal.removeWhere((e) => plan.completedPendingIds.contains(e.batchId));
    for (final id in plan.completedPendingIds) {
      _prepared.remove(id);
    }
    for (final entry in plan.kvJournalValues.entries) {
      _kvJournal.add(
        KvJournalEntry(
          id: _kvJournalNextId++,
          batchId: plan.batchId,
          key: entry.key,
          value: entry.value,
          targetHash: computeSyncPayloadHash(entry.value),
          expectedHash:
              plan.kvExpectedHashes[entry.key] ?? computeSyncPayloadHash(null),
        ),
      );
    }

    // Update shadow from plan's shadowHashes so the next causality check
    // within the same scan cycle sees the freshly applied state.
    for (final entry in plan.shadowHashes.entries) {
      try {
        final key = decodeSyncEntityKey(entry.key);
        _shadow[key] = entry.value;
      } catch (_) {
        // Ignore malformed keys — do not block the whole apply.
      }
    }

    if (plan.kvJournalValues.isEmpty) {
      _finalize(plan);
    } else if (plan.kvJournalValues.isNotEmpty) {
      _prepared[plan.batchId] = plan;
      _pendingBatches[plan.batchId] = SyncPendingBatch(
        batchId: plan.batchId,
        events: [
          for (final v in plan.entityVersions)
            SyncEvent(
              protocolVersion: syncProtocolVersion,
              operationId: v.operationId,
              version: v.version,
              entity: v.entity,
              operation: v.deleted
                  ? SyncOperationKind.delete
                  : SyncOperationKind.upsert,
              payloadHash: v.payloadHash,
              payload: v.payload,
              batchId: plan.batchId,
              keyFingerprint: 'local',
            ),
        ],
        reason: 'prepared',
      );
    }
  }

  @override
  Future<SyncScanState> loadScanState() async => _scanState;

  @override
  Future<void> saveScanState(SyncScanState state) async {
    _scanState = state;
  }

  @override
  Future<List<SyncConflictRecord>> loadConflicts() async =>
      List<SyncConflictRecord>.of(_conflicts);

  @override
  Future<void> storeConflict(SyncConflictRecord conflict) async {
    _conflicts.removeWhere((c) => c.id == conflict.id);
    _conflicts.add(conflict);
  }

  @override
  Future<void> removeConflict(String conflictId) async {
    _conflicts.removeWhere((c) => c.id == conflictId);
  }

  @override
  Future<List<KvJournalEntry>> loadPendingKvJournal() async => <KvJournalEntry>[
    for (final entry in _kvJournal)
      if (!_kvJournalApplied.contains(entry.id)) entry,
  ];

  @override
  Future<void> markKvJournalApplied(int id) async {
    _kvJournalApplied.add(id);
  }

  /// shadow 的内存镜像。语义与 SQLite 实现一致：整体替换，不合并。
  final Map<SyncEntityKey, String> _shadow = <SyncEntityKey, String>{};

  @override
  Future<Map<SyncEntityKey, String>> loadShadow() async =>
      Map<SyncEntityKey, String>.of(_shadow);

  @override
  Future<void> saveShadow(Map<SyncEntityKey, String> shadow) async {
    _shadow
      ..clear()
      ..addAll(shadow);
  }

  KnownSyncEntityVersion? _latestVersionFor(SyncEntityKey key) {
    final bucket = _versions[key];
    if (bucket == null || bucket.isEmpty) {
      return null;
    }
    var latest = bucket.first;
    for (final version in bucket.skip(1)) {
      if (version.version.logicalTime >= latest.version.logicalTime) {
        latest = version;
      }
    }
    return KnownSyncEntityVersion(
      entity: key,
      operationId: latest.operationId,
      version: latest.version,
      deleted: latest.deleted,
    );
  }
}

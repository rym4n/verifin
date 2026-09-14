import 'package:verifin/app/models.dart';
import 'package:verifin/app/sync/sync_change_tracker.dart';
import 'package:verifin/app/sync/sync_models.dart';
import 'package:verifin/app/sync/sync_projection.dart';
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
    return {
      if (_profile.isNotEmpty) 'profile': _profile,
      if (_entries.isNotEmpty)
        'entries': _entries
            .map(
              (e) => {
                'id': e.id,
                'amount': e.amount,
                // Add other fields as needed
              },
            )
            .toList(),
      // Add other entities as needed
    };
  }

  @override
  Future<void> waitForPendingWrites() async {
    // No async writes in memory implementation
  }

  // Test helper methods
  void setProfile(Map<String, Object?> profile) {
    _profile = Map<String, Object?>.from(profile);
  }

  void addEntry(Map<String, Object?> entryData) {
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
        ),
      );
    }
  }

  @override
  Future<void> markBatchUploaded(String batchId) async {
    _outbox.removeWhere((record) => record.batchId == batchId);
  }

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
    _applied
      ..clear()
      ..addAll(nextApplied);
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

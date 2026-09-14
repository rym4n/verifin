import 'sync_models.dart';

/// 同步元数据仓储边界。生产实现挂在 [SqliteLedgerRepository]（`sqlite_sync_store.dart`），
/// 测试用内存实现挂在 `InMemoryLedgerRepository`，两者共享本文件的校验逻辑，
/// 避免「生产拒绝、测试放过」这类语义分叉。
///
/// 语义约定：
/// - [loadDeviceState] 在从未写入过时返回「空身份」（deviceId 为空、序列从 1 起）。
///   真正的设备身份由 `SyncClock` 持有并在初始化时写入，仓储不自行生成。
/// - [loadOutbox] 只返回尚未标记上传的记录。
/// - [applyRemoteBatch] 在单个事务内写入 sync_entity_versions/sync_shadow/
///   sync_apply_journal/sync_conflicts 与 sync_applied_ops；任何校验失败都整批不落库。
abstract interface class SyncRepository {
  Future<SyncDeviceState> loadDeviceState();
  Future<void> saveDeviceState(SyncDeviceState state);

  Future<List<SyncOutboxRecord>> loadOutbox();
  Future<void> enqueueBatch(SyncBatchRecord batch);
  Future<void> markBatchUploaded(String batchId);

  Future<void> applyRemoteBatch(RemoteApplyPlan plan);

  Future<SyncScanState> loadScanState();
  Future<void> saveScanState(SyncScanState state);

  Future<List<SyncConflictRecord>> loadConflicts();

  /// 读取当前 `sync_shadow`：实体键 → 规范化 payload hash。
  ///
  /// shadow 是「上一次已知的投影」，`SyncChangeTracker.reconcile()` 用它做本地
  /// 变更检测。**只存 hash 不存 payload**：变更判定只需要「是否与已知一致」，
  /// 旧 payload 体积随账目增长而膨胀，且远端应用本就是合并而非回读。
  ///
  /// 键编码走 [encodeSyncEntityKey] / [decodeSyncEntityKey]，与
  /// [RemoteApplyPlan.shadowHashes] 同一格式，调用方不要自行拼接。
  Future<Map<SyncEntityKey, String>> loadShadow();

  /// 整体替换 `sync_shadow`。
  ///
  /// **语义是替换而非合并**：调用方传入的必须是「本次投影的完整结果」。
  /// 若只传差异，上一轮被删除的实体行会残留，下一轮 reconcile 会把同一个删除
  /// 反复判成新变更。实现方在单事务内先清空再写入，保证不会读到半份 shadow。
  Future<void> saveShadow(Map<SyncEntityKey, String> shadow);
}

/// 远端批次与本地已落库状态互斥时抛出。调用方据此保留 pending 并提示用户，
/// 而不是静默覆盖——同步协议要求「并发版本同时保存，由用户决议」。
class SyncConflictException implements Exception {
  const SyncConflictException(this.message, {this.operationId});

  final String message;

  /// 触发冲突的操作 id（如果有具体到单个操作）。
  final String? operationId;

  @override
  String toString() => operationId == null
      ? 'SyncConflictException: $message'
      : 'SyncConflictException($operationId): $message';
}

/// 实体键 → shadow map 键的规范编码：`"scope|type|id"`（竖线分隔）。
///
/// [RemoteApplyPlan.shadowHashes] 是扁平 `Map<String, String>`，而 sync_shadow
/// 以 (scope, type, id) 三列为主键，因此需要一个确定且可逆的字符串编码。
/// 编码格式属于协议约定（由 team lead 明确指定），计划构造方必须用本函数生成键，
/// 不要各写各的拼接。
///
/// 约束：scope/type/id 的取值中不得出现 `|`。三者的取值域是内部固定的枚举式标识
/// （`default`、`entry`、`account`、`themePreference` 之类的字段名或实体 id），
/// 不含竖线；[decodeSyncEntityKey] 在遇到多于两段时抛 [FormatException] 而非
/// 猜测切分点，使违约尽早暴露而不是把数据静默写到错误的实体上。
String encodeSyncEntityKey(SyncEntityKey key) =>
    '${key.scope}|${key.type}|${key.id}';

/// [encodeSyncEntityKey] 的逆运算。
///
/// 只按**前两个**竖线切分，因此 id 里若混入竖线仍能还原出正确 scope/type，
/// 只是 id 会被整体保留（不会截断）。真正无法解析的是段数不足，或任一段为空——
/// 这两种情况抛 [FormatException]，不静默丢弃：丢弃会让 shadow 与实体版本对不上，
/// 后续把已应用的远端变更误报成本地新变更。
SyncEntityKey decodeSyncEntityKey(String encoded) {
  final firstSeparator = encoded.indexOf('|');
  final secondSeparator = firstSeparator < 0
      ? -1
      : encoded.indexOf('|', firstSeparator + 1);
  if (firstSeparator <= 0 || secondSeparator <= firstSeparator + 1) {
    throw FormatException('Invalid sync entity key encoding: $encoded');
  }
  final scope = encoded.substring(0, firstSeparator);
  final type = encoded.substring(firstSeparator + 1, secondSeparator);
  final id = encoded.substring(secondSeparator + 1);
  if (id.isEmpty) {
    throw FormatException('Invalid sync entity key encoding: $encoded');
  }
  return SyncEntityKey(scope: scope, type: type, id: id);
}

/// 一条已应用的远端操作（去重与哈希校验所需的最少字段）。
class AppliedSyncOperation {
  const AppliedSyncOperation({
    required this.operationId,
    required this.payloadHash,
  });

  final String operationId;
  final String payloadHash;
}

/// 已落库实体版本的因果快照（tombstone 回退判定所需的最少字段）。
class KnownSyncEntityVersion {
  const KnownSyncEntityVersion({
    required this.entity,
    required this.operationId,
    required this.version,
    required this.deleted,
  });

  final SyncEntityKey entity;
  final String operationId;
  final SyncVersion version;
  final bool deleted;
}

/// SQLite 与内存实现共享的 [RemoteApplyPlan] 校验。
///
/// 校验分三层，顺序固定，任何一层失败都不产生副作用：
/// 1. 幂等：同一 operationId 已应用且 payload hash 不同 → 拒绝（协议冲突）。
/// 2. 因果：传入版本严格早于该实体当前版本 → 拒绝（tombstone/编辑回退）。
/// 3. 一致：批次内自相矛盾（同一 operationId 出现两个不同 hash）→ 拒绝。
///
/// 校验在写入前一次性完成，是实现「整批原子」的前提：内存实现据此先验后写，
/// SQLite 实现在事务内先验后写，两者行为一致。
abstract final class SyncPlanValidator {
  /// 校验整个计划，失败即抛 [SyncConflictException]。无副作用。
  ///
  /// [appliedHashes] 必须覆盖计划声称的**每一个**
  /// [RemoteApplyPlan.appliedOperationIds]，来源是 `sync_applied_ops`
  /// （「已应用」的唯一真相），hash 取值统一走
  /// [RemoteApplyPlan.payloadHashForOperation]。
  static void validate({
    required RemoteApplyPlan plan,
    required Map<String, String> appliedHashes,
    required Map<SyncEntityKey, KnownSyncEntityVersion> knownVersions,
  }) {
    void checkNotAlreadyApplied(String operationId, String payloadHash) {
      final applied = appliedHashes[operationId];
      if (applied != null && applied != payloadHash) {
        throw SyncConflictException(
          '操作已应用且载荷 hash 不同：已应用 $applied，传入 $payloadHash',
          operationId: operationId,
        );
      }
    }

    // 已应用判定独立于 entityVersions 单独走一遍：纯 KV 批次、决议事件等没有实体
    // 版本行，只遍历 entityVersions 会漏掉它们，让「同 operationId 不同 hash」通过。
    for (final operationId in plan.appliedOperationIds) {
      checkNotAlreadyApplied(
        operationId,
        plan.payloadHashForOperation(operationId),
      );
    }

    final plannedHashes = <String, String>{};
    for (final version in plan.entityVersions) {
      final operationId = version.operationId;

      final inBatch = plannedHashes[operationId];
      if (inBatch != null && inBatch != version.payloadHash) {
        throw SyncConflictException(
          '批次 ${plan.batchId} 内同一 operationId 出现两个不同载荷 hash',
          operationId: operationId,
        );
      }
      plannedHashes[operationId] = version.payloadHash;

      checkNotAlreadyApplied(operationId, version.payloadHash);

      final known = knownVersions[version.entity];
      if (known != null && known.operationId != operationId) {
        final causality = version.version.context.compare(
          known.version.context,
        );
        if (causality == SyncCausality.before) {
          throw SyncConflictException(
            '版本因果回退：${version.entity} 当前版本为 '
            '${known.version.context}，传入 ${version.version.context}',
            operationId: operationId,
          );
        }
      }
    }
  }
}

/// 由 [RemoteApplyPlan.shadowHashes] 展开出的 shadow 行。
Iterable<({SyncEntityKey key, String payloadHash})> shadowRowsOf(
  RemoteApplyPlan plan,
) sync* {
  for (final entry in plan.shadowHashes.entries) {
    yield (key: decodeSyncEntityKey(entry.key), payloadHash: entry.value);
  }
}

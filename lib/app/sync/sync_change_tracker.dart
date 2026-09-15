import 'dart:async';

import 'sync_clock.dart';
import 'sync_models.dart';
import 'sync_projection.dart';
import 'sync_store.dart';

/// 控制器向同步层暴露的最小读接口：只要「当前导出快照」一项。
///
/// 用接口而不是直接依赖 `VeriFinController`，是为了让变更追踪器可以脱离控制器
/// 单测（伪造一份投影即可覆盖崩溃恢复、防抖、远端抑制等分支），同时不给
/// controller 增加公开 API 面。
abstract interface class SyncProjectionSource {
  /// 当前全量数据，形状与 `exportDataJson()` 的输出一致。
  Map<String, Object?> exportDataForSync();

  /// 等待调用前已发起的业务写入落库。
  ///
  /// 读取投影时必须先等：账目写入是 fire-and-forget 的，比较若插在「内存已改、
  /// 库未写」之间进行，会把一次写入的中间态当成本次投影，并与随后真正落库的状态
  /// 产生一次多余却真实的差异。等待后投影与存储一致，比较结果才有意义。
  Future<void> waitForPendingWrites();
}

/// 本地变更捕获：把「当前投影」与最后一次已知投影（`sync_shadow`）比较，
/// 把差异写进 outbox。
///
/// 为什么是「比较」而不是「在每个写路径上记录增量」：
/// - 写路径分散在 controller 的几十个方法里，逐个改成发事件既容易漏，也无法覆盖
///   SQLite 与 KV 两条不同的持久化路径；
/// - 投影比较天然覆盖「派生字段重算」「分类自愈」这类隐式改写；
/// - 用 shadow 做基准后，进程在上传前退出只会在下次启动时补出事件，不会丢。
///
/// 代价是每次比较要遍历全量实体。用 hash 比较而非深度比较，实际开销是 O(实体数)
/// 次 SHA-256，远小于一次导出 JSON 的序列化成本。
class SyncChangeTracker {
  SyncChangeTracker({
    required SyncProjectionSource controller,
    required SyncRepository repository,
    required SyncClock clock,
    Duration debounce = const Duration(milliseconds: 500),
    // 私有字段不能作具名初始化形参（`this._controller` 会成为 `_controller:` 形参名），
    // 与项目既有 veri_fin_controller.dart、sync_clock.dart 同一处 ignore。
    // ignore: prefer_initializing_formals
  }) : _controller = controller,
       // ignore: prefer_initializing_formals
       _repository = repository,
       // ignore: prefer_initializing_formals
       _clock = clock,
       // ignore: prefer_initializing_formals
       _debounce = debounce;

  final SyncProjectionSource _controller;
  final SyncRepository _repository;
  final SyncClock _clock;
  final Duration _debounce;

  /// 远端同步引擎（Task 5）会读它来标注事件来源；这里保证它是可用且唯一的钟。
  SyncClock get clock => _clock;

  Timer? _debounceTimer;
  bool _reconciling = false;
  bool _rerunRequested = false;

  /// rerun 时是否只对齐 shadow 而不入队。
  ///
  /// 在 `_reconciling` 为 true 时到达的 `reconcile(alignShadowOnly: true)` 调用无法
  /// 立即执行，只能设位等待下一轮。若此时用原始调用的 `alignShadowOnly: false` 跑
  /// rerun，会把远端应用的结果当成本地新变更入队——这正是 `alignShadowOnly` 存在的
  /// 原因。因此要单独记录「有没有人请求了对齐模式」，并在 rerun 时取 OR：任何一个
  /// 调用方想要对齐模式，rerun 就必须用对齐模式（对齐比入队更保守，不会丢变更）。
  bool _rerunAlignShadowOnly = false;

  int _remoteApplyDepth = 0;

  /// 首次比较只建立基线、不入队。见 [_reconcileOnce] 的说明。
  bool _baselinePending = true;

  /// 是否处于「远端批次应用」窗口内。窗口内 [reconcile] 直接返回，不产生 outbox。
  bool get remoteApplyActive => _remoteApplyDepth > 0;

  /// 每台设备只进行一次设备状态对齐，避免每个 tracker 都写库。
  bool _deviceStateRestored = false;

  /// 与 `sync_shadow` 对齐并产出缺失的本地事件。
  ///
  /// [alignShadowOnly] 为 true 时只推进 shadow、绝不入队 outbox。远端批次应用期间
  /// 必须用这个模式：那时业务数据刚被远端结果改写，投影与 shadow 的差异**不是**
  /// 本地变更，推进 shadow 是为了让窗口关闭后不把它当成本地新变更回传。
  ///
  /// 提交顺序是**先 outbox 后 shadow**：shadow 代表「已确认写进 outbox 的投影」，
  /// 若先推进 shadow 再入队失败，那次变更就永久丢失（下次比较看不到差异）。
  /// 反过来（先入队后 shadow）最坏情况是同一条变更被重复入队，而事件带
  /// `operationId`，重复入队会被远端按操作去重，是可接受的一侧。
  Future<void> reconcile({bool alignShadowOnly = false}) async {
    if (_reconciling) {
      // 正在比较时到达的新请求不能在结束时丢：置位让本次结束后再跑一轮。
      _rerunRequested = true;
      // 对齐意图取 OR：任何一个调用方请求了 alignShadowOnly，rerun 就必须用对齐
      // 模式。反之则不行——把 alignShadowOnly=true 的请求吞掉并以普通模式重跑，
      // 会把远端应用的结果当成本地新变更入队，产生回声。
      _rerunAlignShadowOnly = _rerunAlignShadowOnly || alignShadowOnly;
      return;
    }
    if (remoteApplyActive && !alignShadowOnly) {
      // 远端应用期间不接受普通比较；应用完成后由调用方以对齐模式收口。
      return;
    }
    _reconciling = true;
    try {
      var align = alignShadowOnly;
      do {
        _rerunRequested = false;
        _rerunAlignShadowOnly = false;
        await _reconcileOnce(alignShadowOnly: align);
        // rerun 时继承本轮结束前收到的对齐意图。
        align = _rerunAlignShadowOnly;
      } while (_rerunRequested && !remoteApplyActive);
    } finally {
      _reconciling = false;
    }
  }

  Future<void> _reconcileOnce({required bool alignShadowOnly}) async {
    await _restoreDeviceState();
    // 先等业务写入落库，再读投影：中间态比较会产出多余差异。
    await _controller.waitForPendingWrites();

    final shadow = await _repository.loadShadow();
    final snapshot = SyncProjection.fromExportData(
      _controller.exportDataForSync(),
    );
    final currentHashes = snapshot.payloadHashes;

    // 差异基准是 shadow 而不是空投影：键在 shadow 缺失 → 新增；hash 不同 → 修改；
    // shadow 有而投影没有 → 删除（显式 tombstone，不靠远端缺文件推断）。
    final batchId = _clock.nextOperationId();
    final changedKeys = <SyncEntityKey>[
      for (final entry in currentHashes.entries)
        if (shadow[entry.key] != entry.value) entry.key,
    ]..sort(_compareKeys);
    final deletedKeys = <SyncEntityKey>[
      for (final key in shadow.keys)
        if (!currentHashes.containsKey(key)) key,
    ]..sort(_compareKeys);

    if (changedKeys.isEmpty && deletedKeys.isEmpty) {
      // 无差异也要落一次 shadow：首次启动需要建立基线，否则每次启动都要重跑一次
      // 全量比较；两边都空时这也是唯一的落库时机。
      _baselinePending = false;
      await _repository.saveShadow(currentHashes);
      return;
    }

    if (alignShadowOnly) {
      // 远端批次应用期间的对齐：业务数据已被远端结果改写，差异**不是**本地变更。
      // 推进 shadow 让窗口关闭后不再把它当成本地新变更回传。
      await _repository.saveShadow(currentHashes);
      return;
    }

    if (_baselinePending) {
      // 本进程的第一次比较：此刻的本地数据是**当前状态**而非「待上传的变更」。
      // 整库上传既不是协议要求（首次启用由 `initializeFromRestoredData()` 生成基线
      // 批次），远端非空时还会造成覆盖。故只建立基线。
      //
      // 判定用进程内标志位而不是「shadow 是否为空」：tracker 由同步引擎创建，
      // 只在同步启用后才存在，因此进程内的第一次比较必然等于基线那次；而
      // 「shadow 空」在正常后续运行中已不可能出现（每次都写全量），用标志位表述的是
      // 同一件事且不依赖存储内容做控制流。
      _baselinePending = false;
      await _repository.saveShadow(currentHashes);
      return;
    }

    final events = <SyncEvent>[
      for (final key in changedKeys)
        _buildEvent(
          entity: key,
          operation: SyncOperationKind.upsert,
          payload: snapshot.entity(key)!.payload,
          payloadHash: currentHashes[key]!,
          batchId: batchId,
        ),
      for (final key in deletedKeys)
        _buildEvent(
          entity: key,
          operation: SyncOperationKind.delete,
          payload: null,
          payloadHash: computeSyncPayloadHash(null),
          batchId: batchId,
        ),
    ];

    final batch = SyncBatchRecord(
      batchId: batchId,
      events: events,
      manifest: SyncBatchManifest(
        batchId: batchId,
        operationIds: <String>[for (final event in events) event.operationId],
        // 附件 blob 的上传清单由 Task 4/5 的传输层补齐；变更捕获只负责事件。
        blobHashes: const <String>[],
        manifestHash: _manifestHash(batchId, events),
      ),
    );

    // 入队失败时不推进 shadow（下方 saveShadow 不会执行）：下次比较会重新发现
    // 同一批差异并重试。
    await _repository.enqueueBatch(batch);
    await _repository.saveShadow(currentHashes);
  }

  /// 标记一次本地写入，防抖后比较。
  ///
  /// 防抖而不是立刻比较：一次用户操作往往连写多张表（交易 + 退款 + 附件），逐次
  /// 比较会把一次操作放大成多个批次，也让 outbox 里出现大量可合并的事件。
  void markLocalMutation() {
    if (remoteApplyActive) {
      return;
    }
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounce, () {
      _debounceTimer = null;
      unawaited(reconcile());
    });
  }

  /// 进入「远端应用」窗口。窗口内的一切本地写都视为远端结果，不产生 outbox。
  ///
  /// 必须成对使用：见 [clearRemoteApply]。
  void markRemoteApply() {
    _remoteApplyDepth++;
    _debounceTimer?.cancel();
    _debounceTimer = null;
  }

  /// 退出远端应用窗口。退出后调用方应显式 [reconcile] 一次，把 shadow 推进到
  /// 远端应用后的状态——否则被抑制的远端变更会在下一轮被误判成本地新变更。
  void clearRemoteApply() {
    if (_remoteApplyDepth == 0) {
      return;
    }
    _remoteApplyDepth--;
  }

  /// 等待防抖到期并完成一次比较。测试与「应用切后台/退出前的收口」用。
  Future<void> flush() async {
    _debounceTimer?.cancel();
    _debounceTimer = null;
    await reconcile();
  }

  /// 释放定时器。控制器 `dispose()` 时调用，避免测试间残留定时器。
  void dispose() {
    _debounceTimer?.cancel();
    _debounceTimer = null;
  }

  SyncEvent _buildEvent({
    required SyncEntityKey entity,
    required SyncOperationKind operation,
    required Object? payload,
    required String payloadHash,
    required String batchId,
  }) {
    final version = _clock.nextVersion(known: _clock.knownVector);
    return SyncEvent(
      protocolVersion: syncProtocolVersion,
      operationId: _clock.nextOperationId(),
      version: version,
      entity: entity,
      operation: operation,
      payloadHash: payloadHash,
      payload: payload,
      batchId: batchId,
      // 口令指纹由同步引擎在构造批次时填入；变更捕获不持有加密口令。
      keyFingerprint: '',
    );
  }

  /// 设备状态只在第一次比较时对齐一次。
  ///
  /// `SyncClock.create()` 从 KV 恢复序列号，而 `sync_device` 是权威行（包含其他设备
  /// 的已知向量）。若库里已有记录就据此恢复，避免序列号在重装 KV 后被重置而
  /// 与远端已见的 sequence 碰撞。
  Future<void> _restoreDeviceState() async {
    if (_deviceStateRestored) {
      return;
    }
    _deviceStateRestored = true;
    final state = await _repository.loadDeviceState();
    if (state.deviceId.isEmpty) {
      await _repository.saveDeviceState(_clock.getState());
      return;
    }
    if (state.deviceId == _clock.deviceId) {
      _clock.restoreState(state);
      return;
    }
    // 设备 id 不一致：库里那份属于别的设备身份（例如换了设备但复用了数据库）。
    // 不覆盖时钟身份，以 KV 中的身份为准并写回，避免两个设备共用一份序列。
    await _repository.saveDeviceState(_clock.getState());
  }

  static String _manifestHash(String batchId, List<SyncEvent> events) {
    return computeSyncPayloadHash(<String, Object?>{
      'batchId': batchId,
      'operationIds': <String>[for (final event in events) event.operationId],
      'payloadHashes': <String>[for (final event in events) event.payloadHash],
    });
  }

  static int _compareKeys(SyncEntityKey a, SyncEntityKey b) {
    final byScope = a.scope.compareTo(b.scope);
    if (byScope != 0) return byScope;
    final byType = a.type.compareTo(b.type);
    if (byType != 0) return byType;
    return a.id.compareTo(b.id);
  }
}

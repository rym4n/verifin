// 同步冲突审阅页：列出未决冲突，展示两侧版本差异，并让用户逐条决议。
//
// 设计约束：
// - 只展示「人能读懂的字段摘要」，绝不把原始 payload JSON 或密文渲染到界面；
//   未知字段一律回退为本地化的占位摘要，宁可少显示也不泄露内部结构。
// - 派生缓存字段（`refundedBaseAmount`）不参与对比——它由已到账退款重算，
//   两侧各带一份缓存值互相覆盖没有意义（见 docs/dev/refund-design.md）。
// - 金额一律经 `formatAmount` 等既有 helper 渲染，与其他页面的口径一致。
import 'dart:async';

import 'package:flutter/material.dart';

import '../app/app_theme.dart';
import '../app/common_widgets.dart';
import '../app/feedback.dart';
import '../app/ledger_math.dart';
import '../app/models.dart';
import '../app/sync/sync_conflict.dart';
import '../app/sync/sync_models.dart';
import '../app/veri_fin_scope.dart';
import '../l10n/app_localizations.dart';

/// 冲突两侧的展示摘要：字段名 → 已本地化/已格式化的值。
///
/// 值为 null 表示该字段在这一侧不存在（例如一侧是删除操作）。
typedef SyncConflictPayloadSummary = Map<String, String>;

/// 冲突审阅页。壳是无状态的：真正的加载与决议状态在 [_SyncConflictsBody]。
class SyncConflictsPage extends StatelessWidget {
  const SyncConflictsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: VeriPage(
          child: _SyncConflictsBody(
            title: AppLocalizations.of(context).syncConflictsTitle,
          ),
        ),
      ),
    );
  }
}

class _SyncConflictsBody extends StatefulWidget {
  const _SyncConflictsBody({required this.title});

  final String title;

  @override
  State<_SyncConflictsBody> createState() => _SyncConflictsBodyState();
}

class _SyncConflictsBodyState extends State<_SyncConflictsBody> {
  List<SyncConflict>? _conflicts;
  bool _loading = true;
  bool _failed = false;

  /// 正在决议中的冲突 id：期间禁用该卡片的全部按钮，避免重复提交。
  final Set<String> _busy = <String>{};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_conflicts == null && !_failed) {
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final controller = VeriFinScope.of(context);
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final conflicts = await controller.loadSyncConflicts();
      if (!mounted) return;
      setState(() {
        _conflicts = conflicts;
        _loading = false;
      });
    } catch (error) {
      controller.logger?.error('读取同步冲突失败', source: 'sync', error: error);
      if (!mounted) return;
      setState(() {
        _failed = true;
        _loading = false;
      });
    }
  }

  /// 应用一条决议。成功后就地刷新列表——冲突计数必须立刻反映最新的未决数量，
  /// 否则用户会以为决议没生效。
  Future<void> _resolve(
    SyncConflict conflict,
    ConflictResolution resolution,
  ) async {
    final controller = VeriFinScope.of(context);
    final l10n = AppLocalizations.of(context);
    final feedback = VeriFeedbackHost.of(context);
    setState(() => _busy.add(conflict.id));
    try {
      await controller.resolveSyncConflict(conflict.id, resolution);
      if (!mounted) return;
      await _load();
      if (!mounted) return;
      unawaited(
        feedback.showMessage(
          message: l10n.syncConflictResolved,
          tone: VeriFeedbackTone.success,
        ),
      );
    } catch (error) {
      controller.logger?.error('同步冲突决议失败', source: 'sync', error: error);
      if (!mounted) return;
      unawaited(
        feedback.showMessage(
          message: l10n.syncConflictResolveFailed,
          tone: VeriFeedbackTone.error,
          duration: VeriFeedbackDuration.long,
          priority: VeriFeedbackPriority.high,
          dedupeKey: 'sync-conflict-resolve',
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _busy.remove(conflict.id));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final conflicts = _conflicts ?? const <SyncConflict>[];
    return Column(
      children: <Widget>[
        VeriHeader(
          title: widget.title,
          subtitle: l10n.syncConflictsSubtitle,
          showBack: true,
        ),
        Expanded(child: _buildBody(context, conflicts)),
      ],
    );
  }

  Widget _buildBody(BuildContext context, List<SyncConflict> conflicts) {
    final l10n = AppLocalizations.of(context);
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_failed) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                Icons.error_outline,
                size: 44,
                color: veriSemantic(context, veriExpense),
              ),
              const SizedBox(height: 12),
              Text(
                l10n.syncConflictsLoadFailed,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 14),
              FilledButton(
                onPressed: () => unawaited(_load()),
                child: Text(l10n.syncConflictsRetry),
              ),
            ],
          ),
        ),
      );
    }
    if (conflicts.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                Icons.check_circle_outline,
                size: 44,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: 12),
              Text(
                l10n.syncConflictsEmpty,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 28),
      itemCount: conflicts.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final conflict = conflicts[index];
        return SyncConflictCard(
          conflict: conflict,
          busy: _busy.contains(conflict.id),
          onResolve: (resolution) => unawaited(_resolve(conflict, resolution)),
        );
      },
    );
  }
}

/// 单条冲突卡片：实体标识 + 两侧版本对比 + 决议动作。
class SyncConflictCard extends StatelessWidget {
  const SyncConflictCard({
    super.key,
    required this.conflict,
    required this.onResolve,
    this.busy = false,
  });

  final SyncConflict conflict;
  final ValueChanged<ConflictResolution> onResolve;

  /// 决议提交中：按钮禁用，防止同一条冲突被提交两次。
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final controller = VeriFinScope.of(context);
    final localSummary = summarizeSyncConflictPayload(
      l10n,
      conflict.localPayload,
      conflict.entity.type,
      accounts: controller.accounts,
      categories: controller.categories,
    );
    final remoteSummary = summarizeSyncConflictPayload(
      l10n,
      conflict.remotePayload,
      conflict.entity.type,
      accounts: controller.accounts,
      categories: controller.categories,
    );
    final rows = compareSyncConflictPayloads(localSummary, remoteSummary);

    return VeriCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _buildHeader(context, l10n),
          const SizedBox(height: 10),
          _buildVersionMeta(
            context,
            l10n,
            label: l10n.syncConflictLocalVersion,
            version: conflict.localVersion,
            deleted: conflict.localDeleted,
          ),
          const SizedBox(height: 6),
          _buildVersionMeta(
            context,
            l10n,
            label: l10n.syncConflictRemoteVersion,
            version: conflict.remoteVersion,
            deleted: conflict.remoteDeleted,
          ),
          if (rows.isNotEmpty) ...<Widget>[
            const SizedBox(height: 10),
            const Divider(height: 1),
            const SizedBox(height: 8),
            for (final row in rows) _buildDiffRow(context, row),
          ],
          const SizedBox(height: 12),
          _buildActions(context, l10n),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context, AppLocalizations l10n) {
    final theme = Theme.of(context);
    final scopeLabel = formatSyncConflictScope(l10n, conflict);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: veriSemantic(context, veriExpense).withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(veriRadiusSm),
          ),
          child: Icon(
            Icons.sync_problem_outlined,
            size: 20,
            color: veriSemantic(context, veriExpense),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                syncEntityTypeLabel(l10n, conflict.entity.type),
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                scopeLabel,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 一侧版本的来源与时序信息：源设备、序列号、逻辑时钟。
  Widget _buildVersionMeta(
    BuildContext context,
    AppLocalizations l10n, {
    required String label,
    required SyncVersion version,
    required bool deleted,
  }) {
    final theme = Theme.of(context);
    final mutedStyle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final parts = <String>[
      l10n.syncConflictSourceDevice(version.dot.deviceId),
      l10n.syncConflictSequence(version.dot.sequence),
      formatSyncConflictLogicalTime(l10n, version.logicalTime),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (deleted) ...<Widget>[
              const SizedBox(width: 6),
              Text(
                l10n.syncConflictDeletedMarker,
                style: theme.textTheme.labelSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: veriSemantic(context, veriExpense),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 2),
        Text(parts.join(' · '), style: mutedStyle),
      ],
    );
  }

  Widget _buildDiffRow(BuildContext context, SyncConflictDiffRow row) {
    final theme = Theme.of(context);
    final a = row.local ?? AppLocalizations.of(context).syncConflictAbsent;
    final b = row.remote ?? AppLocalizations.of(context).syncConflictAbsent;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 88,
            child: Text(
              row.label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(a, style: theme.textTheme.bodySmall),
                Text(
                  b,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: veriSemantic(context, veriRoyal),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActions(BuildContext context, AppLocalizations l10n) {
    final oneDeleted = conflict.localDeleted || conflict.remoteDeleted;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        if (!oneDeleted) ...<Widget>[
          _actionButton(
            context,
            label: l10n.syncConflictKeepLocal,
            onPressed: () => onResolve(ConflictResolution.keepLocal),
          ),
          _actionButton(
            context,
            label: l10n.syncConflictKeepRemote,
            onPressed: () => onResolve(ConflictResolution.keepRemote),
          ),
        ] else ...<Widget>[
          // 一侧已删除：真正的抉择是「保留删除」还是「保留另一侧的编辑」，
          // 此时再给出 keepLocal/keepRemote 只会让用户猜那一侧是不是被删的那侧。
          _actionButton(
            context,
            label: l10n.syncConflictKeepDelete,
            destructive: true,
            onPressed: () => onResolve(ConflictResolution.keepDelete),
          ),
          _actionButton(
            context,
            label: l10n.syncConflictKeepEdit,
            onPressed: () => onResolve(ConflictResolution.keepEdit),
          ),
        ],
        _actionButton(
          context,
          label: l10n.commonCancel,
          onPressed: () => onResolve(ConflictResolution.cancel),
        ),
      ],
    );
  }

  Widget _actionButton(
    BuildContext context, {
    required String label,
    required VoidCallback onPressed,
    bool destructive = false,
  }) {
    return OutlinedButton(
      onPressed: busy ? null : onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: destructive
            ? veriSemantic(context, veriExpense)
            : veriSemantic(context, veriRoyal),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        minimumSize: const Size(0, 34),
      ),
      child: Text(label),
    );
  }
}

/// 一条差异行：字段名 + 两侧值（null 表示该侧无此字段）。
class SyncConflictDiffRow {
  const SyncConflictDiffRow({
    required this.label,
    required this.local,
    required this.remote,
  });

  final String label;
  final String? local;
  final String? remote;
}

/// 实体类型 → 本地化名称。未知类型回退到通用文案，不把内部 type 串暴露出去。
String syncEntityTypeLabel(AppLocalizations l10n, String type) {
  switch (type) {
    case 'entries':
      return l10n.syncEntityEntries;
    case 'accounts':
      return l10n.syncEntityAccounts;
    case 'accountGroups':
      return l10n.syncEntityAccountGroups;
    case 'categories':
      return l10n.syncEntityCategories;
    case 'tags':
      return l10n.syncEntityTags;
    case 'attachments':
      return l10n.syncEntityAttachments;
    case 'recurringRules':
      return l10n.syncEntityRecurringRules;
    case 'exchangeRates':
      return l10n.syncEntityExchangeRates;
    case 'ledgerBook':
      return l10n.syncEntityLedgerBook;
    case 'monthlyBudgets':
    case 'categoryBudgets':
    case 'dailyBudgets':
      return l10n.syncEntityBudgets;
    case 'profile':
      return l10n.syncEntityProfile;
    case 'homePanels':
      return l10n.syncEntityHomePanels;
    case 'reportPanels':
      return l10n.syncEntityReportPanels;
    default:
      return l10n.syncEntityGeneric;
  }
}

/// 冲突的作用域描述：账本名（能解析到时）或全局。
String formatSyncConflictScope(AppLocalizations l10n, SyncConflict conflict) {
  if (conflict.entity.scope == 'global') {
    return l10n.syncConflictScopeGlobal;
  }
  return l10n.syncConflictScopeLedger;
}

/// 逻辑时钟的展示：逻辑时钟是单调递增的本地时间戳，直接显示原始数字没有意义，
/// 这里只在两侧可比较时给出「L / R」关系提示，其余回退为序号。
String formatSyncConflictLogicalTime(AppLocalizations l10n, int logicalTime) {
  return l10n.syncConflictLogicalTime('$logicalTime');
}

/// 把一侧的 payload 归一化成人可读的「字段名 → 值」摘要。
///
/// 只输出白名单/已知字段；未知结构整条摘要为占位文案，避免把协议内部字段名
/// 或原始 JSON 泄露到界面。金额经 `formatAmount` 渲染。
SyncConflictPayloadSummary summarizeSyncConflictPayload(
  AppLocalizations l10n,
  Object? payload,
  String entityType, {
  List<Account> accounts = const <Account>[],
  List<Category> categories = const <Category>[],
}) {
  if (payload is! Map) {
    return <String, String>{
      l10n.syncConflictFieldSummary: l10n.syncConflictUnreadable,
    };
  }
  final map = payload.cast<String, Object?>();
  final summary = <String, String>{};
  void put(String label, Object? value) {
    if (value == null) return;
    if (value is String && value.isEmpty) return;
    summary[label] = _renderValue(l10n, label, value, accounts, categories);
  }

  switch (entityType) {
    case 'entries':
      put(l10n.syncConflictFieldType, _entryTypeLabel(l10n, map['type']));
      put(
        l10n.syncConflictFieldAmount,
        map['amount'] is num ? formatAmount(map['amount'] as num) : null,
      );
      put(l10n.syncConflictFieldAccount, _accountName(l10n, accounts, map));
      put(l10n.syncConflictFieldCategory, _categoryName(l10n, categories, map));
      put(l10n.syncConflictFieldNote, map['note']);
      put(l10n.syncConflictFieldDate, _dateLabel(l10n, map['occurredAt']));
    case 'accounts':
      put(l10n.syncConflictFieldName, map['name']);
      put(
        l10n.syncConflictFieldInitialBalance,
        map['initialBalance'] is num
            ? formatAmount(map['initialBalance'] as num)
            : null,
      );
      put(
        l10n.syncConflictFieldType,
        map['type'] is String ? map['type'] : null,
      );
    case 'categories':
    case 'tags':
      put(l10n.syncConflictFieldName, map['name'] ?? map['label']);
    case 'ledgerBook':
      put(l10n.syncConflictFieldName, map['name']);
      put(l10n.syncConflictFieldCurrency, map['baseCurrencyCode']);
    case 'monthlyBudgets':
    case 'categoryBudgets':
    case 'dailyBudgets':
      put(
        l10n.syncConflictFieldAmount,
        map['amount'] is num ? formatAmount(map['amount'] as num) : null,
      );
    case 'exchangeRates':
      put(l10n.syncConflictFieldCurrency, map['currencyCode'] ?? map['code']);
      put(
        l10n.syncConflictFieldRate,
        map['rate'] is num ? '${map['rate']}' : null,
      );
    default:
      put(l10n.syncConflictFieldName, map['name'] ?? map['label']);
  }

  if (summary.isEmpty) {
    summary[l10n.syncConflictFieldSummary] = l10n.syncConflictEmptyPayload;
  }
  return summary;
}

/// 按本地摘要顺序产出差异行；只保留两侧不一致的字段。
///
/// 顺序以本地摘要为准，远端独有字段追加在后，保证同一份冲突在不同次渲染中
/// 行序稳定（否则对比列表会「跳」）。
List<SyncConflictDiffRow> compareSyncConflictPayloads(
  SyncConflictPayloadSummary local,
  SyncConflictPayloadSummary remote,
) {
  final rows = <SyncConflictDiffRow>[];
  final seen = <String>{};
  for (final entry in local.entries) {
    seen.add(entry.key);
    final other = remote[entry.key];
    if (other == entry.value) continue;
    rows.add(
      SyncConflictDiffRow(label: entry.key, local: entry.value, remote: other),
    );
  }
  for (final entry in remote.entries) {
    if (seen.contains(entry.key)) continue;
    rows.add(
      SyncConflictDiffRow(label: entry.key, local: null, remote: entry.value),
    );
  }
  return rows;
}

String _renderValue(
  AppLocalizations l10n,
  String label,
  Object value,
  List<Account> accounts,
  List<Category> categories,
) {
  if (value is bool) {
    return value ? l10n.syncConflictValueTrue : l10n.syncConflictValueFalse;
  }
  if (value is num) {
    return '$value';
  }
  if (value is List) {
    return l10n.syncConflictListCount(value.length);
  }
  if (value is Map) {
    return l10n.syncConflictMapEntryCount(value.length);
  }
  return '$value';
}

String? _entryTypeLabel(AppLocalizations l10n, Object? raw) {
  if (raw is! String) return null;
  switch (raw) {
    case 'expense':
      return l10n.entryTypeExpense;
    case 'income':
      return l10n.entryTypeIncome;
    case 'transfer':
      return l10n.entryTypeTransfer;
    case 'refund':
      return l10n.entryTypeRefund;
    default:
      return null;
  }
}

String? _accountName(
  AppLocalizations l10n,
  List<Account> accounts,
  Map<String, Object?> map,
) {
  final id = map['accountId'];
  if (id is! String || id.isEmpty) {
    return l10n.syncConflictNoAccount;
  }
  final match = accounts.where((a) => a.id == id).firstOrNull;
  return match?.name ?? l10n.syncConflictUnknownAccount;
}

String? _categoryName(
  AppLocalizations l10n,
  List<Category> categories,
  Map<String, Object?> map,
) {
  final id = map['categoryId'];
  if (id is! String || id.isEmpty) return null;
  final match = categories.where((c) => c.id == id).firstOrNull;
  return match?.label ?? l10n.syncConflictUnknownCategory;
}

String? _dateLabel(AppLocalizations l10n, Object? raw) {
  if (raw is! String) return null;
  final parsed = DateTime.tryParse(raw);
  if (parsed == null) return null;
  return '${l10n.dateMonthDay(parsed.toLocal())} '
      '${formatTime(parsed.toLocal())}';
}

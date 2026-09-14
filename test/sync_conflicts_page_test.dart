// Task 7：同步冲突审阅页。覆盖空态、两版展示、字段差异、删除/编辑标签、
// 保留本机 / 保留远端的动作调用、取消不改动任何一侧，以及决议后的冲突计数刷新。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/sync/sync_models.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/app/veri_fin_scope.dart';
import 'package:verifin/pages/sync_conflicts_page.dart';

import 'support/in_memory_ledger_repository.dart';
import 'support/test_harness.dart';

/// 构造一条实体版本。逻辑时钟与序列号显式传参，便于断言界面上的时序信息。
SyncEntityVersion _version({
  required SyncEntityKey entity,
  required String deviceId,
  required int sequence,
  required int logicalTime,
  required Object? payload,
  bool deleted = false,
  String? operationId,
}) {
  final version = SyncVersion(
    dot: SyncDot(deviceId: deviceId, sequence: sequence),
    context: SyncVersionVector(<String, int>{deviceId: sequence}),
    logicalTime: logicalTime,
  );
  return SyncEntityVersion(
    entity: entity,
    version: version,
    payloadHash: computeSyncPayloadHash(payload),
    payload: payload,
    deleted: deleted,
    operationId: operationId ?? '$deviceId-$sequence',
  );
}

void main() {
  useTestDatabases();

  /// 预置冲突记录并打开冲突页。返回 (控制器, 仓储)。
  ///
  /// 冲突必须先经仓储写入、再构造页面：页面的首次读取发生在
  /// `didChangeDependencies`，此时仓储里就得有数据。
  Future<(VeriFinController, InMemoryLedgerRepository)> pumpPage(
    WidgetTester tester, {
    List<SyncConflictRecord> conflicts = const <SyncConflictRecord>[],
  }) async {
    await tester.binding.setSurfaceSize(const Size(460, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final repository = InMemoryLedgerRepository();
    for (final conflict in conflicts) {
      await repository.sync.storeConflict(conflict);
    }
    final controller = await makeController(null, true, repository);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      VeriFinScope(
        controller: controller,
        child: zhMaterialApp(home: const SyncConflictsPage()),
      ),
    );
    await tester.pumpAndSettle();
    return (controller, repository);
  }

  /// 一条交易冲突：本机改了金额，远端改了备注。
  SyncConflictRecord entryConflict({
    String id = 'conflict-1',
    Object? localPayload,
    Object? remotePayload,
    bool localDeleted = false,
    bool remoteDeleted = false,
  }) {
    const entity = SyncEntityKey(
      scope: 'ledger',
      type: 'entries',
      id: 'entry-1',
    );
    return SyncConflictRecord(
      id: id,
      entity: entity,
      local: _version(
        entity: entity,
        deviceId: 'device-local',
        sequence: 7,
        logicalTime: 1000,
        payload:
            localPayload ??
            <String, Object?>{
              'id': 'entry-1',
              'type': 'expense',
              'amount': 12.5,
              'note': '本机备注',
              'categoryId': '',
              'accountId': '',
            },
        deleted: localDeleted,
      ),
      remote: _version(
        entity: entity,
        deviceId: 'device-remote',
        sequence: 9,
        logicalTime: 2000,
        payload:
            remotePayload ??
            <String, Object?>{
              'id': 'entry-1',
              'type': 'expense',
              'amount': 30.0,
              'note': '远端备注',
              'categoryId': '',
              'accountId': '',
            },
        deleted: remoteDeleted,
      ),
    );
  }

  testWidgets('无冲突时显示空态', (tester) async {
    await pumpPage(tester);
    expect(find.text('没有待处理的冲突'), findsOneWidget);
  });

  testWidgets('展示两侧版本、来源设备与时序', (tester) async {
    await pumpPage(tester, conflicts: <SyncConflictRecord>[entryConflict()]);

    expect(find.text('交易'), findsOneWidget);
    // 两侧版本标签都要出现，用户才知道哪一列是哪一版。
    expect(find.text('本机版本'), findsOneWidget);
    expect(find.text('其他设备版本'), findsOneWidget);
    // 来源设备与序号来自版本元数据。
    expect(find.textContaining('device-local'), findsOneWidget);
    expect(find.textContaining('device-remote'), findsOneWidget);
    expect(find.textContaining('序号 7'), findsOneWidget);
    expect(find.textContaining('序号 9'), findsOneWidget);
    // 两版备注都可见，说明不是只渲染了一侧。
    expect(find.text('本机备注'), findsOneWidget);
    expect(find.text('远端备注'), findsOneWidget);
  });

  testWidgets('只对比有差异的字段', (tester) async {
    await pumpPage(tester, conflicts: <SyncConflictRecord>[entryConflict()]);

    // 备注两侧不同 → 出现在差异行里。
    expect(find.text('备注'), findsOneWidget);
    // 金额两侧不同 → 差异行展示两版金额。
    expect(find.text('金额'), findsOneWidget);
    expect(find.text('12.5'), findsOneWidget);
    expect(find.text('30'), findsOneWidget);
  });

  testWidgets('未修改的原始 JSON 与派生缓存字段不出现在界面上', (tester) async {
    await pumpPage(
      tester,
      conflicts: <SyncConflictRecord>[
        entryConflict(
          localPayload: <String, Object?>{
            'id': 'entry-1',
            'type': 'expense',
            'amount': 12.5,
            'note': '同一条备注',
            'refundedBaseAmount': 3.0,
          },
          remotePayload: <String, Object?>{
            'id': 'entry-1',
            'type': 'expense',
            'amount': 12.5,
            'note': '同一条备注',
            'refundedBaseAmount': 8.0,
          },
        ),
      ],
    );

    // 派生缓存字段两侧不同也不算冲突：它由已到账退款重算，不该竞争。
    expect(find.textContaining('refundedBaseAmount'), findsNothing);
    expect(find.text('3'), findsNothing);
    expect(find.text('8'), findsNothing);
  });

  testWidgets('一侧删除时只给出保留删除 / 保留修改', (tester) async {
    await pumpPage(
      tester,
      conflicts: <SyncConflictRecord>[
        entryConflict(localDeleted: true, localPayload: null),
      ],
    );

    expect(find.text('保留删除'), findsOneWidget);
    expect(find.text('保留修改'), findsOneWidget);
    // 删除/编辑二选一时不应再出现「保留本机 / 保留其他设备」。
    expect(find.text('保留本机'), findsNothing);
    expect(find.text('保留其他设备'), findsNothing);
  });

  testWidgets('两侧都是修改时给出保留本机 / 保留其他设备', (tester) async {
    await pumpPage(tester, conflicts: <SyncConflictRecord>[entryConflict()]);

    expect(find.text('保留本机'), findsOneWidget);
    expect(find.text('保留其他设备'), findsOneWidget);
    expect(find.text('保留删除'), findsNothing);
    expect(find.text('保留修改'), findsNothing);
  });

  testWidgets('保留本机后冲突消失、计数归零', (tester) async {
    await pumpPage(tester, conflicts: <SyncConflictRecord>[entryConflict()]);

    await tester.tap(find.text('保留本机'));
    await tester.pumpAndSettle();

    // 决议后页面刷新为空态，仓储里的未决冲突也应为零。
    expect(find.text('没有待处理的冲突'), findsOneWidget);
    final status = await VeriFinScope.of(
      tester.element(find.byType(SyncConflictsPage)),
    ).loadSyncPreferenceStatus();
    expect(status.conflictCount, 0);
  });

  testWidgets('保留其他设备同样清掉该冲突', (tester) async {
    await pumpPage(tester, conflicts: <SyncConflictRecord>[entryConflict()]);

    await tester.tap(find.text('保留其他设备'));
    await tester.pumpAndSettle();

    expect(find.text('没有待处理的冲突'), findsOneWidget);
    final status = await VeriFinScope.of(
      tester.element(find.byType(SyncConflictsPage)),
    ).loadSyncPreferenceStatus();
    expect(status.conflictCount, 0);
  });

  testWidgets('取消不改动任何一侧，冲突保持未决', (tester) async {
    final (_, repository) = await pumpPage(
      tester,
      conflicts: <SyncConflictRecord>[entryConflict()],
    );
    final before = await repository.sync.loadConflicts();
    final outboxBefore = await repository.sync.loadOutbox();

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    // 冲突还在，且没有被写入任何决议事件。
    final after = await repository.sync.loadConflicts();
    expect(after.length, before.length);
    expect(after.first.id, before.first.id);
    expect(await repository.sync.loadOutbox(), hasLength(outboxBefore.length));
    // 界面仍展示这条冲突，用户可以重新决定。
    expect(find.text('保留本机'), findsOneWidget);
  });

  testWidgets('多条冲突时逐条决议，计数递减', (tester) async {
    await pumpPage(
      tester,
      conflicts: <SyncConflictRecord>[
        entryConflict(id: 'conflict-1'),
        entryConflict(id: 'conflict-2'),
      ],
    );

    expect(find.text('保留本机'), findsNWidgets(2));

    await tester.tap(find.text('保留本机').first);
    await tester.pumpAndSettle();

    // 只剩一条，列表没有整块消失。
    expect(find.text('保留本机'), findsOneWidget);
    final status = await VeriFinScope.of(
      tester.element(find.byType(SyncConflictsPage)),
    ).loadSyncPreferenceStatus();
    expect(status.conflictCount, 1);
  });

  testWidgets('账户冲突展示名称与初始余额，不展示原始 JSON', (tester) async {
    const entity = SyncEntityKey(
      scope: 'ledger',
      type: 'accounts',
      id: 'account-1',
    );
    await pumpPage(
      tester,
      conflicts: <SyncConflictRecord>[
        SyncConflictRecord(
          id: 'account-conflict',
          entity: entity,
          local: _version(
            entity: entity,
            deviceId: 'device-local',
            sequence: 1,
            logicalTime: 10,
            payload: <String, Object?>{
              'id': 'account-1',
              'name': '招商银行',
              'initialBalance': 100.0,
              'type': 'bank',
            },
          ),
          remote: _version(
            entity: entity,
            deviceId: 'device-remote',
            sequence: 2,
            logicalTime: 20,
            payload: <String, Object?>{
              'id': 'account-1',
              'name': '招商银行',
              'initialBalance': 250.0,
              'type': 'bank',
            },
          ),
        ),
      ],
    );

    expect(find.text('账户'), findsOneWidget);
    expect(find.text('初始余额'), findsOneWidget);
    expect(find.text('100'), findsOneWidget);
    expect(find.text('250'), findsOneWidget);
    // 名称两侧相同 → 不出现在差异行；原始 JSON 键名不得泄露。
    expect(find.text('名称'), findsNothing);
    expect(find.textContaining('initialBalance'), findsNothing);
    expect(find.textContaining('{'), findsNothing);
  });

  testWidgets('决议使用控制器 API 而非直接改仓储', (tester) async {
    final (controller, repository) = await pumpPage(
      tester,
      conflicts: <SyncConflictRecord>[entryConflict()],
    );

    // 先确认冲突确实在仓储里，再点按钮，最后确认控制器视角也一致。
    expect(await controller.loadSyncConflicts(), hasLength(1));
    await tester.tap(find.text('保留本机'));
    await tester.pumpAndSettle();

    expect(await controller.loadSyncConflicts(), isEmpty);
    expect(await repository.sync.loadConflicts(), isEmpty);
    // 决议必须留下一个待上传的 resolve 事件，否则远端永远不知道这个决定。
    expect(await repository.sync.loadOutbox(), isNotEmpty);
  });
}

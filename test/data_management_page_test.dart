import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/app_theme.dart';
import 'package:verifin/app/backup/backup_settings.dart';
import 'package:verifin/app/backup/webdav_config.dart';
import 'package:verifin/app/common_widgets.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/sync/sync_models.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/app/veri_fin_scope.dart';
import 'package:verifin/local_storage/local_storage.dart';
import 'package:verifin/pages/data_management_page.dart';
import 'package:verifin/pages/sync_conflicts_page.dart';

import 'support/in_memory_ledger_repository.dart';
import 'support/test_harness.dart';

/// 一条「本机改了金额、远端改了备注」的交易冲突，供状态行测试预置使用。
///
/// 这里只关心「存在未决冲突」这一个事实，因此载荷用最小的可读字段，
/// 不复制同步页测试里的完整对比矩阵。
SyncConflictRecord conflictRecord({required String id}) {
  const entity = SyncEntityKey(scope: 'ledger', type: 'entries', id: 'entry-1');
  SyncEntityVersion version({
    required String deviceId,
    required int sequence,
    required String note,
    required double amount,
  }) {
    final payload = LedgerEntry(
      id: 'entry-1',
      bookId: 'default',
      type: EntryType.expense,
      amount: amount,
      categoryId: 'dining',
      accountId: '',
      note: note,
      occurredAt: DateTime(2026, 9, 16),
    ).toJson();
    return SyncEntityVersion(
      entity: entity,
      version: SyncVersion(
        dot: SyncDot(deviceId: deviceId, sequence: sequence),
        context: SyncVersionVector(<String, int>{deviceId: sequence}),
        logicalTime: sequence * 1000,
      ),
      payloadHash: computeSyncPayloadHash(payload),
      payload: payload,
      deleted: false,
      operationId: '$deviceId-$sequence',
    );
  }

  return SyncConflictRecord(
    id: id,
    entity: entity,
    local: version(
      deviceId: 'device-local',
      sequence: 1,
      note: '本机备注',
      amount: 12.5,
    ),
    remote: version(
      deviceId: 'device-remote',
      sequence: 2,
      note: '远端备注',
      amount: 30,
    ),
  );
}

/// Task 6 Step 5：数据管理页的同步控件、互斥反馈、状态行与恢复守卫。
void main() {
  useTestDatabases();

  /// 打开数据管理页，返回控制器。默认预置一个已配置的 WebDAV 服务器，
  /// 否则同步控件区块整块不渲染（它跟手动上传/恢复一样只在已配置时出现）。
  ///
  /// [repository] 用于需要先往同步元数据里预置数据的用例（如冲突记录）；
  /// 传入时该仓储即绑定到 store，页面读到的就是预置内容。
  ///
  /// [mode] 必须在页面首次构建**之前**就写进控制器：页面的模式草稿在
  /// `didChangeDependencies` 里一次性快照，之后控制器再变也不会刷新草稿
  /// （这正是「未保存的草稿不被外部状态覆盖」的预期行为）。
  Future<VeriFinController> pumpPage(
    WidgetTester tester, {
    bool webdavConfigured = true,
    BackupTransportMode mode = BackupTransportMode.manual,
    InMemoryLedgerRepository? repository,
  }) async {
    await tester.binding.setSurfaceSize(const Size(460, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = repository == null
        ? await makeController()
        : await makeController(null, true, repository);
    addTearDown(controller.dispose);
    if (webdavConfigured) {
      controller.setWebdavConfig(
        const WebdavConfig(
          url: 'https://dav.example.com/verifin/',
          username: 'u',
          password: 'p',
        ),
      );
    }
    if (mode != BackupTransportMode.manual) {
      await controller.setBackupTransportMode(mode);
    }
    await tester.pumpWidget(
      VeriFinScope(
        controller: controller,
        child: zhMaterialApp(home: const DataManagementPage()),
      ),
    );
    await tester.pumpAndSettle();
    return controller;
  }

  /// 推进足够的帧让反馈卡片完成挂载与入场动画。提示正文是 `Text.rich`（带计数
  /// 后缀的 TextSpan），因此断言必须用 [feedbackMessageVisible] 而不是
  /// `find.text`——`find.text` 只匹配 `Text.data`，对 RichText 恒为 0。
  Future<void> settleFeedback(WidgetTester tester) async {
    await tester.pump();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// 反馈卡片上是否显示了 [message]。匹配 RichText 的 span 文本。
  Finder feedbackMessage(String message) => find.byWidgetPredicate(
    (widget) => widget is Text && (widget.textSpan?.toPlainText() == message),
    description: '反馈气泡文案「$message」',
  );

  /// 打开「同步方式」菜单并选中 [mode]。菜单项按稳定 id 定位
  /// （`veri_menu_item_sync_mode_<mode>`）而不是文案，避免中文/英文断言漂移。
  ///
  /// 触发点用 [current]（行右侧当前显示的文案）：区块标题与行标题是同一个
  /// 「同步方式」字符串，按标题点会误中不可交互的分区标签。
  Future<void> pickTransportMode(
    WidgetTester tester,
    BackupTransportMode mode, {
    required String current,
  }) async {
    await tester.pump();
    final trigger = find.text(current);
    expect(trigger, findsWidgets, reason: '找不到当前模式文案「$current」，菜单无法打开');
    await tester.tap(trigger.last);
    await tester.pumpAndSettle();
    final item = find.byKey(
      ValueKey<String>('veri_menu_item_sync_mode_${mode.name}'),
    );
    expect(item, findsOneWidget, reason: '菜单里没有 ${mode.name} 选项');
    await tester.tap(item);
    await tester.pumpAndSettle();
  }

  group('同步方式控件', () {
    testWidgets('未配置 WebDAV 时不显示同步方式区块', (tester) async {
      await pumpPage(tester, webdavConfigured: false);
      expect(find.text('同步方式'), findsNothing);
      expect(find.text('同步状态'), findsNothing);
    });

    testWidgets('已配置时显示同步方式与同步状态，且与立即上传/恢复分开', (tester) async {
      await pumpPage(tester);

      expect(find.text('同步方式'), findsWidgets);
      expect(find.text('同步状态'), findsOneWidget);
      // 手动入口仍在，且不受传输模式影响。
      expect(find.text('上传到 WebDAV'), findsOneWidget);
      expect(find.text('从 WebDAV 恢复'), findsOneWidget);
      expect(find.text('立即上传'), findsOneWidget);
      expect(find.text('选择备份'), findsOneWidget);
    });

    testWidgets('默认为手动模式，状态显示为尚未同步成功', (tester) async {
      final controller = await pumpPage(tester);
      expect(controller.backupTransportMode, BackupTransportMode.manual);
      expect(find.text('手动'), findsOneWidget);
      expect(find.text('尚未同步成功'), findsOneWidget);
    });

    testWidgets('选择自动同步并保存后落库，且自动上传被关掉', (tester) async {
      final controller = await pumpPage(tester);
      expect(controller.backupTransportMode, BackupTransportMode.manual);

      await pickTransportMode(
        tester,
        BackupTransportMode.autoSync,
        current: '手动',
      );

      // 只改草稿：保存前控制器不变。
      expect(controller.backupTransportMode, BackupTransportMode.manual);

      await tester.tap(find.byTooltip('保存'));
      await tester.pumpAndSettle();

      expect(controller.backupTransportMode, BackupTransportMode.autoSync);
      // 互斥：旧的上传标记必须为 false。
      expect(controller.webdavConfig.autoUpload, isFalse);
      expect(controller.backupTransportModeConflict, isFalse);
    });

    testWidgets('切到自动同步时给出互斥反馈文案', (tester) async {
      final controller = await pumpPage(
        tester,
        mode: BackupTransportMode.autoUpload,
      );
      expect(controller.backupTransportMode, BackupTransportMode.autoUpload);

      await pickTransportMode(
        tester,
        BackupTransportMode.autoSync,
        current: '自动上传',
      );
      await tester.tap(find.byTooltip('保存'));
      await settleFeedback(tester);

      expect(controller.backupTransportMode, BackupTransportMode.autoSync);
      expect(feedbackMessage('已开启自动同步，自动上传已关闭'), findsOneWidget);
    });

    testWidgets('自动同步切回自动上传时给出反向反馈', (tester) async {
      final controller = await pumpPage(
        tester,
        mode: BackupTransportMode.autoSync,
      );
      expect(controller.backupTransportMode, BackupTransportMode.autoSync);

      await pickTransportMode(
        tester,
        BackupTransportMode.autoUpload,
        current: '自动同步',
      );
      await tester.tap(find.byTooltip('保存'));
      await settleFeedback(tester);

      expect(controller.backupTransportMode, BackupTransportMode.autoUpload);
      expect(controller.webdavConfig.autoUpload, isTrue);
      expect(feedbackMessage('已开启自动上传，自动同步已关闭'), findsOneWidget);
    });

    testWidgets('切到手动模式不发互斥提示（没有互相排斥的对象）', (tester) async {
      await pumpPage(tester, mode: BackupTransportMode.autoSync);

      await pickTransportMode(
        tester,
        BackupTransportMode.manual,
        current: '自动同步',
      );
      await tester.tap(find.byTooltip('保存'));
      await tester.pumpAndSettle();
      await settleFeedback(tester);

      expect(feedbackMessage('已开启自动同步，自动上传已关闭'), findsNothing);
      expect(feedbackMessage('已开启自动上传，自动同步已关闭'), findsNothing);
    });
  });

  group('恢复守卫', () {
    /// 构造「两种自动模式同时开启」的损坏状态：先落 autoSync，再绕过
    /// [VeriFinController.setBackupTransportMode] 直接打开旧上传标记。
    Future<VeriFinController> pumpConflicted(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(460, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final controller = await makeController();
      addTearDown(controller.dispose);
      controller.setWebdavConfig(
        const WebdavConfig(url: 'https://dav.example.com/verifin/'),
      );
      await controller.setBackupTransportMode(BackupTransportMode.autoSync);
      controller.setWebdavAutoUpload(true);
      expect(controller.backupTransportModeConflict, isTrue);

      await tester.pumpWidget(
        VeriFinScope(
          controller: controller,
          child: zhMaterialApp(home: const DataManagementPage()),
        ),
      );
      await tester.pumpAndSettle();
      return controller;
    }

    testWidgets('检测到冲突时显示恢复守卫行', (tester) async {
      await pumpConflicted(tester);
      expect(find.text('自动同步与自动上传同时处于开启状态，请重置传输模式'), findsOneWidget);
      expect(find.text('重置为自动上传'), findsOneWidget);
    });

    testWidgets('点击恢复守卫复位到自动上传并给出反馈', (tester) async {
      final controller = await pumpConflicted(tester);

      await tester.tap(find.text('重置为自动上传'));
      await settleFeedback(tester);

      expect(controller.backupTransportMode, BackupTransportMode.autoUpload);
      expect(controller.backupTransportModeConflict, isFalse);
      expect(feedbackMessage('已重置同步模式'), findsOneWidget);
      // 复位后守卫行消失。
      expect(find.text('自动同步与自动上传同时处于开启状态，请重置传输模式'), findsNothing);
    });

    testWidgets('无冲突时不显示恢复守卫行', (tester) async {
      await pumpPage(tester);
      expect(find.text('自动同步与自动上传同时处于开启状态，请重置传输模式'), findsNothing);
      expect(find.text('重置为自动上传'), findsNothing);
    });
  });

  group('同步状态行', () {
    testWidgets('待重放偏好时显示待同步计数', (tester) async {
      final store = LocalKeyValueStore();
      final repo = InMemoryLedgerRepository();
      final controller = await makeController(store, true, repo);
      addTearDown(controller.dispose);
      controller.setWebdavConfig(
        const WebdavConfig(url: 'https://dav.example.com/verifin/'),
      );
      // 启动期的重放已经过去；这里再写一条待重放行，它会一直留到下次启动，
      // 页面读状态时应把它算进「待同步」。
      await repo.sync.applyRemoteBatch(
        RemoteApplyPlan(
          batchId: 'batch-pending',
          entityVersions: const <SyncEntityVersion>[],
          appliedOperationIds: const <String>['op-pending'],
          shadowHashes: const <String, String>{},
          kvJournalValues: const <String, String>{'verifin.theme.v1': 'dark'},
        ),
      );

      await tester.binding.setSurfaceSize(const Size(460, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        VeriFinScope(
          controller: controller,
          child: zhMaterialApp(home: const DataManagementPage()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('同步状态'), findsOneWidget);
      expect(find.text('1 项待同步'), findsOneWidget);
    });

    testWidgets('无待同步项且从未成功时显示尚未同步成功', (tester) async {
      await pumpPage(tester);
      expect(find.text('尚未同步成功'), findsOneWidget);
      expect(find.text('无待同步项'), findsNothing);
    });

    testWidgets('有持久化成功记录且无待处理项时才显示已连接', (tester) async {
      final repo = InMemoryLedgerRepository();
      await repo.sync.saveScanState(
        SyncScanState(
          contiguousSequences: const <String, int>{},
          gaps: const <String, List<int>>{},
          lastSuccess: DateTime(2026, 9, 17),
          lastErrorCode: null,
          retryCount: 0,
        ),
      );

      await pumpPage(tester, repository: repo);

      expect(find.text('已连接'), findsOneWidget);
      expect(find.text('尚未同步成功'), findsNothing);
    });

    testWidgets('持久化同步错误优先于历史成功记录', (tester) async {
      final repo = InMemoryLedgerRepository();
      await repo.sync.saveScanState(
        SyncScanState(
          contiguousSequences: const <String, int>{},
          gaps: const <String, List<int>>{},
          lastSuccess: DateTime(2026, 9, 16),
          lastErrorCode: 'network_error',
          retryCount: 1,
        ),
      );

      await pumpPage(tester, repository: repo);

      expect(find.text('同步出错'), findsOneWidget);
      expect(find.text('已连接'), findsNothing);
    });

    testWidgets('存在未决冲突时显示冲突计数、错误色与进入箭头', (tester) async {
      final repo = InMemoryLedgerRepository();
      await repo.sync.storeConflict(conflictRecord(id: 'conflict-1'));
      final controller = await pumpPage(tester, repository: repo);

      // 状态行本身还是「同步状态」，但右侧显示冲突计数而不是「已连接」。
      expect(find.text('同步状态'), findsOneWidget);
      expect(find.text('1 个冲突待处理'), findsOneWidget);
      expect(find.text('尚未同步成功'), findsNothing);

      // 有冲突时整行走错误色，并且给出进入箭头。
      final row = tester.widget<SettingsRow>(
        find.widgetWithText(SettingsRow, '同步状态'),
      );
      expect(row.contentColor, isNotNull);
      expect(
        row.contentColor,
        veriSemantic(
          tester.element(find.byType(DataManagementPage)),
          veriExpense,
        ),
      );
      expect(row.trailingIcon, Icons.chevron_right);

      // 冲突计数来自控制器读取的仓储状态，两条口径必须一致。
      final status = await controller.loadSyncPreferenceStatus();
      expect(status.conflictCount, 1);
    });

    testWidgets('无冲突时状态行不显示进入箭头', (tester) async {
      await pumpPage(tester);
      final row = tester.widget<SettingsRow>(
        find.widgetWithText(SettingsRow, '同步状态'),
      );
      // 没有冲突时点它只是刷新状态，不应伪装成可进入的页面。
      expect(row.trailingIcon, isNull);
    });

    testWidgets('检测到 v1 历史时阻断并仅在确认后写入待切换状态', (tester) async {
      final repo = InMemoryLedgerRepository();
      await repo.sync.recordV1Scan(
        v1HistoryFound: true,
        fingerprint:
            '1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef',
      );
      await pumpPage(tester, repository: repo);

      expect(find.text('等待旧设备升级（标识 12345678）'), findsOneWidget);
      expect(find.text('所有设备已升级'), findsOneWidget);

      await tester.tap(find.text('所有设备已升级'));
      await tester.pumpAndSettle();
      expect(find.text('确认所有设备已升级？'), findsOneWidget);
      await tester.tap(find.text('确认已升级'));
      await tester.pumpAndSettle();

      expect(
        (await repo.sync.loadSnapshotState()).v1MigrationState,
        V1MigrationState.readyToCutover,
      );
      expect(find.text('所有设备已升级'), findsNothing);
    });

    testWidgets('无冲突时点击状态行只刷新状态，不进入冲突页', (tester) async {
      final repo = InMemoryLedgerRepository();
      await pumpPage(tester, repository: repo);
      expect(find.text('尚未同步成功'), findsOneWidget);

      // 刷新前先在仓储里放一条冲突：如果这次点击读了状态，它就该显示出来。
      await repo.sync.storeConflict(conflictRecord(id: 'conflict-late'));

      await tester.tap(find.text('同步状态'));
      await tester.pumpAndSettle();

      expect(find.byType(SyncConflictsPage), findsNothing);
      expect(find.text('1 个冲突待处理'), findsOneWidget);
      expect(find.text('尚未同步成功'), findsNothing);
    });

    testWidgets('点击状态行进入冲突审阅页', (tester) async {
      final repo = InMemoryLedgerRepository();
      await repo.sync.storeConflict(conflictRecord(id: 'conflict-1'));
      await pumpPage(tester, repository: repo);

      await tester.tap(find.text('同步状态'));
      await tester.pumpAndSettle();

      // 进入了冲突页：标题与那条冲突都在。
      expect(find.byType(SyncConflictsPage), findsOneWidget);
      expect(find.text('同步冲突'), findsOneWidget);
      expect(find.text('交易'), findsOneWidget);
    });

    testWidgets('从冲突页返回后重新读取同步状态，计数刷新', (tester) async {
      final repo = InMemoryLedgerRepository();
      await repo.sync.storeConflict(conflictRecord(id: 'conflict-1'));
      await pumpPage(tester, repository: repo);
      expect(find.text('1 个冲突待处理'), findsOneWidget);

      await tester.tap(find.text('同步状态'));
      await tester.pumpAndSettle();
      expect(find.byType(SyncConflictsPage), findsOneWidget);

      // 在冲突页里决议掉这条冲突（覆盖性决议需要确认）。
      await tester.tap(find.text('保留本机'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(FilledButton),
        ),
      );
      await tester.pumpAndSettle();
      expect(await repo.sync.loadConflicts(), isEmpty);

      // 返回数据管理页：状态行必须重读一次，否则会停在旧的「1 个冲突待处理」。
      // 页面用 VeriHeader 自己的返回箭头（不是 Material 的 BackButton），
      // 所以不能走 `tester.pageBack()`。
      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();

      expect(find.byType(SyncConflictsPage), findsNothing);
      expect(find.text('1 个冲突待处理'), findsNothing);
      // 冲突决议本身会写入 outbox，等下一轮同步上传，不能伪装成无待处理项。
      expect(find.textContaining('项待同步'), findsOneWidget);
      final row = tester.widget<SettingsRow>(
        find.widgetWithText(SettingsRow, '同步状态'),
      );
      expect(row.trailingIcon, isNull);
    });
  });
}

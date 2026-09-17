import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/app_theme.dart';
import 'package:verifin/app/common_widgets.dart';
import 'package:verifin/app/chart_painters.dart';
import 'package:verifin/app/home_metrics.dart';
import 'package:verifin/app/ledger_math.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/main.dart';
import 'package:verifin/pages/home_page.dart';
import 'package:verifin/pages/budget_pages.dart';

import 'support/test_harness.dart';

void main() {
  useTestDatabases();
  testWidgets('概览胶囊靠右对齐，不紧挨主金额', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(393, 852);
    addTearDown(tester.view.reset);
    await pumpApp(tester);
    await tester.pumpAndSettle();
    final row = tester.getRect(find.byKey(const Key('home_primary_metrics')));
    final pill = tester.getRect(find.byKey(const Key('home_summary_pill')));
    expect(pill.right, closeTo(row.right, 0.5));
    expect(find.text('日均消费'), findsNothing);
    expect(find.byKey(const Key('home_metric_1')), findsOneWidget);
    expect(find.byKey(const Key('home_metric_2')), findsNothing);
    expect(find.byKey(const Key('home_metric_3')), findsOneWidget);
    final chart = tester.widget<InteractiveTrendChart>(
      find.byType(InteractiveTrendChart).first,
    );
    expect(chart.referenceLineValue, isNotNull);
    expect(chart.referenceLineColor, anyOf(veriWarning, veriWarningOnLight));
    final tooltip = chart.tooltipOf(0);
    expect(tooltip.lines, hasLength(2));
    expect(tooltip.lines.last.text, contains('日均消费'));
    expect(tooltip.lines.last.color, chart.referenceLineColor);
    final painter =
        tester
                .widget<CustomPaint>(
                  find
                      .byWidgetPredicate(
                        (widget) =>
                            widget is CustomPaint &&
                            widget.painter is TrendLinePainter,
                      )
                      .first,
                )
                .painter!
            as TrendLinePainter;
    expect(painter.referenceLineValue, chart.referenceLineValue);
    expect(painter.referenceLineColor, chart.referenceLineColor);
    expect(tester.takeException(), isNull);
  });
  testWidgets('负结余曲线与正日均线共用纵轴范围', (tester) async {
    final now = DateTime(2026, 9, 10, 12);
    final expense = LedgerEntry(
      id: 'expense',
      bookId: 'book',
      type: EntryType.expense,
      amount: 200,
      categoryId: 'dining',
      accountId: '',
      note: '',
      occurredAt: now,
    );
    final metricContext = HomeMetricContext(
      entries: <LedgerEntry>[expense],
      accounts: const <Account>[],
      balanceOf: (_) => 0,
      now: now,
    );
    await tester.pumpWidget(
      zhMaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 393,
            height: 400,
            child: HomeTrendPanel(
              window: DateWindow(start: now, end: now),
              config: HomeTrendConfig.defaults.copyWith(
                series: HomeTrendSeries.net,
              ),
              metricContext: metricContext,
              chartValues: const <double>[-100],
              currencyCode: 'CNY',
              onTap: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final chart = tester.widget<InteractiveTrendChart>(
      find.byType(InteractiveTrendChart),
    );
    expect(chart.referenceLineValue, 20);
    expect(chart.yLabels, const <String>['-100', '-40', '20']);
    expect(chart.semanticsLabel, contains('日均消费'));
    expect(tester.takeException(), isNull);
  });
  testWidgets('首页保留指标方块与原预算布局，预算仍可打开详情', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(393, 852);
    addTearDown(tester.view.reset);
    final controller = await makeController();
    controller.importTransactionsFromCsv(
      File('docs/dev/preview-transactions.csv').readAsStringSync(),
    );
    controller.setMonthlyBudget(DateTime.now(), 5000);
    controller.setThemePreference(ThemePreference.light);
    await controller.waitForPendingWrites();
    await tester.pumpWidget(VeriFinApp(controller: controller));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final primaryValue = tester.widget<Text>(
      find.byKey(const Key('home_primary_metric_value')),
    );
    expect(primaryValue.style?.fontSize, 14);
    final overview = tester.getRect(find.byType(HomeTrendPanel));
    expect(overview.height, lessThanOrEqualTo(280));
    expect(find.byKey(const Key('home_metric_1')), findsOneWidget);
    expect(find.byKey(const Key('home_metric_2')), findsNothing);
    expect(find.byKey(const Key('home_metric_3')), findsOneWidget);
    final transactions = find.byType(TransactionTile);
    expect(transactions, findsNWidgets(5));
    final navTop = tester.getRect(find.byKey(const Key('main_bottom_nav'))).top;
    expect(tester.getRect(transactions.last).bottom, lessThan(navTop));
    final budget = find.byType(BudgetPanel);
    expect(
      find.descendant(of: budget, matching: find.text('支出')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: budget, matching: find.text('剩余日均')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: budget,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is CustomPaint && widget.painter is BudgetRingPainter,
        ),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: budget,
        matching: find.byType(LinearProgressIndicator),
      ),
      findsNothing,
    );
    // 原预算卡保留完整圆环与原信息层级，不再为首屏目标压缩结构。
    expect(tester.getRect(budget).height, greaterThan(180));
    await tester.drag(firstVerticalScrollable(), const Offset(0, -240));
    await tester.pumpAndSettle();
    await tester.tap(budget);
    await tester.pumpAndSettle();
    expect(find.byType(HomeTrendPanel), findsNothing);
    expect(find.byType(BudgetOverviewPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, skip: !veriUnifiedDesignPreview);
}

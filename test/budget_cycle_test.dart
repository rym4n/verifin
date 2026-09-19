import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/budget_cycle.dart';
import 'package:verifin/app/ledger_math.dart';

void main() {
  group('budgetCycleOfKeyMonth', () {
    test('起始日 1（自然月）与 monthWindowFor 完全一致', () {
      for (final month in <DateTime>[
        DateTime(2026, 1),
        DateTime(2026, 2), // 平年二月
        DateTime(2024, 2), // 闰年二月
        DateTime(2026, 12),
      ]) {
        final cycle = budgetCycleOfKeyMonth(month, naturalMonthStartDay);
        final natural = monthWindowFor(month);
        expect(cycle.start, natural.start, reason: '$month start');
        expect(cycle.end, natural.end, reason: '$month end');
      }
    });

    test('起始日 22：本月 22 日至次月 21 日', () {
      final cycle = budgetCycleOfKeyMonth(DateTime(2026, 7), 22);
      expect(cycle.start, DateTime(2026, 7, 22));
      expect(cycle.end, DateTime(2026, 8, 21));
    });

    test('跨年：12 月键月的周期止于次年 1 月', () {
      final cycle = budgetCycleOfKeyMonth(DateTime(2026, 12), 22);
      expect(cycle.start, DateTime(2026, 12, 22));
      expect(cycle.end, DateTime(2027, 1, 21));
    });

    test('起始日 28 跨二月：1 月键月周期止于 2 月 27 日（平年）', () {
      final cycle = budgetCycleOfKeyMonth(DateTime(2026, 1), 28);
      expect(cycle.start, DateTime(2026, 1, 28));
      expect(cycle.end, DateTime(2026, 2, 27));
    });

    test('越界起始日钳到 1–28', () {
      expect(budgetCycleOfKeyMonth(DateTime(2026, 7), 31).start.day, 28);
      expect(budgetCycleOfKeyMonth(DateTime(2026, 7), 0).start.day, 1);
    });
  });

  group('budgetCycleKeyMonthFor', () {
    test('起始日 1：任意日期的键月都是当月', () {
      expect(
        budgetCycleKeyMonthFor(DateTime(2026, 7, 1), 1),
        DateTime(2026, 7),
      );
      expect(
        budgetCycleKeyMonthFor(DateTime(2026, 7, 31), 1),
        DateTime(2026, 7),
      );
    });

    test('起始日 22：起始日当天起属新周期，之前属上一键月', () {
      expect(
        budgetCycleKeyMonthFor(DateTime(2026, 7, 22), 22),
        DateTime(2026, 7),
      );
      expect(
        budgetCycleKeyMonthFor(DateTime(2026, 7, 21), 22),
        DateTime(2026, 6),
      );
    });

    test('跨年：1 月上旬的键月是上年 12 月', () {
      expect(
        budgetCycleKeyMonthFor(DateTime(2027, 1, 5), 22),
        DateTime(2026, 12),
      );
    });

    test('键月与窗口互洽：任意日期都落在其键月的周期窗口内', () {
      const startDay = 15;
      for (var offset = 0; offset < 70; offset++) {
        final date = DateTime(2026, 6, 1 + offset);
        final keyMonth = budgetCycleKeyMonthFor(date, startDay);
        final window = budgetCycleOfKeyMonth(keyMonth, startDay);
        expect(
          !date.isBefore(window.start) && !date.isAfter(window.end),
          isTrue,
          reason: '$date 应落在键月 $keyMonth 的窗口 ${window.start}~${window.end}',
        );
      }
    });
  });

  group('annual budget windows', () {
    test('natural year window includes every day of the selected year', () {
      final window = calendarYearWindowFor(DateTime(2026, 7, 15));

      expect(window.start, DateTime(2026, 1, 1));
      expect(window.end, DateTime(2026, 12, 31));
    });

    test('year-to-date window ends at the selected month end', () {
      final window = calendarYearToDateWindowFor(DateTime(2026, 7, 15));

      expect(window.start, DateTime(2026, 1, 1));
      expect(window.end, DateTime(2026, 7, 31));
    });

    test('remaining month count includes the selected month', () {
      expect(remainingCalendarMonths(DateTime(2026, 1)), 12);
      expect(remainingCalendarMonths(DateTime(2026, 9)), 4);
      expect(remainingCalendarMonths(DateTime(2026, 12)), 1);
    });

    test('remaining annual budget is averaged over remaining months', () {
      expect(
        remainingAnnualBudgetPerMonth(
          annualBudget: 12000,
          yearToDateExpense: 3000,
          remainingMonths: 4,
        ),
        2250,
      );
      expect(
        remainingAnnualBudgetPerMonth(
          annualBudget: 12000,
          yearToDateExpense: 13000,
          remainingMonths: 4,
        ),
        -250,
      );
    });
  });
}

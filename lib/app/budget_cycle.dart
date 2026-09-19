import 'ledger_math.dart';

/// 预算周期纯函数：预算支持自定义「周期起始日」（1–28，默认 1 = 自然月），
/// 周期为「本月起始日 至 次月起始日前一天」（含两端，起始日当天属于新周期）。
///
/// 周期以其**起始日所在月**的 `yyyy-MM` 作为预算存储键（下称「键月」）——
/// startDay=1 时窗口与键完全退化为自然月，历史预算数据零迁移；用户改起始日
/// 只是展示口径变化，各键月已存的预算金额原地有效。
///
/// 只有预算体系（预算页/预算面板/预算小组件）按此周期取数，统计报表仍按自然月
/// ——发薪日决定「钱怎么规划」，统计对账仍与自然月对齐，避免「本月」出现两套含义。

/// 起始日合法范围 1–28（与信用卡账单日 `nextStatementDate` 同惯例），
/// 避开 29–31 在短月缺日的歧义。
const int budgetCycleStartDayMin = 1;
const int budgetCycleStartDayMax = 28;

/// 自然月周期的起始日（默认值）。用户不设置时一切行为与自然月完全一致。
const int naturalMonthStartDay = 1;

int clampBudgetCycleStartDay(int day) =>
    day.clamp(budgetCycleStartDayMin, budgetCycleStartDayMax);

/// 键月为 [keyMonth]（取 year/month）的预算周期窗口（含两端）。
/// startDay=1 时等价于自然月窗口 [monthWindowFor]。
DateWindow budgetCycleOfKeyMonth(DateTime keyMonth, int startDay) {
  final day = clampBudgetCycleStartDay(startDay);
  return DateWindow(
    start: DateTime(keyMonth.year, keyMonth.month, day),
    // 次月起始日前一天。day=1 时日参数为 0，DateTime 归一化为本月最后一天，
    // 正是自然月末；用「按日构造」而非 subtract(Duration)，避免 DST 偏移。
    end: DateTime(keyMonth.year, keyMonth.month + 1, day - 1),
  );
}

/// 包含 [date] 的预算周期的键月（周期起始日所在月，day 归一为 1）。
/// 例：起始日 22，7 月 10 日属于「6 月 22 日～7 月 21 日」周期，键月为 6 月。
DateTime budgetCycleKeyMonthFor(DateTime date, int startDay) {
  final day = clampBudgetCycleStartDay(startDay);
  return date.day >= day
      ? DateTime(date.year, date.month)
      : DateTime(date.year, date.month - 1);
}

/// 自然年窗口（含首尾两端），用于按年预算的累计支出与年度预算比较。
DateWindow calendarYearWindowFor(DateTime date) =>
    DateWindow(start: DateTime(date.year), end: DateTime(date.year, 12, 31));

/// 截至 [date] 所在月份月末的自然年累计窗口（含首尾两端）。
DateWindow calendarYearToDateWindowFor(DateTime date) => DateWindow(
  start: DateTime(date.year),
  end: DateTime(date.year, date.month + 1, 0),
);

/// 从 [date] 所在月份起（含当月）到自然年末的剩余月份数。
int remainingCalendarMonths(DateTime date) => 13 - date.month;

/// 年度剩余额按剩余月份摊分后的每月可支出额。
double remainingAnnualBudgetPerMonth({
  required double annualBudget,
  required double yearToDateExpense,
  required int remainingMonths,
}) {
  final remaining = annualBudget - yearToDateExpense;
  return remainingMonths <= 0 ? remaining : remaining / remainingMonths;
}

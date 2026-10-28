import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';

const List<String> _weekLabels = ['一', '二', '三', '四', '五', '六', '日'];

/// 同一天（只看年月日，不看时分）。
bool sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// 一天上最多三个点，可以同时出现：开始型 / 截止型 / 已经干完的。
///
/// 打不打点由宿主决定——日历弹窗打（那天有什么要一眼看见），新建流程不打
/// （只关心选哪天，那天已经排了什么与这件事无关）。
class DayDots {
  final bool start;
  final bool deadline;
  final bool done;

  const DayDots({
    this.start = false,
    this.deadline = false,
    this.done = false,
  });

  bool get any => start || deadline || done;
}

/// 月历：页头（左右箭头）+ 星期行 + **固定六行**的网格，横向翻页切月。
///
/// 两个宿主共用这一份：日历弹窗（[日历弹窗](../dialogs/calendar_dialog.dart)）
/// 打点、点某天看安排、长按加一件；新建流程的第 1 页只选日期。
///
/// 网格固定六行（4 行的月份底部留白）：高度跟着月份变，滑动时整块会跳。
class MonthCalendar extends StatefulWidget {
  /// 高亮的那一天。null = 都不选。
  ///
  /// 按完整日期比而不是日号——滑动时相邻页同时在树里，日号相同的那一格
  /// 会跟着亮。
  final DateTime? selected;

  final ValueChanged<DateTime> onPick;

  /// 长按某天；null = 不接。
  final ValueChanged<DateTime>? onLongPress;

  /// 这天画什么点；null = 不打点。
  final DayDots Function(DateTime day)? dots;

  /// 翻到另一个月（传新页的月首日）。宿主用它清掉自己的选中态。
  final ValueChanged<DateTime>? onMonthChanged;

  /// 起始月份，缺省 = [selected] 所在月，再缺省 = 今天所在月。
  final DateTime? initialMonth;

  /// 六行网格的高度上限；null = 只按宽度推。
  ///
  /// 键盘抬起或者下半屏还要摆别的（日历弹窗的当天列表），可用高度不够时
  /// 按它再夹一道，否则格子会把下面的东西顶出去。
  final double? gridMaxHeight;

  const MonthCalendar({
    super.key,
    this.selected,
    required this.onPick,
    this.onLongPress,
    this.dots,
    this.onMonthChanged,
    this.initialMonth,
    this.gridMaxHeight,
  });

  @override
  State<MonthCalendar> createState() => _MonthCalendarState();
}

class _MonthCalendarState extends State<MonthCalendar> {
  /// 按**月序号**翻页（`2000-01` 记 0）：往前往后都算得出来，所以左右滑
  /// 不到头，不用手写可翻范围。
  static const int _baseYear = 2000;

  late final PageController _pageCtrl;
  late int _page;

  @override
  void initState() {
    super.initState();
    final m = widget.initialMonth ?? widget.selected ?? DateTime.now();
    _page = _monthIndex(DateTime(m.year, m.month));
    _pageCtrl = PageController(initialPage: _page);
  }

  @override
  void dispose() {
    _pageCtrl.dispose();
    super.dispose();
  }

  static int _monthIndex(DateTime m) => (m.year - _baseYear) * 12 + m.month - 1;

  static DateTime _monthAt(int index) =>
      DateTime(_baseYear + index ~/ 12, index % 12 + 1);

  DateTime get _month => _monthAt(_page);

  /// 箭头与横滑是同一个动作的两种走法：箭头走相邻一格。
  void _goToMonth(int page) {
    if (!_pageCtrl.hasClients) return;
    _pageCtrl.animateToPage(page,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic);
  }

  /// 一个月的网格：**固定六行**（4 行的月份底部留白）——高度跟着月份变
  /// 会让整块在滑动中跳。
  Widget _monthGrid(int page, DateTime today) {
    final month = _monthAt(page);
    // 周一为一周开始（`weekday` 里周一 = 1）。
    final lead = (month.weekday + 6) % 7;
    final days = DateTime(month.year, month.month + 1, 0).day;
    final isThisMonth = month.year == today.year && month.month == today.month;

    return Column(
      children: [
        for (var row = 0; row < 6; row++)
          Expanded(
            child: Row(
              children: [
                for (var col = 0; col < 7; col++)
                  Expanded(
                    child: _cellFor(
                      dayNumber: row * 7 + col - lead + 1,
                      daysInMonth: days,
                      month: month,
                      today: today,
                      isThisMonth: isThisMonth,
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _cellFor({
    required int dayNumber,
    required int daysInMonth,
    required DateTime month,
    required DateTime today,
    required bool isThisMonth,
  }) {
    if (dayNumber < 1 || dayNumber > daysInMonth) {
      return const SizedBox.shrink();
    }
    final day = DateTime(month.year, month.month, dayNumber);
    final selected = widget.selected != null && sameDay(day, widget.selected!);
    final marks = widget.dots?.call(day);
    return _DayCell(
      key: ValueKey('day-${day.year}-${day.month}-${day.day}'),
      day: dayNumber,
      isToday: isThisMonth && dayNumber == today.day,
      selected: selected,
      startMarked: marks?.start ?? false,
      deadlineMarked: marks?.deadline ?? false,
      doneMarked: marks?.done ?? false,
      onTap: () => widget.onPick(day),
      onLongPress:
          widget.onLongPress == null ? null : () => widget.onLongPress!(day),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final today = DateTime.now();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
          child: Row(
            children: [
              IconButton(
                onPressed: () => _goToMonth(_page - 1),
                icon: const Icon(Icons.chevron_left),
              ),
              Expanded(
                child: Center(
                  child: Text(
                    '${_month.year} 年 ${_month.month} 月',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              ),
              IconButton(
                onPressed: () => _goToMonth(_page + 1),
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
          child: LayoutBuilder(
            builder: (context, constraints) {
              // 格子宽度由容器宽度定，高度按老比例（宽:高 = 1.15）推，
              // 六行总高就是月历区的高度；网格高度有上限时再夹一道。
              final byWidth = constraints.maxWidth / 7 / 1.15;
              final limit = widget.gridMaxHeight;
              final cellH =
                  limit == null ? byWidth : math.min(byWidth, limit / 6);
              return Column(
                children: [
                  Row(
                    children: [
                      for (final w in _weekLabels)
                        Expanded(
                          child: Center(
                            child: Text(w,
                                style: theme.textTheme.bodySmall?.copyWith(
                                    color:
                                        theme.colorScheme.onSurfaceVariant)),
                          ),
                        ),
                    ],
                  ),
                  SizedBox(
                    height: cellH * 6,
                    child: PageView.builder(
                      controller: _pageCtrl,
                      onPageChanged: (page) {
                        setState(() => _page = page);
                        widget.onMonthChanged?.call(_monthAt(page));
                      },
                      itemBuilder: (context, page) => _monthGrid(page, today),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

class _DayCell extends StatelessWidget {
  final int day;
  final bool isToday;
  final bool selected;

  /// 这天有开始型的活欠着（开始点）。
  final bool startMarked;

  /// 这天有截止型的活欠着（截止点）。
  final bool deadlineMarked;

  /// 这天有已经干完的（完成点，不分类型）。三个可以同时出现。
  final bool doneMarked;

  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const _DayCell({
    super.key,
    required this.day,
    required this.isToday,
    required this.selected,
    required this.startMarked,
    required this.deadlineMarked,
    required this.doneMarked,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dots = AppColors.preset.dotsFor(theme.brightness);
    // 选中日整颗圈是强调色填充，开始点跟它同族、贴上去连成一片——那一格不画
    // 开始点（下面展开的列表本来就在说这天有什么）；截止点与完成点照画。
    final pips = <Color>[
      if (startMarked && !selected) dots.start,
      if (deadlineMarked) dots.deadline,
      if (doneMarked) dots.done,
    ];
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      onLongPress: onLongPress,
      // 格子矮的时候（窄屏、或键盘抬起把月历压小）整格等比缩小，而不是让
      // 33dp 的内容顶出格子——不然会看到黄黑条。
      child: Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                // 28 + 1 + 4 = 33dp。
                width: 28,
                height: 28,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: selected
                      ? AppColors.accent
                      : isToday
                          ? AppColors.accent.withValues(alpha: 0.16)
                          : null,
                ),
                child: Text(
                  '$day',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: selected || isToday ? FontWeight.w700 : null,
                    color: selected ? Colors.white : null,
                  ),
                ),
              ),
              const SizedBox(height: 1),
              SizedBox(
                height: 4,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0; i < pips.length; i++) ...[
                      if (i > 0) const SizedBox(width: 3),
                      _Pip(color: pips[i]),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 日期下面那颗小点（4dp，§8 的三色口径：开始 / 截止 / 完成，按对比度分三层深浅）。
class _Pip extends StatelessWidget {
  final Color color;
  const _Pip({required this.color});

  @override
  Widget build(BuildContext context) => Container(
        width: 4,
        height: 4,
        decoration: BoxDecoration(shape: BoxShape.circle, color: color),
      );
}

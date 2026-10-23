/// 今日编排（ui-interaction.md §6.11；存储格式见 docs/formats/plan.md）。
///
/// 编排与任务**不相交**：一条编排不是 `Task`——没有 id、没有完成态、不进调度、
/// 不占工时、不响提醒。它只是"今天打算几点做什么"的一张纸，和主线同族：一个文件
/// 装全部日子，正文就是数据，应用保存时按模型重写。
library;

/// 取当天零点（编排按"天"分段）。
DateTime planDay(DateTime d) => DateTime(d.year, d.month, d.day);

/// `2026-10-22`：文件里的日期段标题，也是按天查的键。
String planDayKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}'
    '-${d.month.toString().padLeft(2, '0')}'
    '-${d.day.toString().padLeft(2, '0')}';

/// 时间轴上的一条：时刻（可空 = 没写时刻）+ 标题。
///
/// 时刻存成"当天第几分钟"，不存 `DateTime`：编排不跨天，存完整时刻只会带来
/// "这条的日期和它所在那一天不一致"这种没人处理得了的状态。
class PlanEntry {
  /// 0–1439；null = 没有时刻（界面上显示 `—`）。
  final int? minutesOfDay;

  final String title;

  const PlanEntry({required this.title, this.minutesOfDay});

  bool get hasTime => minutesOfDay != null;

  /// `08:30`；没有时刻 → null。
  String? get timeText {
    final m = minutesOfDay;
    if (m == null) return null;
    final h = (m ~/ 60).toString().padLeft(2, '0');
    final mi = (m % 60).toString().padLeft(2, '0');
    return '$h:$mi';
  }

  PlanEntry copyWith({
    String? title,
    int? minutesOfDay,
    bool clearTime = false,
  }) =>
      PlanEntry(
        title: title ?? this.title,
        minutesOfDay: clearTime ? null : (minutesOfDay ?? this.minutesOfDay),
      );

  @override
  String toString() => 'PlanEntry(${timeText ?? '—'}, $title)';
}

/// 某一天的编排。行序就是顺序：改时刻 / 新增时由 [sortPlanEntries] 归位，拖动可临时覆盖。
class DayPlan {
  /// 当天零点。
  final DateTime day;

  final List<PlanEntry> entries;

  DayPlan({required this.day, List<PlanEntry> entries = const []})
      : entries = List.unmodifiable(entries);

  bool get isEmpty => entries.isEmpty;

  @override
  String toString() => 'DayPlan(${planDayKey(day)}, ${entries.length} 条)';
}

/// 按时刻升序重排一天：有时刻的在前（同一时刻保持原相对顺序），没有时刻的按原相对顺序
/// 沉到最后。
///
/// 改时刻、新增一条时走这里（[panels/plan.md](../../docs/panels/plan.md)『时间轴』）；
/// 拖动改顺序绕开它——那是唯一的手动覆盖。插入排序不是图省事：`List.sort` 不保证稳定，
/// 同一时刻的两条会被随手换位。
List<PlanEntry> sortPlanEntries(List<PlanEntry> entries) {
  final timed = <PlanEntry>[];
  final untimed = <PlanEntry>[];
  for (final e in entries) {
    if (e.minutesOfDay == null) {
      untimed.add(e);
    } else {
      timed.add(e);
    }
  }
  for (var i = 1; i < timed.length; i++) {
    final entry = timed[i];
    var j = i - 1;
    while (j >= 0 && timed[j].minutesOfDay! > entry.minutesOfDay!) {
      timed[j + 1] = timed[j];
      j--;
    }
    timed[j + 1] = entry;
  }
  return [...timed, ...untimed];
}

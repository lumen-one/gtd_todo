/// 今日编排（ui-interaction.md §6.11；存储格式见 docs/formats/plan.md）。
///
/// 编排与任务**不相交**：一条编排不是 `Task`——没有 id、没有完成态、不进调度、
/// 不占工时。它只是"今天打算几点做什么"的一张纸，和主线同族：一个文件装全部日子，
/// 正文就是数据，应用保存时按模型重写。
///
/// 到点提醒是这层纸唯一伸出去的手（决定卡 2026-10-29-plan-reminder）：条目到点发一条
/// 静音消息，但**不回写任何状态**——[PlanReminder.id] 只在单闹钟那一趟里认"这一站是
/// 谁"，不落盘，条目也不会因此长出完成态或推迟。
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

/// 编排到点提醒的 id 前缀：单闹钟与通知按它区分"这一站是条目还是任务"。
///
/// 条目本身没有 id（[PlanEntry] 只有时刻 + 标题），这个串是**临时**的：只在挂闹钟那一趟
/// 里认人，不落盘、不进文件。
const String planReminderPrefix = 'plan|';

/// `plan|2026-10-29|870` = 那一天那一刻的站点。**按分钟**：同一分钟的多条只响最早那条，
/// 所以同一分钟的条目共用一个站点（[panels/plan.md](../../docs/panels/plan.md)『到点提醒』）。
String planReminderId(DateTime day, int minutesOfDay) =>
    '$planReminderPrefix${planDayKey(day)}|$minutesOfDay';

bool isPlanReminderId(String id) => id.startsWith(planReminderPrefix);

/// 一条会到点响的编排条目（给 `ReminderDispatcher` 的第三个提醒源）。
///
/// 只排**未来**的时刻：过点即作废、不补响，所以它不像任务的 `point_fired` 那样需要幂等
/// 标记（[plan_service](../application/plan_service.dart) 的 `nextReminder`）。
class PlanReminder {
  /// [planReminderId] 算出来的站点 id。
  final String id;

  final DateTime at;

  final String title;

  const PlanReminder({required this.id, required this.at, required this.title});

  @override
  String toString() => 'PlanReminder($id, $title)';
}

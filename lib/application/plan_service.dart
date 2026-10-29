import 'dart:async';

import '../domain/plan.dart';
import '../repository/plan_repository.dart';

/// 今日编排的应用服务（ui-interaction.md §6.11）。
///
/// **与 TaskService 完全独立**：编排条目不是任务，这里不重锚调度、不发领域事件、
/// 不碰 `.gtd/`。它只做三件事：读整份 `编排.md`、改一天、整份写回；外加一件只读的事——
/// 给单闹钟递"下一条到点的条目"（[nextReminder]）。
///
/// 每个命令都是"**先读盘 → 改那一天 → 整份写回**"：两个引擎（应用内 / 悬浮窗）
/// 可能同时写同一个文件，读一遍再改能把"另一个引擎刚写的别的日子"带上，不至于被
/// 本地旧内存态抹掉（与主线同一套理由）。
class PlanService {
  final PlanRepository repo;

  List<DayPlan> _days = const [];

  /// 编排变了（读盘 / 任何命令之后）。单闹钟协调者据此重挂下一站——它不认识编排，
  /// 只认这个信号（决定卡 2026-10-29-plan-reminder）。
  final _changes = StreamController<void>.broadcast();

  PlanService({required this.repo});

  /// 变更信号（广播；没有监听者时也不会攒）。
  Stream<void> get changes => _changes.stream;

  /// 解析告警（诊断用）。
  List<String> get warnings => repo.warnings;

  /// 全部日子（新→旧）。
  List<DayPlan> get days => _days;

  /// 读盘（启动 / 文件变更 / 回前台时调；幂等）。
  Future<void> load() async {
    _days = _sort(await repo.loadAll());
    _notifyChanged();
  }

  /// 某一天的条目；没有编排 → 空表。
  List<PlanEntry> entriesFor(DateTime day) {
    final key = planDayKey(day);
    for (final d in _days) {
      if (planDayKey(d.day) == key) return d.entries;
    }
    return const [];
  }

  /// 下一条到点的条目：**严格晚于 [now]** 的最早一条；没有 → null。
  ///
  /// **只排未来**是这一源的全部幂等机制：响过的条目自然落在过去，重排时再也挑不到它，
  /// 所以 `编排.md` 不需要"已响"标记（代价：错过不补响，登记在 arch §11）。
  /// 同一分钟有多条时取文件里的第一条——它们的 [PlanReminder.id] 相同，站点只有一个。
  PlanReminder? nextReminder(DateTime now) {
    PlanReminder? best;
    for (final d in _days) {
      final day = planDay(d.day);
      for (final e in d.entries) {
        final m = e.minutesOfDay;
        if (m == null) continue;
        final at = DateTime(day.year, day.month, day.day, m ~/ 60, m % 60);
        if (!at.isAfter(now)) continue;
        if (best == null || at.isBefore(best.at)) {
          best = PlanReminder(
            id: planReminderId(day, m),
            at: at,
            title: e.title,
          );
        }
      }
    }
    return best;
  }

  /// 追加一条：按时刻归位（同刻的排在已有那几条之后）。
  Future<void> addEntry(DateTime day, PlanEntry entry) =>
      _mutate(day, (entries) => sortPlanEntries([...entries, entry]));

  /// 改一条（标题 / 时刻）。**只有时刻变了才重排**：只改标题不该打散拖出来的顺序。
  Future<void> updateEntry(DateTime day, int index, PlanEntry next) =>
      _mutate(day, (entries) {
        if (index < 0 || index >= entries.length) return entries;
        final out = [...entries]..[index] = next;
        return entries[index].minutesOfDay == next.minutesOfDay
            ? out
            : sortPlanEntries(out);
      });

  /// 删一条。
  Future<void> removeEntry(DateTime day, int index) =>
      _mutate(day, (entries) {
        if (index < 0 || index >= entries.length) return entries;
        return [...entries]..removeAt(index);
      });

  /// 整日重写（拖动改顺序走这里：一次落盘 + 一次通知）。**不排序**——拖动是手动顺序。
  Future<void> setEntries(DateTime day, List<PlanEntry> entries) =>
      _mutate(day, (_) => entries);

  /// 读盘 → 换掉那一天 → 整份写回。空的一天不落段（文件保持干净）。
  Future<void> _mutate(
    DateTime day,
    List<PlanEntry> Function(List<PlanEntry>) change,
  ) async {
    final disk = await repo.loadAll();
    final key = planDayKey(day);
    final next = <DayPlan>[];
    var found = false;

    for (final d in disk) {
      if (planDayKey(d.day) != key) {
        next.add(d);
        continue;
      }
      found = true;
      final entries = _normalize(change(d.entries));
      if (entries.isNotEmpty) next.add(DayPlan(day: d.day, entries: entries));
    }

    if (!found) {
      final entries = _normalize(change(const []));
      if (entries.isNotEmpty) {
        next.add(DayPlan(day: planDay(day), entries: entries));
      }
    }

    final sorted = _sort(next);
    await repo.saveAll(sorted);
    _days = sorted;
    _notifyChanged();
  }

  void _notifyChanged() {
    if (!_changes.isClosed) _changes.add(null);
  }

  /// 空标题的条目直接丢掉（输入框里按了回车又没写字的场景）。
  ///
  /// 已经规整的条目**原样拿回去**，不重新造成新对象：`PlanEntry` 没有值相等，
  /// 列表按对象身份做行 key——每次落盘都换一批新对象的话，拖动松手那一刻整列
  /// 行都会被当成新行重建（落下动画白做，看着像闪）。
  static List<PlanEntry> _normalize(List<PlanEntry> entries) => [
        for (final e in entries)
          if (e.title.trim().isNotEmpty)
            e.title == e.title.trim()
                ? e
                : PlanEntry(title: e.title.trim(), minutesOfDay: e.minutesOfDay),
      ];

  static List<DayPlan> _sort(List<DayPlan> days) =>
      [...days]..sort((a, b) => b.day.compareTo(a.day));
}

import '../domain/routine.dart';
import '../domain/schedule.dart';
import '../domain/task.dart';

/// 今日清单聚合查询（D12 / ui-interaction.md §6.1）：
/// 六种来源——挂起组（决议 47）+ ScheduleResult（可推/逾期）+ 固定时点组 +
/// 例行实例 + 被挑散件。这是查询不是渲染：UI 只消费结果，不含分组逻辑（守住"UI 不含逻辑"）。
///
/// 分组构成（决议 11/12/25/47）：
/// ⓿ 挂起进行（最顶、无编号、可拖；决议 47）→ ① 逾期（无编号置顶）→
/// ② 固定时点（时间升序）→ ③ 可推（插队件栈式压顶 + 调度序）→
/// ④ 例行（周期实例，决议 12）→ ⑤ 被挑散件（尾部）。
/// 编号跨 ②③④ 连续，由 UI 按 fixed→pinned→flex→routines 顺序生成。
/// 挂起组与调度模式无关（三档都在最顶）：它是持久意图，不是算法排序。
class TodayView {
  final DateTime day;

  /// ⓿ 挂起进行中的任务（v0.17，决议 47）：今日页最顶、逾期组之上、**无编号**；
  /// 按挂起时刻降序（后挂在上，`Task.inProgressAt`），组内可拖调序。
  /// 成员与调度模式无关（三档下都在），也不进任务池（`buildPoolView` 同规则隐藏）。
  final List<Task> inProgress;

  /// ① 过截止未完成：橙红徽标置顶，完成/改期前不消失（决议 2）。
  final List<Task> overdue;

  /// ② 今天到点的固定时点任务（时间升序，组内不可拖）。
  final List<Task> fixed;

  /// ③a 插队件（栈式：后插在上，保持到完成，决议 9）。
  final List<Task> pinned;

  /// ③b 其余可推任务（Slack 调度排序，infeasible 优先）。
  final List<Task> flex;

  /// ④ 周期任务当天实例（不占工时、默认不响；跳过今天的已剔除，决议 12/23）。
  final List<Task> routines;

  /// ⑤ 被挑散件（不编号、弱化呈现，决议 25）。
  final Task? picked;

  const TodayView({
    required this.day,
    this.inProgress = const [],
    this.overdue = const [],
    this.fixed = const [],
    this.pinned = const [],
    this.flex = const [],
    this.routines = const [],
    this.picked,
  });

  bool get isEmpty =>
      inProgress.isEmpty &&
      overdue.isEmpty &&
      fixed.isEmpty &&
      pinned.isEmpty &&
      flex.isEmpty &&
      routines.isEmpty &&
      picked == null;

  /// 今日清单上要编号的条目数（固定时点组 + 可推组 + 插队件；见 §1 名词表）。
  /// **不含提醒门槛**（v1.9）："会不会真的响"要看 `ScheduleResult` 里各任务的
  /// `reminds` / `reminderAt`——分组与编号在两种模式下完全一致，所以这里也不需要模式。
  int get count => overdue.length + fixed.length + pinned.length + flex.length;
}

/// 任务池条目（决议 27：计划段里任务与周期规则条目按日期混排）。
sealed class PoolRow {
  const PoolRow();

  /// 排序键：任务用截止时刻（无截止用创建时间），周期条目用发生时刻。
  DateTime get sortKey;
}

class PoolTaskRow extends PoolRow {
  final Task task;

  const PoolTaskRow(this.task);

  @override
  DateTime get sortKey => task.deadline ?? task.created;
}

class PoolRoutineRow extends PoolRow {
  final Routine routine;
  final DateTime at;

  const PoolRoutineRow(this.routine, this.at);

  @override
  DateTime get sortKey => at;

  RoutineOccurrence get occurrence =>
      RoutineOccurrence(routine: routine, at: at);
}

/// 任务池聚合查询（ui-interaction.md §6.3）：一条横线分两段。
class PoolView {
  /// 横线前（计划段）：明天及以后的任务（有截止 flex + 未来 fixed）。
  final List<Task> plan;

  /// 横线后（散件段）：全部三无散件（被挑走的今日不重复出现）。
  final List<Task> loose;

  /// 计划段的显示行：手工整理过的任务在前，其余任务与周期条目按日期混排
  /// （决议 14 + 决议 27；周期条目是否显示由设置 `routineShowInPool` 决定）。
  final List<PoolRow> rows;

  const PoolView({
    required this.plan,
    required this.loose,
    this.rows = const [],
  });

  bool get isEmpty => plan.isEmpty && loose.isEmpty;
}

String dayMark(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}'
    '-${d.day.toString().padLeft(2, '0')}';

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// 聚合今日清单。[schedule] 为当前调度结果（可推组排序 + "提醒锚点"口径来源）。
///
/// [scheduleMode] 只改**一件**事（v1.12 决议 43 / D17）：可推组的**顺序**——
/// 标准/完整是"插队件压顶 + 调度序"，无排序是手动序（`manual_order`）。
/// 可推组的**成员不变**（仍按"锚点落在今天 / 今天到期"准入），
/// 挂起组置顶、逾期置顶、固定时点按时刻、例行按发生时刻、被挑散件在最后——
/// 三档全部一致（挂起组是持久意图，决议 47）。
TodayView buildTodayView({
  required List<Task> tasks,
  required ScheduleResult? schedule,
  required DateTime now,
  ScheduleMode scheduleMode = ScheduleMode.standard,
}) {
  final today = DateTime(now.year, now.month, now.day);
  final mark = dayMark(today);

  // 手动挑过的日子自动挑让位（决议 8）： picked 即今日尾部那一件。
  // **挂起中的件不当 picked**（决议 47）：它的显示位置是挂起组，取消挂起后
  // （当日标记还在）才回⑤。
  var pickedTask = tasks
      .where((t) =>
          !t.isCompleted &&
          t.pickedForDate == mark &&
          t.inProgressAt == null)
      .firstOrNull;

  final overdue = <Task>[];
  final fixed = <Task>[];
  final flexCandidates = <Task>[];
  final routines = <Task>[];
  final inProgress = <Task>[];

  for (final t in tasks) {
    if (t.isCompleted) continue;
    // ⓿ 挂起组（决议 47）：持久意图顶置最顶——不进其余任何组（逾期/固定/可推/例行
    // 都不收它），任务池也不重复出现（buildPoolView 同规则隐藏）。与调度模式无关。
    // **必须排在 picked 的 identical 跳过之前**：挂着又恰好被挑的件，显示位置是
    // 挂起组；取消挂起后它才回⑤（picked 是当日标记，还留在 metadata 里）。
    if (t.inProgressAt != null) {
      inProgress.add(t);
      continue;
    }
    if (identical(t, pickedTask)) continue;
    final deadline = t.deadline;
    switch (t.type) {
      case TaskType.routine:
        // ④ 例行组：当天实例（决议 12）；跳过今天的今日不再显示（决议 23）。
        if (t.routineDate == mark && !t.isRoutineSkippedOn(mark)) {
          routines.add(t);
        }
      case TaskType.fixed:
        if (deadline == null) continue;
        if (deadline.isBefore(now)) {
          overdue.add(t); // 固定时点过点未完成 → 逾期组
        } else if (_sameDay(deadline, now)) {
          fixed.add(t);
        }
        // 明天及以后的 fixed → 任务池计划段，不进今日。
      case TaskType.flex:
        if (deadline != null && deadline.isBefore(now)) {
          overdue.add(t);
          continue;
        }
        // "提醒锚点落在今天"或今天到期（§6.1）；snoozed 到期前不出现，
        // 到期后下一次重锚自然回来。无截止散件不进今日（进池子/被挑）。
        // v1.9：锚点是调度计算，**不受提醒模式影响**——标准/完整两种模式下
        // 这一页的构成与顺序完全一样，差别只在会不会真的弹通知（D15）。
        final metric = schedule?.metricOf(t.id);
        final reminderToday = metric?.nextReminderAt != null &&
            _sameDay(metric!.nextReminderAt!, now);
        final dueToday = deadline != null && _sameDay(deadline, now);
        // 准入**不受排序模式影响**（决议 43 修正）：无排序只是"今天这几件不排序"，
        // 不是"把所有任务都塞进今天"——成员与自动模式完全一致，只有顺序不同。
        if (reminderToday || dueToday) flexCandidates.add(t);
    }
  }

  fixed.sort((a, b) => a.deadline!.compareTo(b.deadline!));

  // 挂起组：挂起时刻降序（后挂在上，决议 47——与插队栈同一形状）。
  inProgress.sort((a, b) => b.inProgressAt!.compareTo(a.inProgressAt!));

  // 插队件栈式压顶：pinned 时刻降序（后插在上，决议 9）。
  final pinned = flexCandidates
      .where((t) => t.pinnedAt != null)
      .toList()
    ..sort((a, b) => b.pinnedAt!.compareTo(a.pinnedAt!));
  final pinnedIds = pinned.map((t) => t.id).toSet();

  // 其余可推按调度序（schedule.items 已按 priority 降序，infeasible 优先）。
  final orderIndex = <String, int>{
    for (var i = 0; i < (schedule?.items.length ?? 0); i++)
      schedule!.items[i].taskId: i,
  };
  final flex = flexCandidates.where((t) => !pinnedIds.contains(t.id)).toList()
    ..sort((a, b) => (orderIndex[a.id] ?? 1 << 30)
        .compareTo(orderIndex[b.id] ?? 1 << 30));

  // 例行组：有时刻的按时刻升序，其余按标题（当天实例之间无优先级）。
  routines.sort((a, b) {
    final da = a.deadline;
    final db = b.deadline;
    if (da != null && db != null) return da.compareTo(db);
    if (da != null) return -1;
    if (db != null) return 1;
    return a.title.compareTo(b.title);
  });

  // 无排序：整组改用手动序（人拖出来的顺序），没有"插队压顶"这一层——
  // 插队是为算法排序打的补丁，顺序本身就由人定的时候不需要它。
  // 插队标记（pinned）仍然留在任务上——切回标准/完整时它照旧生效。
  // **挂起组与排序模式无关**（决议 47）：三档下它都在最顶、都按挂起时刻降序。
  if (scheduleMode.isManual) {
    return TodayView(
      day: now,
      inProgress: List.unmodifiable(inProgress),
      overdue: List.unmodifiable(overdue),
      fixed: List.unmodifiable(fixed),
      flex: List.unmodifiable(flexCandidates..sort(compareManualOrder)),
      routines: List.unmodifiable(routines),
      picked: pickedTask,
    );
  }

  return TodayView(
    day: now,
    inProgress: List.unmodifiable(inProgress),
    overdue: List.unmodifiable(overdue),
    fixed: List.unmodifiable(fixed),
    pinned: List.unmodifiable(pinned),
    flex: List.unmodifiable(flex),
    routines: List.unmodifiable(routines),
    picked: pickedTask,
  );
}

/// 聚合任务池。[routineOccurrences] = 周期规则的未来发生（决议 27；
/// [routineShowInPool] = false 时按设置不显示）。
PoolView buildPoolView({
  required List<Task> tasks,
  required DateTime now,
  List<RoutineOccurrence> routineOccurrences = const [],
  bool routineShowInPool = true,
}) {
  final plan = <Task>[];
  final loose = <Task>[];
  final startOfTomorrow = DateTime(now.year, now.month, now.day + 1);

  for (final t in tasks) {
    if (t.isCompleted) continue;
    // 挂起中的任务只在今日页顶置组出现（决议 47）：池子两段都不重复显示。
    if (t.inProgressAt != null) continue;
    // 周期实例：当天实例归今日清单（决议 12）；更早的实例（昨日未完成）
    // 不重复出现在计划段——规则的下一次发生由 routineOccurrences 表达。
    if (t.type == TaskType.routine) continue;
    final deadline = t.deadline;
    if (t.type == TaskType.fixed || deadline != null) {
      // 计划段 = 明天及以后；逾期件按决议 2 保留在计划段标橙；
      // 今天的任务归今日清单，不进池子。
      if (deadline != null &&
          (deadline.isBefore(now) || !deadline.isBefore(startOfTomorrow))) {
        plan.add(t);
      }
      continue;
    }
    // 三无散件；当日被挑走的不重复显示（今日尾部最多一件，决议 8）。
    if (t.pickedForDate == dayMark(now)) continue;
    loose.add(t);
  }

  int cmp(Task a, Task b) {
    final oa = a.poolOrder;
    final ob = b.poolOrder;
    if (oa != null && ob != null) return oa.compareTo(ob);
    if (oa != null) return -1; // 整理过的排前面
    if (ob != null) return 1;
    // 计划段按截止升序；散件按创建时间（新建进组末尾，决议 14）。
    final da = a.deadline;
    final db = b.deadline;
    if (da != null && db != null) return da.compareTo(db);
    return a.created.compareTo(b.created);
  }

  plan.sort(cmp);
  loose.sort(cmp);

  // 计划段显示行：手工整理过的任务在前；其余任务与周期条目按日期混排
  // （决议 27：周期任务按下一次发生日期升序插入对应位置）。
  final rows = <PoolRow>[
    for (final t in plan)
      if (t.poolOrder != null) PoolTaskRow(t),
  ];
  final manualIds = {
    for (final t in plan)
      if (t.poolOrder != null) t.id,
  };
  final autoTasks = [
    for (final t in plan)
      if (!manualIds.contains(t.id)) PoolTaskRow(t),
  ];
  final routineRows = <PoolRow>[
    if (routineShowInPool)
      for (final o in routineOccurrences) PoolRoutineRow(o.routine, o.at),
  ];
  var i = 0;
  var j = 0;
  while (i < autoTasks.length || j < routineRows.length) {
    final takeTask = j >= routineRows.length ||
        (i < autoTasks.length &&
            !autoTasks[i].sortKey.isAfter(routineRows[j].sortKey));
    if (takeTask) {
      rows.add(autoTasks[i++]);
    } else {
      rows.add(routineRows[j++]);
    }
  }

  return PoolView(
    plan: List.unmodifiable(plan),
    loose: List.unmodifiable(loose),
    rows: List.unmodifiable(rows),
  );
}

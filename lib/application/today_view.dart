import '../domain/routine.dart';
import '../domain/schedule.dart';
import '../domain/task.dart';

/// 今日清单聚合查询（D12 / ui-interaction.md §6.1）：
/// 七种来源——挂起组（决议 47）+ ScheduleResult（截止型/逾期）+ 开始型组 +
/// 例行实例 + 被挑散件 + 散件段（v1.27，仅无排序档）。这是查询不是渲染：UI 只消费
/// 结果，不含分组逻辑（守住"UI 不含逻辑"）。
///
/// 分组构成（决议 11/12/25/47）：
/// ⓿ 挂起进行（最顶、无编号、可拖；决议 47）→ ① 逾期（无编号置顶）→
/// ② 开始型（时间升序）→ ③ 截止型（插队件栈式压顶 + 调度序）→
/// ④ 例行（周期实例，决议 12）→ ⑤ 被挑散件 → ⑥ 散件段（v1.27，仅无排序档，页底）。
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

  /// ② 今天到点的开始型任务（时间升序，组内不可拖）。
  final List<Task> fixed;

  /// ③a 插队件（栈式：后插在上，保持到完成，决议 9）。
  final List<Task> pinned;

  /// ③b 其余截止型任务（Slack 调度排序，infeasible 优先）。
  final List<Task> flex;

  /// ④ 周期任务当天实例（不占工时、默认不响；跳过今天的已剔除，决议 12/23）。
  final List<Task> routines;

  /// ⑤ 被挑散件（不编号、弱化呈现，决议 25）。
  final Task? picked;

  /// ⑥ 散件段（v1.27，**仅无排序档**）：池子里的全部三无散件，附在 ⑤ 之后、本页最底。
  /// 不编号、弱化呈现；拖动只改整理序（`pool_order`），与 ③ 的手动序互不相干。
  /// 被挑中的那件在 [picked]（⑤），这里不含它——同一件事只有一个显示位置；
  /// 其余两档恒为空（它们在任务池散件段）。
  final List<Task> loose;

  const TodayView({
    required this.day,
    this.inProgress = const [],
    this.overdue = const [],
    this.fixed = const [],
    this.pinned = const [],
    this.flex = const [],
    this.routines = const [],
    this.picked,
    this.loose = const [],
  });

  bool get isEmpty =>
      inProgress.isEmpty &&
      overdue.isEmpty &&
      fixed.isEmpty &&
      pinned.isEmpty &&
      flex.isEmpty &&
      routines.isEmpty &&
      picked == null &&
      loose.isEmpty;

  /// 今日清单上要编号的条目数（开始型组 + 截止型组 + 插队件；见 §1 名词表）。
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
  /// 横线前（计划段）：明天及以后的任务（有截止 flex + 未来 fixed），按日期升序。
  final List<Task> plan;

  /// 横线后（散件段）：全部三无散件（被挑走的今日不重复出现）。
  final List<Task> loose;

  /// 计划段的显示行：任务与周期条目按日期混排（决议 27；周期条目是否显示由设置
  /// `routineShowInPool` 决定）。**没有"手动整理过的在前"这一层**——计划段不可拖
  /// （[决定](../docs/decisions/2026-10-31-pool-plan-date-order.md)）。
  final List<PoolRow> rows;

  /// 无排序档被搬去今日页底部的散件数（v1.27）：[loose] 在这档为空，
  /// 这个数只用来区分"池子真空"与"散件都在今日清单底部"。
  final int hiddenLooseCount;

  const PoolView({
    required this.plan,
    required this.loose,
    this.rows = const [],
    this.hiddenLooseCount = 0,
  });

  bool get isEmpty => plan.isEmpty && loose.isEmpty;
}

String dayMark(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}'
    '-${d.day.toString().padLeft(2, '0')}';

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// 整理序（`pool_order` → 创建时间）：任务池散件段与今日页 ⑥ 散件段共用。
/// **计划段不用它**——那一段按日期升序，见 [buildPoolView]。
/// 与 ③ 的手动序（`manual_order`）是两套序号，互不参与。
int compareLooseOrder(Task a, Task b) {
  final oa = a.poolOrder;
  final ob = b.poolOrder;
  if (oa != null && ob != null) return oa.compareTo(ob);
  if (oa != null) return -1; // 整理过的排前面
  if (ob != null) return 1;
  return a.created.compareTo(b.created);
}

/// 编排与支线的候选来源：今日清单各段 + 任务池两段，按"今天该做的在前"排好。
///
/// **不截断**（[arrangeCandidates] 只给顺序，框多高、怎么滚由界面定）。原先两页各抄
/// 一份候选逻辑，都带"最多六条"——挂起组排在最前，挂起件一到六件，别的任务就再也进
/// 不了那张表，看上去像"候选里只有挂起的任务"（[panels/plan.md](../../docs/panels/plan.md)
/// 『添加、拖动、编辑』）。
///
/// [includeRoutines] 给支线关掉：例行实例是当天的，明天就不在了，挂进去只剩失效引用。
List<Task> arrangeCandidates({
  required TodayView today,
  required PoolView pool,
  bool includeRoutines = true,
}) {
  final out = <Task>[];
  final seen = <String>{};
  void take(Iterable<Task> tasks) {
    for (final t in tasks) {
      if (seen.add(t.id)) out.add(t);
    }
  }

  take(today.inProgress);
  take(today.overdue);
  take(today.fixed);
  take(today.pinned);
  take(today.flex);
  if (includeRoutines) take(today.routines);
  final picked = today.picked;
  if (picked != null) take([picked]);
  take(today.loose);
  take(pool.plan);
  take(pool.loose);
  return out;
}

/// 输入框里的字按标题做包含匹配（不分大小写）；空串原样返回。
List<Task> filterCandidates(List<Task> ordered, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return ordered;
  return [
    for (final t in ordered)
      if (t.title.toLowerCase().contains(q)) t,
  ];
}

/// 聚合今日清单。[schedule] 为当前调度结果（截止型组排序 + "提醒锚点"口径来源）；
/// 无排序档不用它——那一档既不排序也没有锚点（`TaskService.lastSchedule` 是空结果）。
///
/// [scheduleMode] 改**三件**事（决议 43 / D17 / 决定卡 mode-as-information-depth）：
/// ① ③ 组的**成员**——标准档按"锚点落在今天 / 今天到期"准入；无排序只认
/// "今天到期"（没有锚点这层），所以"裕度薄、今天该动手"的远期件这一档不进来；
/// ② ③ 组的**顺序**——标准档是"插队件压顶 + 调度序"，无排序是手动序
/// （`manual_order`）；③ 页底 ⑥ 散件段只在无排序档出现（任务池那边同步隐藏）。
/// 其余成员不变：挂起组置顶、逾期置顶、开始型按时刻、例行按发生时刻、
/// 被挑散件在倒数第二——三档一致（挂起组是持久意图，决议 47）。
TodayView buildTodayView({
  required List<Task> tasks,
  required ScheduleResult? schedule,
  required DateTime now,
  ScheduleMode scheduleMode = ScheduleMode.standard,
}) {
  final today = DateTime(now.year, now.month, now.day);
  final mark = dayMark(today);

  // 手动挑过的日子自动挑让位（决议 8）： picked 即今日尾部那一件。
  // **无排序档没有这一件**：那一档不跑定期挑，散件整段在 ⑥——"挑上来"没有去处。
  // **挂起中的件不当 picked**（决议 47）：它的显示位置是挂起组，取消挂起后
  // （当日标记还在）才回⑤。
  var pickedTask = scheduleMode.isManual
      ? null
      : tasks
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
  final loose = <Task>[];

  for (final t in tasks) {
    if (t.isCompleted) continue;
    // ⓿ 挂起组（决议 47）：持久意图顶置最顶——不进其余任何组（逾期/固定/截止型/例行
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
          overdue.add(t); // 开始型过点未完成 → 逾期组
        } else if (_sameDay(deadline, now)) {
          fixed.add(t);
        }
        // 明天及以后的 fixed → 任务池计划段，不进今日。
      case TaskType.flex:
        if (deadline != null && deadline.isBefore(now)) {
          overdue.add(t);
          continue;
        }
        // 无截止散件（v1.27）：**只在无排序档**进页底 ⑥；标准档归任务池
        // 散件段（或被挑）。这是三档之间唯一的成员差异，其余成员仍按锚点准入。
        // 标了 `loose_home: pool` 的例外——它们住在池子散件段（长按搬过去）。
        if (deadline == null) {
          if (scheduleMode.isManual && !t.looseHomeIsPool) loose.add(t);
          continue;
        }
        // "提醒锚点落在今天"或今天到期（§6.1）；snoozed 到期前不出现，
        // 到期后下一次重锚自然回来。
        // v1.9：锚点是调度计算，**与响不响铃无关**——标准档下这一页的构成与
        // 顺序只看锚点，『响铃』只在送达那一刻决定出不出声（D15 / B4）。
        final dueToday = _sameDay(deadline, now);
        if (scheduleMode.isManual) {
          // 无排序档不跑调度（§3.1）：没有锚点这一层，成员只认"今天到期"。
          // 所以"裕度薄、今天该动手"的远期任务留在任务池，等当天到期才出现。
          if (dueToday) flexCandidates.add(t);
          continue;
        }
        final metric = schedule?.metricOf(t.id);
        final reminderToday = metric?.nextReminderAt != null &&
            _sameDay(metric!.nextReminderAt!, now);
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

  // 其余截止型按调度序（schedule.items 已按 priority 降序，infeasible 优先）。
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
  // 插队标记（pinned）仍然留在任务上——切回标准档时它照旧生效。
  // **挂起组与排序模式无关**（决议 47）：三档下它都在最顶、都按挂起时刻降序。
  if (scheduleMode.isManual) {
    // ⑥ 散件段（v1.27）：整理序，与池子散件段同一个比较器。
    loose.sort(compareLooseOrder);
    return TodayView(
      day: now,
      inProgress: List.unmodifiable(inProgress),
      overdue: List.unmodifiable(overdue),
      fixed: List.unmodifiable(fixed),
      flex: List.unmodifiable(flexCandidates..sort(compareManualOrder)),
      routines: List.unmodifiable(routines),
      picked: pickedTask,
      loose: List.unmodifiable(loose),
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
///
/// [splitLoose]（无排序档）：散件按 metadata `loose_home` 分家——池子这边只收
/// 标了 `pool` 的那些，其余整段在今日页底部（[TodayView.loose]）；
/// [PoolView.hiddenLooseCount] 给空状态文案用。同一件任务在无排序档只有一个家。
PoolView buildPoolView({
  required List<Task> tasks,
  required DateTime now,
  List<RoutineOccurrence> routineOccurrences = const [],
  bool routineShowInPool = true,
  bool splitLoose = false,
}) {
  final plan = <Task>[];
  final loose = <Task>[];
  var looseInToday = 0;
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
    // 三无散件。
    if (splitLoose) {
      // 无排序档：只有搬过来的（`loose_home: pool`）住池子，其余整段在今日页 ⑥。
      // 当日"被挑"的标记这一档不参与——那一档不跑定期挑，⑤ 不出现。
      if (t.looseHomeIsPool) {
        loose.add(t);
      } else {
        looseInToday++;
      }
      continue;
    }
    // 标准档：当日被挑走的不重复显示（今日尾部最多一件，决议 8）。
    if (t.pickedForDate == dayMark(now)) continue;
    loose.add(t);
  }

  // 计划段：**日期升序**，同日按创建时间（新建的在后）。这一段的读法是"哪天轮到我"，
  // 手动整理序一旦写下就永久压在日期前面，一条 11-01 会一直排在 10-20 上面
  // （[决定](../docs/decisions/2026-10-31-pool-plan-date-order.md)）。散件段仍按整理序：
  // 散件没有日期可比，那个位置才需要人来定。
  plan.sort((a, b) {
    final c = a.deadline!.compareTo(b.deadline!);
    return c != 0 ? c : a.created.compareTo(b.created);
  });
  loose.sort(compareLooseOrder);

  // 计划段显示行：任务与周期条目按日期混排（决议 27：周期任务按下一次发生日期升序
  // 插入对应位置）。两条路各自已按日期排好，归并一次就够。
  final planTasks = <PoolRow>[for (final t in plan) PoolTaskRow(t)];
  final routineRows = <PoolRow>[
    if (routineShowInPool)
      for (final o in routineOccurrences) PoolRoutineRow(o.routine, o.at),
  ];
  final rows = <PoolRow>[];
  var i = 0;
  var j = 0;
  while (i < planTasks.length || j < routineRows.length) {
    final takeTask = j >= routineRows.length ||
        (i < planTasks.length &&
            !planTasks[i].sortKey.isAfter(routineRows[j].sortKey));
    if (takeTask) {
      rows.add(planTasks[i++]);
    } else {
      rows.add(routineRows[j++]);
    }
  }

  return PoolView(
    plan: List.unmodifiable(plan),
    loose: List.unmodifiable(loose),
    rows: List.unmodifiable(rows),
    hiddenLooseCount: splitLoose ? looseInToday : 0,
  );
}

/// 已完成任务归档查询（ui-interaction.md §6.7 已完成页）：
/// 按完成日期分三组。这是查询不是渲染：UI 只消费结果，不含分组逻辑
/// （与 [buildTodayView] / [buildPoolView] 同规则）。
///
/// 完成的任务不进今日清单与任务池（`isCompleted` 即排除），但那一行原样留在
/// 人类文档里——这一页就是它在 App 里的落脚处。与调度模式三档无关：存档不参与
/// 排序，`buildCompletedView` 不收 `scheduleMode`。
class CompletedView {
  /// 今天完成的（`completedAt` 与今天同一天），按完成时刻降序。
  final List<Task> today;

  /// 昨天完成的，按完成时刻降序。
  final List<Task> yesterday;

  /// 更早完成的，按完成时刻降序；**没有完成时刻的**（人在 Obsidian 里手打了勾）
  /// 垫在末尾、按创建时间降序——完成日期属人写的那半边，内核不猜。
  final List<Task> earlier;

  const CompletedView({
    this.today = const [],
    this.yesterday = const [],
    this.earlier = const [],
  });

  bool get isEmpty => today.isEmpty && yesterday.isEmpty && earlier.isEmpty;
}

/// 组内排序：有完成时刻的按时刻降序（最新完成的在上）；都无时刻的按创建时间
/// 降序；两者混排时"有时刻的在前"（无时刻的是手勾的历史件，垫底）。
int _compareCompleted(Task a, Task b) {
  final ca = a.completedAt;
  final cb = b.completedAt;
  if (ca != null && cb != null) return cb.compareTo(ca);
  if (ca != null) return -1;
  if (cb != null) return 1;
  return b.created.compareTo(a.created);
}

/// 聚合已完成任务（ui 文档 §6.7）。
CompletedView buildCompletedView({
  required List<Task> tasks,
  required DateTime now,
}) {
  final today = DateTime(now.year, now.month, now.day);
  final yesterday = today.subtract(const Duration(days: 1));
  final todayDone = <Task>[];
  final yesterdayDone = <Task>[];
  final earlierDone = <Task>[];

  for (final t in tasks) {
    if (!t.isCompleted) continue;
    final at = t.completedAt;
    if (at == null) {
      earlierDone.add(t); // 手勾无时刻：归『更早』末尾（排序器负责垫底）
      continue;
    }
    final day = DateTime(at.year, at.month, at.day);
    if (day == today) {
      todayDone.add(t);
    } else if (day == yesterday) {
      yesterdayDone.add(t);
    } else {
      earlierDone.add(t);
    }
  }

  for (final group in [todayDone, yesterdayDone, earlierDone]) {
    group.sort(_compareCompleted);
  }

  return CompletedView(
    today: List.unmodifiable(todayDone),
    yesterday: List.unmodifiable(yesterdayDone),
    earlier: List.unmodifiable(earlierDone),
  );
}

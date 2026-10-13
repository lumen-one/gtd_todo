import 'dart:async';
import 'dart:math';

import '../domain/event.dart';
import '../domain/reminder.dart';
import '../domain/routine.dart';
import '../domain/schedule.dart';
import '../domain/task.dart';
import '../domain/time_context.dart';
import '../repository/task_repository.dart';
import '../scheduler/scheduler.dart';

/// Application 层协调者：用户行为 → 系统行为。
///
/// - 唯一写入口（§3.2 C1）：一切状态变更（用户/AI/迁移）都化作这里的命令，
///   不变量 A1–A4 在此守护；
/// - 每个命令发领域事件（含 origin），订阅者见 §3.3；
/// - 每个命令后重锚调度（C2 防 Zeno：只有事件才重锚）；
/// - reload 从仓库重读全部任务——文件监听/Obsidian 手改由此回流。
class TaskService {
  final TaskRepository repo;
  final Scheduler scheduler;
  final WorkTimeRule workRule;

  /// **调度模式**（v1.12，决议 43）：**完整 / 标准 / 无排序**三档，默认标准。
  ///
  /// 它同时决定两件事：给内核的**提醒门槛**（[ScheduleMode.reminderMode]）与
  /// 业务层的**清单顺序**（[ScheduleMode.isManual]）。设置页改动经装配点回调调
  /// [updateScheduleMode]；模式只改查询口径与调度入参，**不动任何任务数据**。
  ScheduleMode scheduleMode;

  /// 给内核的提醒门槛（三档 → 标准/完整两档：无排序也是"只排列不提醒"）。
  ReminderMode get reminderMode => scheduleMode.reminderMode;

  /// 是否关掉排序（今日可推组改用手动序）。
  bool get isManualSort => scheduleMode.isManual;

  /// 可注入时钟：测试与仿真可以自由拨动时间。
  final DateTime Function() now;

  final StreamController<DomainEvent> _events =
      StreamController<DomainEvent>.broadcast();

  List<Task> _tasks = [];
  ScheduleResult? lastSchedule;

  TaskService({
    required this.repo,
    required this.scheduler,
    this.workRule = WorkTimeRule.standard,
    this.scheduleMode = ScheduleMode.standard,
    DateTime Function()? clock,
  }) : now = clock ?? DateTime.now;

  /// 领域事件流（broadcast）：UI/AI/同步各自订阅。
  Stream<DomainEvent> get events => _events.stream;

  /// 解析与合并告警（附录 B 流向）。
  List<String> get warnings => repo.warnings;

  List<Task> get tasks => List.unmodifiable(_tasks);

  Task? byId(String id) {
    for (final t in _tasks) {
      if (t.id == id) return t;
    }
    return null;
  }

  /// 重新读取仓库并重新调度（重锚提醒间隔）。
  ///
  /// C2 防 Zeno：只应在事件发生时调用（命令 / 提醒到点 / 文件变更），
  /// 不要在周期 tick 里无条件调用，否则提醒永远到不了点。
  Future<void> refreshSchedule({EventOrigin origin = EventOrigin.system}) async {
    await _reload();
    lastSchedule = scheduler.schedule(
      tasks: _tasks,
      now: now(),
      workRule: workRule,
      reminderMode: scheduleMode.reminderMode,
    );
    _emit(DomainEventType.scheduleReanchored, lastSchedule?.nextTaskId ?? '',
        origin);
  }

  /// 切换调度模式（设置页 → 装配点回调，D15 / D17）。
  ///
  /// **不改任何任务数据**：门槛是计算结果（D1），顺序是查询结果，重算即生效；
  /// 手动序是持久意图（B5），自动档下原样躺在 metadata 里，切回来还在。
  /// 模式没变就什么都不做（C2 的精神：只在真的有事发生时重锚）。
  Future<void> updateScheduleMode(ScheduleMode mode) async {
    if (mode == scheduleMode) return;
    scheduleMode = mode;
    _emit(DomainEventType.scheduleModeChanged, '', EventOrigin.user);
    await refreshSchedule();
  }

  Future<void> _reload() async {
    final loaded = await repo.loadAll();
    final current = now();
    final result = <Task>[];
    for (final t in loaded) {
      // A4：snooze 到期自动回到 active。
      if (t.status == TaskStatus.snoozed &&
          t.snoozedUntil != null &&
          !t.snoozedUntil!.isAfter(current)) {
        final fixed = t.copyWith(status: TaskStatus.active, clearSnooze: true);
        await repo.save(fixed);
        result.add(fixed);
      } else {
        result.add(t);
      }
    }
    _tasks = result;
  }

  // ---------- 命令（唯一写入口）----------

  /// 创建任务（§3.5 规划表：签名改造落地）。
  ///
  /// - [type] = fixed：必须有 [deadline]；估工时不需要，豁免 A2（可为 0）；
  /// - [type] = flex（默认）：[deadline] 可选（null = 三无散件）；
  ///   估工时缺省 30 分钟，且必须 ≥ 1（A2）。
  Future<Task> createTask({
    required String title,
    TaskType type = TaskType.flex,
    DateTime? deadline,
    int? estimatedWorkMinutes,
    int importance = 3,
    String description = '',
    EventOrigin origin = EventOrigin.user,
  }) async {
    if (title.trim().isEmpty) {
      throw ArgumentError.value(title, 'title', '标题不能为空');
    }
    if (type == TaskType.routine) {
      // 周期实例只能由规则生成（RoutineService），不能凭空创建。
      throw ArgumentError('周期实例不通过 createTask 创建（改规则即可）');
    }
    if (type == TaskType.fixed && deadline == null) {
      throw ArgumentError.value(deadline, 'deadline', '固定时点任务必须有截止时刻');
    }
    final est = estimatedWorkMinutes ?? (type == TaskType.fixed ? 0 : 30);
    // A2（fixed 豁免允许 0，flex 必须 ≥ 1）
    if (est < (type == TaskType.fixed ? 0 : 1)) {
      throw ArgumentError.value(
          estimatedWorkMinutes, 'estimatedWorkMinutes', 'estimatedWork 非法');
    }
    final task = Task(
      // 时间戳 + 随机尾巴：同一毫秒内连续创建也不会撞 id。
      id: 'task-${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}'
          '-${Random().nextInt(0x10000).toRadixString(36).padLeft(4, '0')}',
      title: title,
      deadline: deadline,
      estimatedWork: est,
      importance: importance.clamp(1, 5),
      description: description,
      created: now(),
      metadata: type == TaskType.fixed
          ? const {'type': 'fixed'}
          : const {},
    );
    await repo.save(task);
    _tasks = [..._tasks, task];
    _emit(DomainEventType.taskCreated, task.id, origin);
    await refreshSchedule(origin: origin);
    return task;
  }

  /// 完成。**完成时刻在此刻落下**（ui 文档 §6.1 / 附录 B）：人类文档那一行补
  /// `完成 <日期,时间>` 并打勾，内核属性文档同步落 `completed_at`——两者都由
  /// [Task.completedAt] 这一个字段驱动（[TaskDocumentCodec.encodeLine] 与
  /// [TaskSidecarCodec] 各取它渲染）。
  ///
  /// 人在 Obsidian 里已经手写了完成时刻的，保留人的那个值（§4.3 归属表：
  /// 完成日期属人写的那半边）。
  Future<Task> completeTask(String id,
      {EventOrigin origin = EventOrigin.user}) async {
    final cur = _require(id);
    final updated = cur.copyWith(
      status: TaskStatus.completed,
      remainingWork: 0,
      completedAt: cur.completedAt ?? now(),
      clearSnooze: true,
    );
    await _persist(updated, origin, DomainEventType.taskCompleted);
    return updated;
  }

  /// 推迟不是简单 Timer：改变任务状态后触发对整个任务集合的重新调度。
  /// D8 语义：[minutes] 为**自然时间**分钟（≤120 的短推）。
  Future<Task> snoozeTask(String id, {required int minutes,
      EventOrigin origin = EventOrigin.user}) async {
    if (minutes < 1) {
      throw ArgumentError.value(minutes, 'minutes', 'snooze 必须 ≥ 1 分钟');
    }
    final updated = _require(id)
        .copyWith(snoozedUntil: now().add(Duration(minutes: minutes)),
            status: TaskStatus.snoozed);
    await _persist(updated, origin, DomainEventType.taskSnoozed);
    return updated;
  }

  /// 绝对档位推迟（ui 文档 §7.2：明早 9 点 / 自选时间）。
  /// 送达时刻原样响，不经 NotificationWindowRule 顺延（决议 26）。
  Future<Task> snoozeUntil(String id, {required DateTime until,
      EventOrigin origin = EventOrigin.user}) async {
    final updated = _require(id)
        .copyWith(snoozedUntil: until, status: TaskStatus.snoozed);
    await _persist(updated, origin, DomainEventType.taskSnoozed);
    return updated;
  }

  /// D8 的显式选项：推迟到下一个工作窗开始（跳过午休/夜间/周末）。
  Future<Task> snoozeToNextWindow(String id,
      {EventOrigin origin = EventOrigin.user}) async {
    final updated = _require(id).copyWith(
        snoozedUntil: workRule.nextWindowStart(now()),
        status: TaskStatus.snoozed);
    await _persist(updated, origin, DomainEventType.taskSnoozed);
    return updated;
  }

  /// 记录实际投入的工时：remainingWork 减小 → slack 增大 → 提醒自动变疏。
  Future<Task> logWork(String id, {required int minutes,
      EventOrigin origin = EventOrigin.user}) async {
    final cur = _require(id);
    final remaining = (cur.remainingWork - minutes).clamp(0, cur.estimatedWork);
    // 干完即完成（flex 的剩余工时归零）：同样要落完成时刻，否则人类文档里
    // 只打勾、没有「完成 <时刻>」，与 completeTask 走出来的是两种形状。
    final done = remaining <= 0;
    final updated = cur.copyWith(
      remainingWork: remaining,
      status: done ? TaskStatus.completed : TaskStatus.active,
      completedAt: done ? (cur.completedAt ?? now()) : cur.completedAt,
      clearSnooze: true, // 用户重新动手了，取消静默
    );
    await _persist(updated, origin, DomainEventType.workLogged);
    return updated;
  }

  Future<Task> updateTask(
    String id, {
    String? title,
    DateTime? deadline,
    bool clearDeadline = false,
    int? estimatedWorkMinutes,
    int? importance,
    String? description,
    TaskType? type,
    EventOrigin origin = EventOrigin.user,
  }) async {
    final cur = _require(id);
    if (cur.type == TaskType.routine) {
      // 决议 23：例行实例是临时的，只提供"完成/跳过今天/编辑规则/删除规则"。
      throw ArgumentError('周期实例不能在实例上编辑（改节奏请编辑规则）');
    }
    if (type == TaskType.routine) {
      throw ArgumentError('任务不能转成周期实例');
    }
    var updated = cur;
    if (title != null) updated = updated.copyWith(title: title);
    if (clearDeadline) {
      // 散件没有截止；fixed 清截止是非法操作（在类型合并后校验）。
      updated = updated.copyWith(clearDeadline: true);
      updated = _clearPointFired(updated);
    } else if (deadline != null) {
      updated = updated.copyWith(deadline: deadline);
      updated = _clearPointFired(updated); // 改期 → 时点提醒重新生效
    }
    if (estimatedWorkMinutes != null) {
      // A2：fixed 允许 0，flex 必须 ≥ 1（按更新后的类型裁决）。
      final newType = type ?? cur.type;
      if (estimatedWorkMinutes < (newType == TaskType.fixed ? 0 : 1)) {
        throw ArgumentError.value(estimatedWorkMinutes, 'estimatedWorkMinutes',
            'estimatedWork 非法');
      }
      // A1：预估缩减时，剩余工时同步收敛到新预估内。
      updated = updated.copyWith(
        estimatedWork: estimatedWorkMinutes,
        remainingWork:
            cur.remainingWork.clamp(0, estimatedWorkMinutes).toInt(),
      );
    }
    if (importance != null) {
      updated = updated.copyWith(importance: importance.clamp(1, 5));
    }
    if (description != null) {
      updated = updated.copyWith(description: description);
    }
    if (type != null) {
      // 类型转换（散件转正 / 可推↔不可推）：metadata 缓冲带写 `type` 键。
      updated = _withMeta(updated, (m) {
        if (type == TaskType.fixed) return {...m, 'type': 'fixed'};
        return Map<String, String>.from(m)..remove('type');
      });
      if (type == TaskType.flex && cur.type == TaskType.fixed) {
        // fixed→flex：flex 必须 ≥1 工时（A2），且不能带着 0 剩余出生即完成。
        final est = updated.estimatedWork < 1 ? 30 : updated.estimatedWork;
        updated = updated.copyWith(
          estimatedWork: est,
          remainingWork: max(updated.remainingWork, est),
        );
      }
    }
    // 合并后校验：fixed 必须有截止；flex 无截止合法（散件）。
    if (updated.type == TaskType.fixed && updated.deadline == null) {
      throw ArgumentError('固定时点任务必须有截止时刻');
    }
    await _persist(updated, origin, DomainEventType.taskUpdated);
    return updated;
  }

  /// 删除 = 软删除（D11）：内核属性文件移入 `.gtd/.trash/`、人类文档那一行注释掉，
  /// Obsidian 可见可捞；撤销走 [restoreTask]。
  Future<void> deleteTask(String id,
      {EventOrigin origin = EventOrigin.user}) async {
    _require(id);
    await repo.moveToTrash(id);
    _tasks = _tasks.where((t) => t.id != id).toList();
    _emit(DomainEventType.taskDeleted, id, origin);
    await refreshSchedule(origin: origin);
  }

  /// 从回收站恢复（撤销窗口 / 设置页回收列表）。
  Future<void> restoreTask(String id,
      {EventOrigin origin = EventOrigin.user}) async {
    await repo.restore(id);
    await refreshSchedule(origin: origin);
    _emit(DomainEventType.taskRestored, id, origin);
  }

  /// 清空回收站（真删，仅设置页显式触发）。
  Future<void> purgeTrash({EventOrigin origin = EventOrigin.user}) async {
    await repo.purgeTrash();
    _emit(DomainEventType.trashPurged, '', origin);
  }

  /// 回收站清单（查询，不经缓存）。
  Future<List<Task>> loadTrash() => repo.loadTrash();

  /// **逐任务提醒开关**（v1.9 决议 38）：在标准模式下让**这一件**出声（metadata
  /// `remind`）。它**不改顺序**、不改其他字段；完整模式下开了也等于没开（本来就全响）。
  /// 不可推（fixed）与周期实例也适用——时点性提醒走同一道门槛（D15）。
  Future<Task> setTaskReminder(String id,
      {required bool enabled, EventOrigin origin = EventOrigin.user}) async {
    final updated = _withMeta(_require(id), (m) {
      final next = Map<String, String>.from(m);
      if (enabled) {
        next['remind'] = 'true';
      } else {
        next.remove('remind');
      }
      return next;
    });
    await _persist(updated, origin, DomainEventType.taskReminderSet);
    return updated;
  }

  /// 插队（决议 9）：持久意图记在任务上，保持到完成；栈式压顶（后插在上）。
  /// 仅对可推任务生效（决议 11）。
  Future<Task> pinToTop(String id,
      {EventOrigin origin = EventOrigin.user}) async {
    final cur = _require(id);
    if (cur.type != TaskType.flex) {
      throw ArgumentError('插队仅对可推任务生效');
    }
    final updated = _withMeta(
        cur, (m) => {...m, 'pinned': now().toIso8601String()});
    await _persist(updated, origin, DomainEventType.taskPinned);
    return updated;
  }

  /// 挑到今日（决议 8/13）：不转正，附今日尾部；当日手动挑标记生效。
  Future<Task> pickForToday(String id,
      {EventOrigin origin = EventOrigin.user}) async {
    final d = now();
    final mark =
        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    final updated =
        _withMeta(_require(id), (m) => {...m, 'picked_for_today': mark});
    await _persist(updated, origin, DomainEventType.taskPicked);
    return updated;
  }

  /// 放回池子（决议 25）：清除被挑标记，"今天不想做"的语义。
  Future<Task> returnToPool(String id,
      {EventOrigin origin = EventOrigin.user}) async {
    final updated = _withMeta(
        _require(id), (m) => Map<String, String>.from(m)..remove('picked_for_today'));
    await _persist(updated, origin, DomainEventType.taskUpdated);
    return updated;
  }

  /// 池子显示序（决议 14）：仅整理无调度含义，重启保留。
  Future<Task> setPoolOrder(String id, {required int order,
      EventOrigin origin = EventOrigin.user}) async {
    final updated =
        _withMeta(_require(id), (m) => {...m, 'pool_order': '$order'});
    await _persist(updated, origin, DomainEventType.taskUpdated);
    return updated;
  }

  /// 池子显示序的**整段重编号**（决议 14）：一次拖动手势会打乱整段，所以按
  /// [orderedIds] 的顺序一次性写 0..n-1。
  ///
  /// **必须批量**：逐条调 [setPoolOrder] 会放大成 N 次读盘，更糟的是每写一条就
  /// 重锚一次、发一次事件——第 k 条写完时只有前 k 个序号是新的，那个半成品顺序
  /// 会被立刻渲染出来，清单就在几个位置之间来回跳，最后才停（"闪动"的真因）。
  /// 这里照 [setManualOrder] 的形状：批量落盘 → 整体换 `_tasks` → 一个事件 →
  /// 一次重锚。
  Future<List<Task>> setPoolOrders(List<String> orderedIds,
      {EventOrigin origin = EventOrigin.user}) async {
    final updated = <Task>[];
    for (var i = 0; i < orderedIds.length; i++) {
      final cur = byId(orderedIds[i]);
      if (cur == null) continue;
      updated.add(_withMeta(cur, (m) => {...m, 'pool_order': '$i'}));
    }
    return _persistBatch(updated, DomainEventType.poolOrderChanged, origin);
  }

  /// 插队栈的**整段重写**（决议 9：后插在上，保持到完成）：按 [orderedIds] 的
  /// 顺序决定谁压在最上面，只针对可推任务（决议 11）。
  ///
  /// 时刻按目标顺序**递减 1 毫秒**：一次手势里逐条写会让它们落在同一毫秒上，
  /// 而插队件按 `pinned` 字符串排序——并列时 `sort` 没有稳定依据，落位变成随机
  /// （表现为"闪完之后停在别处"）。批量落盘的理由同 [setPoolOrders]。
  Future<List<Task>> setPinnedStack(List<String> orderedIds,
      {EventOrigin origin = EventOrigin.user}) async {
    final base = now();
    final updated = <Task>[];
    for (var i = 0; i < orderedIds.length; i++) {
      final cur = byId(orderedIds[i]);
      if (cur == null || cur.type != TaskType.flex) continue;
      updated.add(_withMeta(cur, (m) => {
            ...m,
            'pinned': base.subtract(Duration(milliseconds: i)).toIso8601String(),
          }));
    }
    return _persistBatch(updated, DomainEventType.taskPinned, origin);
  }

  /// 手动序（v1.12，决议 43 / D17）：按 [orderedIds] 的顺序整段重编号（从 0 连续），
  /// 只在无排序模式下参与排序；自动模式下这些序号原样保留、只是不生效。
  ///
  /// 一次拖动手势会重编整段，所以这里**批量落盘后再重锚一次**（不像 [setPoolOrder]
  /// 那样每写一条就重锚一次——那会放大成 N 次读盘）。
  Future<List<Task>> setManualOrder(List<String> orderedIds,
      {EventOrigin origin = EventOrigin.user}) async {
    final updated = <Task>[];
    for (var i = 0; i < orderedIds.length; i++) {
      final cur = byId(orderedIds[i]);
      if (cur == null) continue;
      updated.add(_withMeta(cur, (m) => {...m, 'manual_order': '$i'}));
    }
    return _persistBatch(updated, DomainEventType.manualOrderChanged, origin);
  }

  // ---------- 周期任务的实例（决议 5/12/23）----------

  /// 当天实例的确定性 id（幂等生成的前提）：`<规则id>-<yyyy-MM-dd>`。
  static String routineInstanceId(String routineId, String dayMark) =>
      '$routineId-$dayMark';

  /// 生成某规则在 [day] 的当天实例（幂等：已存在则原样返回）。
  /// 实例不占工时（estimatedWork = 0，A2 由 routine 类型豁免），
  /// 不进 ScheduleResult 排序（SlackScheduler 过滤非 flex）。
  Future<Task> createRoutineInstance(
    Routine routine,
    DateTime day, {
    EventOrigin origin = EventOrigin.system,
  }) async {
    final mark = _dayMark(day);
    final id = routineInstanceId(routine.id, mark);
    final existing = byId(id);
    if (existing != null) return existing;

    final task = Task(
      id: id,
      title: routine.title,
      description: routine.description,
      deadline: routine.occurrenceAt(day),
      estimatedWork: 0,
      remainingWork: 0,
      created: now(),
      metadata: Map.unmodifiable({
        'type': 'routine',
        'routine': routine.id,
        'routine_date': mark,
        if (routine.remind) 'routine_remind': 'true',
      }),
    );
    await repo.save(task);
    _tasks = [..._tasks, task];
    _emit(DomainEventType.routineInstanceGenerated, task.id, origin);
    await refreshSchedule(origin: origin);
    return task;
  }

  /// 规则改动后同步今日实例（决议 23：改规则即改实例；不提供"编辑实例"）。
  /// - 规则停用 / 今天不发生 → 未完成的今日实例移入回收站；
  /// - 今天发生 → 有则刷新标题/备注/时刻，无则生成。
  Future<void> syncRoutineForDay(
    Routine routine,
    DateTime day, {
    EventOrigin origin = EventOrigin.system,
  }) async {
    final mark = _dayMark(day);
    final id = routineInstanceId(routine.id, mark);
    final existing = byId(id);
    if (!routine.enabled || !routine.occursOn(day)) {
      if (existing != null && !existing.isCompleted) {
        await deleteTask(id, origin: origin);
      }
      return;
    }
    if (existing == null) {
      await createRoutineInstance(routine, day, origin: origin);
      return;
    }
    if (existing.isCompleted) return; // 完成即消，次日再生（决议 5）
    final deadline = routine.occurrenceAt(day);
    final meta = Map<String, String>.from(existing.metadata);
    if (routine.remind) {
      meta['routine_remind'] = 'true';
    } else {
      meta.remove('routine_remind');
    }
    // 内容没变就不落盘：文件 watch（主引擎/悬浮引擎/Obsidian 三方都在看）会
    // 因为无谓的写入互相触发，形成"写 → 事件 → 同步 → 再写"的回环。
    final unchanged = existing.title == routine.title &&
        existing.description == routine.description &&
        existing.deadline == deadline &&
        existing.routineRemind == routine.remind;
    if (unchanged) return;
    final updated = existing.copyWith(
      title: routine.title,
      description: routine.description,
      deadline: deadline,
      clearDeadline: deadline == null,
      metadata: Map.unmodifiable(meta),
    );
    await _persist(updated, origin, DomainEventType.routineUpdated);
  }

  /// 规则删除：连带清掉它未完成的今日实例（已完成的历史保留）。
  Future<void> removeRoutineInstances(String routineId,
      {EventOrigin origin = EventOrigin.system}) async {
    final mine = _tasks
        .where((t) =>
            t.type == TaskType.routine &&
            t.routineId == routineId &&
            !t.isCompleted)
        .map((t) => t.id)
        .toList();
    for (final id in mine) {
      await deleteTask(id, origin: origin);
    }
  }

  /// "跳过今天"（决议 23）：不完成、今日不再显示，次日再生。
  Future<Task> skipRoutineToday(String id,
      {EventOrigin origin = EventOrigin.user}) async {
    final cur = _require(id);
    if (cur.type != TaskType.routine) {
      throw ArgumentError('只有周期实例可以"跳过今天"');
    }
    final mark = cur.routineDate ?? _dayMark(now());
    final updated =
        _withMeta(cur, (m) => {...m, 'routine_skipped': mark});
    await _persist(updated, origin, DomainEventType.routineSkipped);
    return updated;
  }

  // ---------- 提醒轮询 ----------

  /// 时点性提醒候选（决议 3/18）：不可推到点 + 设了响的周期实例。
  /// 已响过（point_fired 与当前时刻一致）与超过补响宽限的不再返回。
  /// **v1.9：再过一道提醒门槛**（D15）——标准模式下只有被显式要求提醒的才出声。
  PointReminder? nextPointReminder() {
    final current = now();
    PointReminder? best;
    for (final t in _tasks) {
      if (t.isCompleted) continue;
      // 提醒门槛（v1.9，D15）：标准模式下只有被显式要求提醒的任务才出声。
      if (!reminderAllowed(t, reminderMode)) continue;
      final at = t.pointReminderAt;
      if (at == null) continue;
      if (t.pointFiredMark == at.toIso8601String()) continue; // 只到点响一次
      if (at.isBefore(current.subtract(pointReminderGrace))) continue; // 错过
      if (best == null || at.isBefore(best.at)) {
        best = PointReminder(taskId: t.id, at: at);
      }
    }
    return best;
  }

  /// 由 UI/定时器周期调用：时点性提醒优先，其次 Slack 软提醒。
  /// 到点则产出 ReminderEvent 并重锚；未到点返回 null。
  /// 绝对不要在这里无条件 refreshSchedule（C2）。
  ///
  /// 两种提醒都已过**门槛**（D15）：时点提醒在 [nextPointReminder] 里过滤，
  /// 软提醒取 `ScheduleResult.nextReminderAt`（那是"会响的下一站"，标准模式下通常为 null）。
  Future<ReminderEvent?> pollReminder() async {
    final current = now();
    final point = nextPointReminder();
    if (point != null && !point.at.isAfter(current)) {
      final task = byId(point.taskId);
      final before = lastSchedule;
      if (task == null || before == null) return null;
      // 记为已响（持久）：只到点响一次；改期/推迟会清掉这个标记。
      await _persist(
        _withMeta(task, (m) => {...m, 'point_fired': point.at.toIso8601String()}),
        EventOrigin.system,
        DomainEventType.taskUpdated,
      );
      return ReminderEvent(
        firedAt: current,
        taskId: task.id,
        kind: ReminderKind.point,
        schedule: before,
      );
    }

    final s = lastSchedule;
    if (s == null || s.nextReminderAt == null) return null;
    if (current.isBefore(s.nextReminderAt!)) return null;
    final taskId = s.nextReminderTaskId ?? s.nextTaskId;
    if (taskId == null) return null;
    await refreshSchedule(origin: EventOrigin.system);
    return ReminderEvent(
      firedAt: current,
      taskId: taskId,
      kind: ReminderKind.soft,
      schedule: s,
    );
  }

  // ---------- 内部 ----------

  /// metadata 缓冲带写助手：不可变任务 → 带 [patch] 后的 metadata 新实例。
  static Task _withMeta(
      Task t, Map<String, String> Function(Map<String, String>) patch) {
    final next = patch(Map<String, String>.from(t.metadata));
    return t.copyWith(metadata: Map.unmodifiable(next));
  }

  /// 改期后清掉"已响"标记（时点提醒重新生效）。
  static Task _clearPointFired(Task t) {
    if (!t.metadata.containsKey('point_fired')) return t;
    return _withMeta(t, (m) => Map<String, String>.from(m)..remove('point_fired'));
  }

  static String _dayMark(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}'
      '-${d.day.toString().padLeft(2, '0')}';

  /// **批量落盘**：一次用户手势（拖动定序/整理池子/插队）只许写一次盘、发一个
  /// 事件、重锚一次。逐条写会让"只写了一半的顺序"被渲染出来——清单闪动就是这么
  /// 来的；内存 `_tasks` 先整体换成终态再发事件，所以第一次重建就是最终顺序。
  Future<List<Task>> _persistBatch(List<Task> updated, DomainEventType type,
      EventOrigin origin) async {
    if (updated.isEmpty) return const [];
    final byIdMap = {for (final t in updated) t.id: t};
    for (final t in updated) {
      await repo.save(t);
    }
    _tasks = [for (final x in _tasks) byIdMap[x.id] ?? x];
    _emit(type, updated.first.id, origin);
    await refreshSchedule(origin: origin);
    return List.unmodifiable(updated);
  }

  Future<void> _persist(Task t, EventOrigin origin, DomainEventType type) async {
    await repo.save(t);
    _tasks = [for (final x in _tasks) x.id == t.id ? t : x];
    _emit(type, t.id, origin);
    await refreshSchedule(origin: origin);
  }

  void _emit(DomainEventType type, String taskId, EventOrigin origin) {
    if (_events.isClosed) return;
    _events.add(DomainEvent(type: type, taskId: taskId, at: now(), origin: origin));
  }

  Task _require(String id) {
    final t = byId(id);
    if (t == null) throw StateError('任务不存在: $id');
    return t;
  }
}

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

part 'task_service/task_service_trash.dart';
part 'task_service/task_service_routine.dart';
part 'task_service/task_service_ordering.dart';

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

  /// 落盘失败记录（v1.16：命令先发事件、后落盘）。空 = 正常；非空 = "界面上这个
  /// 状态重启后会丢"，条目形如 `<taskId>: <错误>`。供设置页/日志查，不参与逻辑。
  List<String> get persistFailures => List.unmodifiable(_persistFailures);

  final List<String> _persistFailures = [];

  List<Task> get tasks => List.unmodifiable(_tasks);

  Task? byId(String id) {
    for (final t in _tasks) {
      if (t.id == id) return t;
    }
    return null;
  }

  /// 重新读取仓库并重新调度（重锚提醒间隔）。**从盘回流**用这一条。
  ///
  /// C2 防 Zeno：只应在事件发生时调用（命令 / 提醒到点 / 文件变更），
  /// 不要在周期 tick 里无条件调用，否则提醒永远到不了点。
  ///
  /// 内部命令**不走这里**（改走 [recomputeSchedule]）：顺序刚在内存里落定，
  /// 再全量回读一遍目录只会把"让 UI 看到新顺序"推迟到 I/O 之后。
  Future<void> refreshSchedule({EventOrigin origin = EventOrigin.system}) async {
    await _reload();
    await recomputeSchedule(origin: origin);
  }

  /// 用**当前内存态**重算调度并发事件（不读盘）。
  ///
  /// 命令的最后一环走这里（v1.16）：`_tasks` 已经是终态，重算一遍调度即可，
  /// 没有理由再 `loadAll` 一遍——那会让界面看到的顺序变成"写进盘再读回来"的
  /// 那一份，而这份要等 N 次文件写 + 一次全量读才到得了手（拖动闪动的真因）。
  /// 只有外部改动（Obsidian 手改 / 文件监听 / 回到前台 / 启动）才需要真的回读。
  ///
  /// **锚点表**（v1.25，C2 的另一半）：命令重算不再把别人的提醒往后推——
  /// 上次算出的锚点按任务存着，任务自身没变就作为入参交给算法沿用。
  Future<void> recomputeSchedule(
      {EventOrigin origin = EventOrigin.system}) async {
    lastSchedule = scheduler.schedule(
      tasks: _tasks,
      now: now(),
      workRule: workRule,
      reminderMode: scheduleMode.reminderMode,
      anchors: _carriableAnchors(),
    );
    _rememberAnchors();
    _emit(DomainEventType.scheduleReanchored, lastSchedule?.nextTaskId ?? '',
        origin);
  }

  /// 锚点表：`taskId → 上次算出的提醒锚点`。
  ///
  /// 调度结果是计算的，不落盘；但"已经定下的闹钟"要跨重锚活下来。没有它，
  /// 每条命令都用 `now + interval` 重算，等于把每件任务的提醒都往后推一格——
  /// 用户越勤快地完成小事、拖顺序，最该响的那件越响不起来。
  final Map<String, DateTime> _anchors = {};

  /// 与 [_anchors] 同寿命的输入指纹表（见 [_anchorFingerprint]）。
  final Map<String, String> _anchorInputs = {};

  /// 每件任务上次锚定时的**输入指纹**：只有这些字段变了才允许重算锚点。
  ///
  /// 只收三样：改期、推迟/恢复、完成。干活（remaining 变小）、改标题、
  /// 开关提醒都不重置锚点——那是进度与元数据，不是"换了个约定"。
  static String _anchorFingerprint(Task t) =>
      '${t.deadline?.toIso8601String()}|'
      '${t.status.name}|'
      '${t.snoozedUntil?.toIso8601String()}';

  Map<String, DateTime> _carriableAnchors() {
    final out = <String, DateTime>{};
    for (final t in _tasks) {
      final at = _anchors[t.id];
      if (at == null) continue;
      if (_anchorInputs[t.id] != _anchorFingerprint(t)) continue;
      out[t.id] = at;
    }
    return out;
  }

  /// 把本次结果的锚点写回表里（连同当时的输入指纹）；没有锚点的清掉
  /// （完成 / 逾期 / 推迟到未来，都会让锚点自然消失）。
  void _rememberAnchors() {
    final s = lastSchedule;
    if (s == null) return;
    final byIdMap = {for (final t in _tasks) t.id: t};
    final kept = <String>{};
    for (final m in s.items) {
      final at = m.nextReminderAt;
      if (at == null) continue;
      final t = byIdMap[m.taskId];
      if (t == null) continue;
      _anchors[m.taskId] = at;
      _anchorInputs[m.taskId] = _anchorFingerprint(t);
      kept.add(m.taskId);
    }
    _anchors.removeWhere((id, _) => !kept.contains(id));
    _anchorInputs.removeWhere((id, _) => !kept.contains(id));
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
    await recomputeSchedule();
  }

  Future<void> _reload() async {
    final loaded = await repo.loadAll();
    final current = now();
    final result = <Task>[];
    for (final t in loaded) {
      // A4：snooze 到期自动回到 active。`snoozedUntil` 缺失的 snoozed 也算过期
      // （状态机不允许它出现，但手改 metadata 造得出来，不能让它永久卡住）。
      if (t.status == TaskStatus.snoozed &&
          (t.snoozedUntil == null || !t.snoozedUntil!.isAfter(current))) {
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
  /// - [type] = flex（默认）：[deadline] 可选（null = 三无散件）——
  ///   **无截止（三无）缺省工作强度 = '长期'**（v1.17，D18：豁免 A2/A3，
  ///   内核属性文档只有 id 一行），**有截止缺省 30 分钟且必须 ≥ 1**（A2）。
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
    // flex 分支按截止拆开（v1.17，D18）：无截止（三无）→ 缺省'长期'（null）；
    // 有截止 → 缺省 30 分钟。fixed → 0（豁免 A2）。显式传值优先。
    int? est;
    if (estimatedWorkMinutes != null) {
      est = estimatedWorkMinutes;
    } else if (type == TaskType.fixed) {
      est = 0;
    } else if (deadline != null) {
      est = 30;
    } else {
      est = null; // '长期'：估不出来就不写（D18）
    }
    // A2：fixed 豁免（0 合法）、flex 必须 ≥ 1；'长期'没有分钟数可校验（豁免）。
    if (est != null && est < (type == TaskType.fixed ? 0 : 1)) {
      throw ArgumentError.value(
          estimatedWorkMinutes, 'estimatedWorkMinutes', 'estimatedWork 非法');
    }
    // A3：'长期'不设优先级（豁免，D18）；其余缺省 3、clamp 1–5。
    final imp = est == null ? null : importance.clamp(1, 5);
    final task = Task(
      // 时间戳 + 随机尾巴：同一毫秒内连续创建也不会撞 id。
      id: 'task-${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}'
          '-${Random().nextInt(0x10000).toRadixString(36).padLeft(4, '0')}',
      title: title,
      deadline: deadline,
      estimatedWork: est,
      importance: imp,
      description: description,
      created: now(),
      metadata: type == TaskType.fixed
          ? const {'type': 'fixed'}
          : const {},
    );
    _tasks = [..._tasks, task];
    _emit(DomainEventType.taskCreated, task.id, origin);
    await _saveAll([task]);
    await recomputeSchedule(origin: origin);
    return task;
  }

  /// 完成。**完成时刻在此刻落下**（ui 文档 §6.1 / 附录 B）：人类文档那一行补
  /// `完成 <日期,时间>` 并打勾，内核属性文档同步落 `completed_at`——两者都由
  /// [Task.completedAt] 这一个字段驱动（[TaskDocumentCodec.encodeLine] 与
  /// [TaskSidecarCodec] 各取它渲染）。
  ///
  /// 同时清掉**挂起进行标记**（v1.18，ui 决议 47）：挂起保持到完成或主动取消——
  /// 完成即消，今日页最顶的挂起组里不再出现它。
  ///
  /// 人在 Obsidian 里已经手写了完成时刻的，保留人的那个值（§4.3 归属表：
  /// 完成日期属人写的那半边）。
  Future<Task> completeTask(String id,
      {EventOrigin origin = EventOrigin.user}) async {
    final cur = _require(id);
    final updated = _clearInProgress(cur.copyWith(
      status: TaskStatus.completed,
      // '长期'任务没有剩余工作量（D18）：completedAt/status 照落，
      // 但 remainingWork 保持缺位——内核属性文档只有 id，完成态只认人类文档。
      remainingWork: cur.isLongTerm ? null : 0,
      completedAt: cur.completedAt ?? now(),
      clearSnooze: true,
    ));
    await _persist(updated, origin, DomainEventType.taskCompleted);
    return updated;
  }

  /// 恢复未完成（撤销一次完成，ui 文档 §6.7『已完成』页）：已完成任务的兜底动作。
  ///
  /// - **例行实例不能恢复**：实例是临时的，恢复一个往日实例它会从所有清单里
  ///   消失（今日清单只收当天实例，池子不收实例）——要续节奏去编辑规则；
  /// - status 回 active、清 `completedAt`：人类文档那行由 codec 从 `completedAt`
  ///   驱动天然复原（`- [x] … 完成 <时刻>` → `- [ ]`），内核属性文档的
  ///   `completed_at` 同步移除，不写行逻辑；
  /// - `remainingWork` 回满到 `estimatedWork`（完成时被归零/干完）；'长期'任务
  ///   没有预估可回，保持缺位（D18）；
  /// - 没完成的任务调它是无操作（幂等，也防误触把已记的工时冲掉）。
  Future<Task> reopenTask(String id,
      {EventOrigin origin = EventOrigin.user}) async {
    final cur = _require(id);
    if (cur.type == TaskType.routine) {
      throw ArgumentError('周期实例不能恢复（实例是临时的；要续节奏请编辑规则）');
    }
    if (!cur.isCompleted) return cur;
    final updated = cur.copyWith(
      status: TaskStatus.active,
      clearCompletedAt: true,
      remainingWork: cur.isLongTerm ? null : cur.estimatedWork,
    );
    await _persist(updated, origin, DomainEventType.taskReopened);
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
  /// **'长期'任务不记工时**（v1.17，D18）：没有预估可对账——要跟踪投入，
  /// 先在编辑里把它换成具体工时（转正）。
  Future<Task> logWork(String id, {required int minutes,
      EventOrigin origin = EventOrigin.user}) async {
    final cur = _require(id);
    if (cur.isLongTerm) {
      throw ArgumentError('长期任务不记工时（没有预估可对账）；'
          '要跟踪投入，请先在编辑里换成具体工时');
    }
    final remaining = (cur.remainingWork! - minutes).clamp(0, cur.estimatedWork!);
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
    bool clearWork = false,
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
      // **清截止不自动改写工作强度**（v1.17，D18）：'长期' ↔ 数字工时都在
      // 编辑里显式设，不悄悄改语义（§3.4 防线三）。
      updated = updated.copyWith(clearDeadline: true);
      updated = _clearPointFired(updated);
    } else if (deadline != null) {
      updated = updated.copyWith(deadline: deadline);
      updated = _clearPointFired(updated); // 改期 → 时点提醒重新生效
    }
    if (clearWork) {
      // 显式设为'长期'（v1.17，D18）：三项一起清空——估不出来 → 没有工时、
      // 没有剩余、没有优先级（A1/A2/A3 全部豁免）。与 estimatedWorkMinutes
      // 互斥（同时传以 clearWork 为准）。
      updated = updated.copyWith(clearWork: true);
    } else if (estimatedWorkMinutes != null) {
      // A2：fixed 允许 0，flex 必须 ≥ 1（按更新后的类型裁决）；
      // **'长期'豁免**（v1.17，D18）——它本来就没有分钟数。
      final newType = type ?? cur.type;
      if (estimatedWorkMinutes < (newType == TaskType.fixed ? 0 : 1)) {
        throw ArgumentError.value(estimatedWorkMinutes, 'estimatedWorkMinutes',
            'estimatedWork 非法');
      }
      if (cur.isLongTerm) {
        // '长期' → 数字工时（'转正'的另一半，ui §6.3）：补剩余工作量与
        // 优先级缺省 3（A3）——否则带截止的 flex 会拖着空值进调度公式。
        updated = updated.copyWith(
          estimatedWork: estimatedWorkMinutes,
          remainingWork: estimatedWorkMinutes,
          importance: importance?.clamp(1, 5) ?? 3,
        );
      } else {
        // A1：预估缩减时，剩余工时同步收敛到新预估内。
        updated = updated.copyWith(
          estimatedWork: estimatedWorkMinutes,
          remainingWork: (cur.remainingWork ?? estimatedWorkMinutes)
              .clamp(0, estimatedWorkMinutes)
              .toInt(),
        );
      }
    }
    if (importance != null && !updated.isLongTerm) {
      // A3：1–5、缺省 3；'长期'任务不设优先级（豁免，D18）——此时忽略
      // importance 参数（要设优先级先给数字工时）。
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
        // （'长期'豁免 A2，但"从 fixed 带着 0 工时转来"仍按老规矩补 30——
        //  那一转通常还带着截止，空值进公式正是'长期'要避免的。）
        final curEst = updated.estimatedWork;
        final est = (curEst == null || curEst < 1) ? 30 : curEst;
        updated = updated.copyWith(
          estimatedWork: est,
          remainingWork: max(updated.remainingWork ?? est, est),
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

  /// **挂起进行**（v1.18，ui 决议 47 / D19）：长期任务的"正在做"标记——今日页
  /// 最顶的挂起组顶置呈现（见 `buildTodayView` 的 `inProgress` 组）。持久意图
  /// 记在任务上（metadata `in_progress`，值 = 挂起时刻），**保持到完成或主动
  /// 取消、不按天过期**（`completeTask` 顺手清除）。仅'长期'任务可挂（有截止的
  /// 事归调度管）；**取消不受此限**——'转正'后已挂的仍占挂起位，也要能取消。
  Future<Task> setInProgress(String id,
      {required bool enabled, EventOrigin origin = EventOrigin.user}) async {
    final cur = _require(id);
    if (enabled && !cur.isLongTerm) {
      throw ArgumentError('仅长期任务可挂起进行（有截止的事归调度管）');
    }
    final updated = _withMeta(cur, (m) {
      final next = Map<String, String>.from(m);
      if (enabled) {
        next['in_progress'] = now().toIso8601String();
      } else {
        next.remove('in_progress');
      }
      return next;
    });
    await _persist(updated, origin, DomainEventType.taskInProgressSet);
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

  // ---------- 周期任务的实例（决议 5/12/23）----------

  /// 当天实例的确定性 id（幂等生成的前提）：`<规则id>-<yyyy-MM-dd>`。
  ///
  /// static 必须留在类体内（extension 承载不了 static）；实例侧的生成/同步/
  /// 清理/跳过在 `task_service/task_service_routine.dart` 的 extension 上。
  static String routineInstanceId(String routineId, String dayMark) =>
      '$routineId-$dayMark';

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

  /// 有没有"snooze 已到期、但状态还挂着 snoozed"的任务（A4 的定时触点）。
  ///
  /// `_reload` 里写回 active，而 `_reload` 只由 `refreshSchedule` 调；
  /// 标准档下 `lastSchedule.nextReminderAt` 恒为 null，`pollReminder` 会提前
  /// return，永远走不到那条路——被推迟的件就卡在 snoozed 里：不进清单、
  /// 不参与排序、也不再提醒。轮询是唯一不依赖"别的事件"的发现方式。
  bool get hasExpiredSnooze {
    final current = now();
    for (final t in _tasks) {
      if (t.status != TaskStatus.snoozed) continue;
      final until = t.snoozedUntil;
      if (until == null || !until.isAfter(current)) return true;
    }
    return false;
  }

  /// 由 UI/定时器周期调用：时点性提醒优先，其次 Slack 软提醒。
  /// 到点则产出 ReminderEvent 并重锚；未到点返回 null。
  /// 绝对不要在这里无条件 refreshSchedule（C2）。
  ///
  /// 两种提醒都已过**门槛**（D15）：时点提醒在 [nextPointReminder] 里过滤，
  /// 软提醒取 `ScheduleResult.nextReminderAt`（那是"会响的下一站"，标准模式下通常为 null）。
  Future<ReminderEvent?> pollReminder() async {
    // A4 先跑：到期的 snooze 要写回 active 并重锚，否则它既不在清单里、
    // 也不在"下一站"里，没有任何东西会把它叫醒。
    if (hasExpiredSnooze) {
      await refreshSchedule(origin: EventOrigin.system);
    }
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
    // 响过之后这件任务的锚点作废：重算要给出"下一轮"，不能沿用刚响的那个。
    // 与上面的"到期 snooze"一样，两条重锚都走读盘——到点是时间驱动的，
    // `_reload` 顺带把到期的 snooze 拉回 active（A4），内存态不知道时间过去了。
    _anchors.remove(taskId);
    _anchorInputs.remove(taskId);
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

  /// 完成时清掉挂起标记（"持久到完成"，v1.18 决议 47）：键不在就原样返回。
  static Task _clearInProgress(Task t) {
    if (!t.metadata.containsKey('in_progress')) return t;
    return _withMeta(t, (m) => Map<String, String>.from(m)..remove('in_progress'));
  }

  static String _dayMark(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}'
      '-${d.day.toString().padLeft(2, '0')}';

  /// **批量落盘**：一次用户手势（拖动定序/整理池子/插队）只许发一个事件、重算一次。
  ///
  /// 顺序很关键（v1.16）：**先把内存 `_tasks` 换成终态并发事件，再去落盘**。
  /// 事件是 UI 刷新的唯一触发器，放在落盘之后就等于让"界面看到新顺序"等
  /// N 次文件写——那几帧里列表还是旧顺序，条目先弹回原位再跳到新位置（闪动）。
  Future<List<Task>> _persistBatch(List<Task> updated, DomainEventType type,
      EventOrigin origin) async {
    if (updated.isEmpty) return const [];
    final byIdMap = {for (final t in updated) t.id: t};
    _tasks = [for (final x in _tasks) byIdMap[x.id] ?? x];
    _emit(type, updated.first.id, origin);
    await _saveAll(updated);
    await recomputeSchedule(origin: origin);
    return List.unmodifiable(updated);
  }

  Future<void> _persist(Task t, EventOrigin origin, DomainEventType type) async {
    _tasks = [for (final x in _tasks) x.id == t.id ? t : x];
    _emit(type, t.id, origin);
    await _saveAll([t]);
    await recomputeSchedule(origin: origin);
  }

  /// 落盘：失败**只记不抛**——内存态已经是界面看到的终态，抛出去只会让命令
  /// 半途而废、UI 停在更不一致的地方。写不进去的任务留在 [persistFailures]
  /// 里，供设置页/日志查（下次任意一次从盘回流会把它冲掉）。
  Future<void> _saveAll(List<Task> tasks) async {
    for (final t in tasks) {
      try {
        await repo.save(t);
      } catch (e) {
        _persistFailures.add('${t.id}: $e');
      }
    }
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

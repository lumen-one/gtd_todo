import '../domain/schedule.dart';
import '../domain/task.dart';
import '../domain/time_context.dart';
import 'scheduler.dart';

/// **时间裕度优先**（v1.9 起的默认算法，决议 39 / D16）：裕度的非线性风险 × 重要度。
///
/// 对每个未完成任务计算：
///
/// ```text
/// available = WorkTime(now, deadline)              # 跳过休息时间的真实可用工时
/// slack     = available - remainingWork            # 裕度，唯一的压力表
/// risk      = slack ≤ 0 ? 1 : exp(−(slack/τ)^γ)    # 非线性误期风险 ∈ (0,1]
/// priority  = risk × importance                    # 调度优先级 = 排序键（缺省 3）
/// interval  = reminderInterval(α·slack, 拐点 pivot) # 提醒节奏（两段：线性 + 对数）
/// nextReminderAt = 沿用旧锚点 ?? addWorkMinutes(now, interval)
/// ```
///
/// 与旧 [SlackScheduler] 的差别只有**排序键**（priority 降序 vs urgency 降序）；
/// 风险函数、间隔公式、锚点沿用、过滤条件（fixed / 散件 / 周期实例不进调度）、
/// 派生状态（infeasible / overdue / snoozed）、四档排序全部一致。
///
/// **提醒门槛（D15）**：`reminderAllowed(task, reminderMode)` 不成立时这一件不出声
/// （`reminds = false`、`ScheduleResult.nextReminderAt` 不会取到它）；
/// 但**锚点照算**——"今天该看哪几件"是调度问题，不该被提醒模式改掉（今日清单准入用它）。
class SlackPriorityScheduler implements Scheduler {
  static const String defaultId = 'slack-priority.v1';

  final SlackPriorityConfig config;

  const SlackPriorityScheduler({this.config = const SlackPriorityConfig()});

  @override
  String get id => defaultId;

  @override
  String get displayName => '时间裕度优先';

  @override
  List<ParamSpec> get params => [
        ParamSpec(
          key: 'alpha',
          label: '提醒激进度 α',
          hint: '每轮提醒消耗剩余裕度的比例，越大催得越紧',
          min: 0.1,
          max: 0.9,
          defaultValue: config.alpha,
        ),
        ParamSpec(
          key: 'minIntervalMinutes',
          label: '最小间隔（分钟）',
          hint: '低于此时长的提醒没有行动价值',
          min: 5,
          max: 120,
          defaultValue: config.minIntervalMinutes,
        ),
        ParamSpec(
          key: 'maxIntervalMinutes',
          label: '间隔拐点（分钟）',
          hint: '裕度换算出的间隔撞到它就改按对数放缓：超过后每翻一倍裕度加一个拐点',
          min: 30,
          max: 1440,
          defaultValue: config.maxIntervalMinutes,
        ),
        ParamSpec(
          key: 'riskScaleMinutes',
          label: '风险尺度 τ（工作分钟）',
          hint: '多宽算"宽"：多出 τ 分钟的裕度，风险压到 1/e（默认 1 个工作日）',
          min: 60,
          max: 2880,
          defaultValue: config.riskScaleMinutes,
        ),
        ParamSpec(
          key: 'riskGamma',
          label: '风险陡度 γ',
          hint: '1 = 纯指数；>1 = 裕度充足时压得更低（更平），薄了迅速冲到 1（更陡）',
          min: 0.5,
          max: 3,
          defaultValue: config.riskGamma,
        ),
      ];

  @override
  ScheduleResult schedule({
    required List<Task> tasks,
    required DateTime now,
    required WorkTimeRule workRule,
    ReminderMode reminderMode = ReminderMode.standard,
    Map<String, DateTime> anchors = const {},
  }) {
    final metrics = <TaskMetric>[];
    final infeasible = <String>[];
    final overdue = <String>[];
    final sortable = <_TaskView>[];

    for (final task in tasks) {
      if (task.isCompleted) continue;
      // ui-interaction.md §10 #2/#3：只有可推（flex）进调度。
      // fixed 不进调度（走 AlarmPort 时点闹钟）；周期实例不占工时、默认不响
      // （决议 5/12）；无截止 flex（散件）不参与 overdue/infeasible 派生、永不提醒。
      if (task.type != TaskType.flex) continue;
      // '长期'不进这套公式（v1.17，D18）：它本来就没有截止（三无缺省），
      // 把它塞进公式只会逼出一个假装精确的 risk——那正是'长期'要避免的。
      // 这里同时是防线：编辑 API 允许"补截止但不换工时"，那一瞬的
      // flex + 截止 + '长期' 也不该参与派生（转正会连截止带工时一起补）。
      if (task.isLongTerm) continue;
      final deadline = task.deadline;
      if (deadline == null) continue;

      // '长期'已在上面跳过（D18）：走到这里的必有数字剩余工作量。
      final remaining = task.remainingWork!;
      final isOverdue = deadline.isBefore(now) && remaining > 0;
      final available =
          isOverdue ? 0 : workRule.workMinutesBetween(now, deadline);
      final slack = available - remaining;

      final snoozedIntoFuture = task.status == TaskStatus.snoozed &&
          task.snoozedUntil != null &&
          task.snoozedUntil!.isAfter(now);

      TaskDisplayStatus display;
      if (isOverdue) {
        display = TaskDisplayStatus.overdue;
        overdue.add(task.id);
      } else if (remaining > 0 && available < remaining) {
        // 按期已不可行：必须升级（改截止 / 砍范围 / 加班预算），不能静静等待。
        display = TaskDisplayStatus.infeasible;
        infeasible.add(task.id);
      } else if (snoozedIntoFuture) {
        display = TaskDisplayStatus.snoozed;
      } else {
        display = TaskDisplayStatus.normal;
      }

      // urgency：available 为 0 时用 1 作分母兜底（结果必然 >1，进入 infeasible）。
      // v1.9 起只作展示（排序键换成了 priority）。
      final urgency =
          remaining <= 0 ? 0.0 : remaining / (available == 0 ? 1 : available);

      // 风险是非线性的（D16）：裕度还宽时压得很低，一薄就陡然爬起来。
      final risk = slackRisk(
        slack,
        scaleMinutes: config.riskScaleMinutes,
        gamma: config.riskGamma,
      );
      // importance 对'长期'为 null，但长期任务已在上面跳过（D18）——走到这里的
      // 必有数字工时，?? 3 只是 A3 缺省值的兜底（不改变任何非长期任务的行为）。
      final priority = risk * (task.importance ?? 3);

      DateTime? nextReminderAt;
      int? interval;
      final schedulable = !isOverdue && !snoozedIntoFuture;
      if (schedulable) {
        interval = reminderInterval(
          slack,
          alpha: config.alpha,
          minIntervalMinutes: config.minIntervalMinutes,
          pivotMinutes: config.maxIntervalMinutes,
        );
        nextReminderAt = carriedAnchor(anchors[task.id], now) ??
            workRule.addWorkMinutes(now, interval);
      }

      final metric = TaskMetric(
        taskId: task.id,
        displayStatus: display,
        availableMinutes: available,
        slackMinutes: slack,
        risk: risk,
        priority: priority,
        urgency: urgency,
        nextReminderAt: nextReminderAt,
        // 门槛（D15）：锚点照算，但只有"允许出声"的任务才会真的响。
        reminds: schedulable && reminderAllowed(task, reminderMode),
        intervalMinutes: interval,
      );
      metrics.add(metric);
      if (!snoozedIntoFuture) {
        sortable.add(_TaskView(task, metric));
      }
    }

    // 排序四档（v1.25）：不可行单独一档——它是"已经注定误期"，必须排在
    // "还来得及"的前面等用户裁决；同档内按**调度优先级**降序
    // （deadline 升序、id 升序裁决）。importance 已经是 priority 里的乘数。
    sortable.sort((a, b) {
      final byStatus = _rank(a.metric.displayStatus)
          .compareTo(_rank(b.metric.displayStatus));
      if (byStatus != 0) return byStatus;
      final byPriority = b.metric.priority.compareTo(a.metric.priority);
      if (byPriority != 0) return byPriority;
      final byDeadline = a.task.deadline!.compareTo(b.task.deadline!);
      if (byDeadline != 0) return byDeadline;
      return a.task.id.compareTo(b.task.id);
    });

    final ordered = sortable.map((v) => v.metric).toList();
    // 已 snooze 的排到列表尾部展示。
    for (final m in metrics) {
      if (m.displayStatus == TaskDisplayStatus.snoozed &&
          !ordered.contains(m)) {
        ordered.add(m);
      }
    }

    // 下一站 = **会响**的提醒里最早的那个（锚点 ∩ 门槛）；标准模式下通常没有。
    DateTime? nextReminderAt;
    String? nextReminderTaskId;
    for (final m in ordered) {
      final at = m.reminderAt;
      if (at != null &&
          (nextReminderAt == null || at.isBefore(nextReminderAt))) {
        nextReminderAt = at;
        nextReminderTaskId = m.taskId;
      }
    }

    return ScheduleResult(
      computedAt: now,
      items: ordered,
      nextTaskId: ordered.isEmpty ? null : ordered.first.taskId,
      nextReminderAt: nextReminderAt,
      nextReminderTaskId: nextReminderTaskId,
      infeasibleTaskIds: infeasible,
      overdueTaskIds: overdue,
    );
  }

  static int _rank(TaskDisplayStatus s) => switch (s) {
        TaskDisplayStatus.infeasible => 0,
        TaskDisplayStatus.normal => 1,
        TaskDisplayStatus.overdue => 2,
        TaskDisplayStatus.snoozed => 3,
      };
}

/// 时间裕度优先算法的可调参数（不要硬编码在算法内部）。
class SlackPriorityConfig {
  /// 每次提醒消耗剩余裕度的比例。0.5 = 每轮提醒吃掉一半 slack。
  final double alpha;

  /// 最小提醒间隔（工作分钟）：低于这个时长的提醒没有行动价值。
  final int minIntervalMinutes;

  /// 最大提醒间隔（工作分钟）：`α·slack` 撞到它之前线性缩短，撞到之后按
  /// 对数放缓（每翻一倍裕度加一个拐点）。它不是硬顶——硬顶会让"裕度 3 天"
  /// 和"裕度 3 个月"的任务拿到同一个间隔，等于给每件远期任务挂每日固定提醒。
  final int maxIntervalMinutes;

  /// 风险尺度 τ（工作分钟）：多出 τ 分钟的裕度，风险压到 1/e。
  final double riskScaleMinutes;

  /// 风险陡度 γ：1 = 纯指数；>1 = 裕度充足时压得更低（更平）、薄了迅速冲到 1（更陡）。
  final double riskGamma;

  const SlackPriorityConfig({
    this.alpha = 0.5,
    this.minIntervalMinutes = 30,
    this.maxIntervalMinutes = 480,
    this.riskScaleMinutes = defaultRiskScaleMinutes,
    this.riskGamma = defaultRiskGamma,
  });
}

class _TaskView {
  final Task task;
  final TaskMetric metric;
  const _TaskView(this.task, this.metric);
}

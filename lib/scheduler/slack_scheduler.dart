import '../domain/schedule.dart';
import '../domain/task.dart';
import '../domain/time_context.dart';
import 'scheduler.dart';

/// 第一版调度算法（**v1.9 起不再默认**）：基于 Slack（裕度）的动态提醒间隔。
///
/// 默认算法已换成 [SlackPriorityScheduler]（时间裕度优先，`priority = risk × importance`）；
/// 本算法留在注册表里做**对照与影子运行**，排序口径仍是 `urgency` 降序。
///
/// 对每个未完成任务计算：
///   available = WorkTime(now, deadline)   —— 跳过休息时间的真实可用工时
///   slack     = available - remainingWork
///   urgency   = remainingWork / available
///   interval  = reminderInterval(α·slack, 拐点 pivot)  （slack <= 0 时取 min）
///   nextReminderAt = min(沿用旧锚点 ?? addWorkMinutes(now, interval), deadline)
///
/// 多任务排序：urgency 高者优先（文档 §11），importance 作并列裁决。
/// 派生状态：infeasible（urgency > 1，按期已不可行）需要升级处理，
/// overdue（已过截止）退出提醒循环，只做展示。
/// **提醒门槛**（v1.9 补上，D15）与默认算法同一套：标准模式下只有被显式要求提醒的
/// 任务才会出声——换算法不能绕过模式，否则"默认安静"就有了后门。
class SlackScheduler implements Scheduler {
  static const String defaultId = 'slack.v1';

  final SlackSchedulerConfig config;

  const SlackScheduler({this.config = const SlackSchedulerConfig()});

  @override
  String get id => defaultId;

  @override
  String get displayName => '裕度几何递减';

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
      ];

  @override
  ScheduleResult schedule({
    required List<Task> tasks,
    required DateTime now,
    required WorkTimeRule workRule,
    Map<String, DateTime> anchors = const {},
    bool weightImportance = true,
  }) {
    final metrics = <TaskMetric>[];
    final infeasible = <String>[];
    final overdue = <String>[];
    final sortable = <_TaskView>[];

    for (final task in tasks) {
      if (task.isCompleted) continue;
      // ui-interaction.md §10 #2/#3：只有截止型（flex）进调度。
      // fixed 不进调度（走 AlarmPort 时点闹钟）；周期实例不占工时、默认不响
      // （决议 5/12）；无截止 flex（散件）不参与 overdue/infeasible 派生、永不提醒。
      if (task.type != TaskType.flex) continue;
      // '长期'不进这套公式（v1.17，D18）：与默认算法同一口径（见
      // [SlackPriorityScheduler]）——估不出来就不算，不逼假装精确的 risk。
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
      final urgency =
          remaining <= 0 ? 0.0 : remaining / (available == 0 ? 1 : available);

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
        // 夹到截止（与 SlackPriorityScheduler 同一口径，见 anchorWithinDeadline）。
        nextReminderAt = anchorWithinDeadline(
          carriedAnchor(anchors[task.id], now) ??
              workRule.addWorkMinutes(now, interval),
          deadline,
        );
      }

      final metric = TaskMetric(
        taskId: task.id,
        displayStatus: display,
        availableMinutes: available,
        slackMinutes: slack,
        // 风险/调度优先级与默认算法同一套公式（TaskMetric 是统一方言），
        // 只是本算法的**排序**仍按 urgency——这才是两个算法的差别所在。
        risk: slackRisk(slack),
        // '长期'任务已在上面跳过（D18），?? 3 只是 A3 缺省值的兜底。
        priority: slackRisk(slack) *
            (weightImportance ? (task.importance ?? 3) : 1),
        urgency: urgency,
        nextReminderAt: nextReminderAt,
        intervalMinutes: interval,
      );
      metrics.add(metric);
      if (!snoozedIntoFuture) {
        sortable.add(_TaskView(task, metric));
      }
    }

    // 排序四档（v1.25，与默认算法同一份口径）：不可行单独一档，
    // 同档内按 urgency 降序，importance 降序、deadline 升序做并列裁决
    // （『问重要度』关掉时 importance 一级整个跳过）。
    sortable.sort((a, b) {
      final byStatus = _rank(a.metric.displayStatus)
          .compareTo(_rank(b.metric.displayStatus));
      if (byStatus != 0) return byStatus;
      final byUrgency = b.metric.urgency.compareTo(a.metric.urgency);
      if (byUrgency != 0) return byUrgency;
      if (weightImportance) {
        final byImportance =
            (b.task.importance ?? 3).compareTo(a.task.importance ?? 3);
        if (byImportance != 0) return byImportance;
      }
      return a.task.deadline!.compareTo(b.task.deadline!);
    });

    final ordered = sortable.map((v) => v.metric).toList();
    // 已 snooze 的排到列表尾部展示。
    for (final m in metrics) {
      if (m.displayStatus == TaskDisplayStatus.snoozed &&
          !ordered.contains(m)) {
        ordered.add(m);
      }
    }

    // 下一站 = 各任务锚点里最早的那个。
    DateTime? nextReminderAt;
    String? nextReminderTaskId;
    for (final m in ordered) {
      final at = m.nextReminderAt;
      if (at != null &&
          (nextReminderAt == null || at.isBefore(nextReminderAt))) {
        nextReminderAt = at;
        nextReminderTaskId = m.taskId;
      }
    }

    // 建议先做的那件必须"没被推迟"（v1.26）：全都 snoozed 时不给建议。
    String? nextTaskId;
    for (final m in ordered) {
      if (m.displayStatus == TaskDisplayStatus.snoozed) continue;
      nextTaskId = m.taskId;
      break;
    }

    return ScheduleResult(
      computedAt: now,
      items: ordered,
      nextTaskId: nextTaskId,
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

class _TaskView {
  final Task task;
  final TaskMetric metric;
  const _TaskView(this.task, this.metric);
}

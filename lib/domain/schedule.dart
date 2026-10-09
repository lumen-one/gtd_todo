/// 调度结果的数据类型（Scheduler 的输出，Application/UI 的输入）。
/// 纯数据，不包含任何 IO。
class TaskMetric {
  final String taskId;
  final TaskDisplayStatus displayStatus;

  /// 截止前剩余可工作分钟数。
  final int availableMinutes;

  /// slack = available - remaining，可为负。
  final int slackMinutes;

  /// urgency = remaining / available。>1 表示按期已不可行。
  final double urgency;

  /// 下一次提醒时刻（墙钟）。逾期任务为 null（提醒已无意义）。
  final DateTime? nextReminderAt;

  /// 本次锚定的提醒间隔（工作分钟）。
  final int? intervalMinutes;

  const TaskMetric({
    required this.taskId,
    required this.displayStatus,
    required this.availableMinutes,
    required this.slackMinutes,
    required this.urgency,
    this.nextReminderAt,
    this.intervalMinutes,
  });
}

/// 展示/排序用的派生状态。注意 overdue 是派生事实，不要求写入存储。
enum TaskDisplayStatus { normal, infeasible, overdue, snoozed }

class ScheduleResult {
  final DateTime computedAt;

  /// 已按优先级排序：不可行 > 普通（urgency 高在前）> 逾期 > 已推迟。
  final List<TaskMetric> items;

  /// 当前最值得做的任务。
  final String? nextTaskId;

  /// 全局下一次提醒时刻（最早的各任务 nextReminderAt）。
  final DateTime? nextReminderAt;
  final String? nextReminderTaskId;

  final List<String> infeasibleTaskIds;
  final List<String> overdueTaskIds;

  const ScheduleResult({
    required this.computedAt,
    required this.items,
    this.nextTaskId,
    this.nextReminderAt,
    this.nextReminderTaskId,
    this.infeasibleTaskIds = const [],
    this.overdueTaskIds = const [],
  });

  TaskMetric? metricOf(String taskId) {
    for (final m in items) {
      if (m.taskId == taskId) return m;
    }
    return null;
  }
}

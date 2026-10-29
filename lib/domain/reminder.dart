import 'schedule.dart';

/// 提醒类别（ui-interaction.md §7.1）：
/// - [soft]  Slack 软提醒：截止型任务按裕度调频，走普通通知，**永不**全屏闹钟；
/// - [point] 时点性提醒：开始型到点 + 设了响的周期实例，只到点响一次，
///   可选闹钟模式（全屏 + 持续响铃，决议 18），不受静默段限制。
enum ReminderKind { soft, point }

/// 提醒事件：到点后由 Application 层产出，交给任意通知实现
/// （系统通知 / UI 弹窗 / 控制台 / CLI）。Scheduler 只产出
/// ScheduleResult，永远不直接发送通知。
class ReminderEvent {
  final DateTime firedAt;

  /// 本次提醒的目标（正典：消费方不再从 schedule 里猜）。任务 = `task.id`；
  /// 编排条目 = [plan.dart](plan.dart) 里的站点 id（`plan|2026-10-29|870`），
  /// 它不对应任何任务，查不到是正常的。
  final String taskId;

  final ReminderKind kind;

  /// 触发这一次的调度结果快照（重锚之前的那份）；重锚本身由
  /// TaskService.pollReminder 内部完成。
  ///
  /// **编排条目没有调度结果**（它不进调度），那一源给的提醒事件这里为 null——
  /// 消费方只认 [taskId] 与 [kind]，不必为它编一份空快照。
  final ScheduleResult? schedule;

  const ReminderEvent({
    required this.firedAt,
    required this.taskId,
    this.schedule,
    this.kind = ReminderKind.soft,
  });
}

/// 时点性提醒候选（TaskService 派生，§4.3 单闹钟协调者的第二个输入）：
/// 到点时刻 + 目标任务。逾期太久（超过 [pointReminderGrace]）的不再补响。
class PointReminder {
  final String taskId;
  final DateTime at;

  const PointReminder({required this.taskId, required this.at});
}

/// 时点提醒的补响宽限：到点后 [pointReminderGrace] 内仍会响（应用当时没运行、
/// 系统闹钟被吞等场景），超过则视为错过，不再打扰。
const Duration pointReminderGrace = Duration(minutes: 30);

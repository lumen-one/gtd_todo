import '../domain/schedule.dart';
import '../domain/task.dart';
import '../domain/time_context.dart';
import 'scheduler.dart';

/// 影子运行（§4.1 配套机制）：主算法出正式结果，影子算法只算不答，
/// 差异记入 [diffLog]。用于新算法上线前的对比观察与调参评估。
/// 影子算法抛异常不影响主结果。
class ShadowScheduler implements Scheduler {
  final Scheduler primary;
  final Scheduler shadow;
  final void Function(String diff)? onDiff;
  final List<String> diffLog = [];

  ShadowScheduler({required this.primary, required this.shadow, this.onDiff});

  @override
  String get id => primary.id;

  @override
  String get displayName => primary.displayName;

  @override
  List<ParamSpec> get params => primary.params;

  @override
  ScheduleResult schedule({
    required List<Task> tasks,
    required DateTime now,
    required WorkTimeRule workRule,
    ReminderMode reminderMode = ReminderMode.standard,
    SortMode sortMode = SortMode.auto,
  }) {
    // 门槛与排序口径都原样透传给两边：影子对比的是"算法差异"，
    // 不是"模式差异"（D17：两边同口径才比得出 priority 的差异）。
    final result = primary.schedule(
        tasks: tasks,
        now: now,
        workRule: workRule,
        reminderMode: reminderMode,
        sortMode: sortMode);
    try {
      final ghost = shadow.schedule(
          tasks: tasks,
          now: now,
          workRule: workRule,
          reminderMode: reminderMode,
          sortMode: sortMode);
      final diff = _describeDiff(result, ghost);
      if (diff != null) {
        diffLog.add('${now.toIso8601String()}: $diff');
        onDiff?.call(diff);
      }
    } catch (_) {
      // 影子失败不影响主结果
    }
    return result;
  }

  String? _describeDiff(ScheduleResult a, ScheduleResult b) {
    if (a.nextTaskId != b.nextTaskId) {
      return 'nextTask: ${a.nextTaskId} vs ${b.nextTaskId}';
    }
    for (final ma in a.items) {
      final mb = b.metricOf(ma.taskId);
      if (mb == null) return 'task ${ma.taskId} 在影子结果中缺失';
      if (ma.intervalMinutes != mb.intervalMinutes) {
        return 'task ${ma.taskId} 间隔 ${ma.intervalMinutes} vs ${mb.intervalMinutes}';
      }
      // 排序口径（v1.9：调度优先级）也在观察范围内——换了排序键要看得见。
      if ((ma.priority - mb.priority).abs() > 1e-9) {
        return 'task ${ma.taskId} 调度优先级 '
            '${ma.priority.toStringAsFixed(4)} vs ${mb.priority.toStringAsFixed(4)}';
      }
    }
    return null;
  }
}

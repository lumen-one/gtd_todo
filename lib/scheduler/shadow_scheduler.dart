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
  }) {
    final result = primary.schedule(tasks: tasks, now: now, workRule: workRule);
    try {
      final ghost =
          shadow.schedule(tasks: tasks, now: now, workRule: workRule);
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
    }
    return null;
  }
}

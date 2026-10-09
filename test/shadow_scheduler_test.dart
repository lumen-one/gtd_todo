import 'package:flutter_test/flutter_test.dart';
import 'package:gtd_todo/domain/schedule.dart';
import 'package:gtd_todo/domain/task.dart';
import 'package:gtd_todo/domain/time_context.dart';
import 'package:gtd_todo/scheduler/scheduler.dart';
import 'package:gtd_todo/scheduler/shadow_scheduler.dart';
import 'package:gtd_todo/scheduler/slack_scheduler.dart';

void main() {
  const rule = WorkTimeRule.standard;
  final now = DateTime(2026, 10, 7, 16, 0); // 周三 16:00

  Task task(String id, int remaining) => Task(
        id: id,
        title: id,
        deadline: DateTime(2026, 10, 7, 18, 0),
        estimatedWork: remaining,
        remainingWork: remaining,
        created: DateTime(2026, 10, 7, 15, 0),
      );

  test('影子运行：返回主算法结果，差异被记录', () {
    final primary = const SlackScheduler();
    final shadow = const SlackScheduler(
        config: SlackSchedulerConfig(alpha: 0.3, minIntervalMinutes: 10));
    final s = ShadowScheduler(primary: primary, shadow: shadow);

    final r = s.schedule(
      tasks: [task('a', 60)],
      now: now,
      workRule: rule,
    );

    // 主结果原样返回
    expect(identical(r, primary.schedule(tasks: [task('a', 60)], now: now, workRule: rule)),
        isFalse); // 重新计算的实例
    expect(r.nextTaskId, 'a');
    expect(r.metricOf('a')!.intervalMinutes, 30); // 主算法口径（α=0.5）
    expect(s.diffLog, isNotEmpty); // 影子口径不同 → 记录差异
  });

  test('影子一致时不记录差异', () {
    final s = ShadowScheduler(
      primary: const SlackScheduler(),
      shadow: const SlackScheduler(),
    );
    s.schedule(tasks: [task('a', 60)], now: now, workRule: rule);
    expect(s.diffLog, isEmpty);
  });

  test('影子算法抛异常不影响主结果', () {
    final s = ShadowScheduler(
      primary: const SlackScheduler(),
      shadow: _ExplodingScheduler(),
    );
    final r = s.schedule(tasks: [task('a', 60)], now: now, workRule: rule);
    expect(r.nextTaskId, 'a');
    expect(s.diffLog, isEmpty);
  });
}

class _ExplodingScheduler extends SlackScheduler {
  const _ExplodingScheduler();

  @override
  ScheduleResult schedule({
    required List<Task> tasks,
    required DateTime now,
    required WorkTimeRule workRule,
  }) {
    throw StateError('影子算法故障');
  }
}

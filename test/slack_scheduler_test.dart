import 'package:flutter_test/flutter_test.dart';
import 'package:qixing/domain/schedule.dart';
import 'package:qixing/domain/task.dart';
import 'package:qixing/domain/time_context.dart';
import 'package:qixing/scheduler/slack_scheduler.dart';

void main() {
  const rule = WorkTimeRule.standard;
  const scheduler = SlackScheduler();
  final now = DateTime(2026, 10, 7, 16, 0); // 周三 16:00

  Task task({
    required String id,
    required DateTime deadline,
    required int remaining,
    int estimated = 60,
    int importance = 3,
    TaskStatus status = TaskStatus.active,
    DateTime? snoozedUntil,
  }) {
    return Task(
      id: id,
      title: id,
      deadline: deadline,
      estimatedWork: estimated,
      remainingWork: remaining,
      importance: importance,
      status: status,
      snoozedUntil: snoozedUntil,
      created: DateTime(2026, 10, 7, 15, 0),
    );
  }

  test('单任务：interval = alpha * slack，nextReminder 落在工作窗内', () {
    // available = 16:00→18:00 = 120min，remaining 60 → slack 60 → interval 30
    // v1.9：要"会响"就得在完整模式下断言（默认标准模式只排列不提醒）。
    final r = scheduler.schedule(
      tasks: [
        task(id: 'a', deadline: DateTime(2026, 10, 7, 18, 0), remaining: 60),
      ],
      now: now,
      workRule: rule,
    );
    final m = r.metricOf('a')!;
    expect(m.slackMinutes, 60);
    expect(m.urgency, closeTo(0.5, 1e-9));
    expect(m.intervalMinutes, 30);
    expect(r.nextReminderAt, DateTime(2026, 10, 7, 16, 30));
    expect(r.nextTaskId, 'a');
  });

  test('裕度很大时 interval 越过拐点后按对数放缓（不再撞硬顶、也不退化成每日固定提醒）', () {
    // available ≈ 2370min，remaining 60 → alpha*slack = 1155 > 拐点 480
    final r = scheduler.schedule(
      tasks: [
        task(id: 'a', deadline: DateTime(2026, 10, 14, 18, 0), remaining: 60),
      ],
      now: now,
      workRule: rule,
    );
    final near = r.metricOf('a')!.intervalMinutes!;
    expect(near, greaterThan(480), reason: '越过拐点后仍然随裕度增长');

    // 裕度再大一个量级 → 间隔继续变长，而不是和上面同频
    final far = scheduler.schedule(
      tasks: [
        task(id: 'b', deadline: DateTime(2026, 11, 14, 18, 0), remaining: 60),
      ],
      now: now,
      workRule: rule,
    ).metricOf('b')!.intervalMinutes!;
    expect(far, greaterThan(near), reason: '硬顶会让两者同频 —— 远期任务天天响');

    // 兜底上限：16 个拐点
    expect(far, lessThanOrEqualTo(480 * 16));
  });

  test('多任务：urgency 高者优先；snooze 后其他任务自动顶上', () {
    final a = task(id: 'a', deadline: DateTime(2026, 10, 7, 18, 0), remaining: 80);
    final b = task(id: 'b', deadline: DateTime(2026, 10, 7, 18, 0), remaining: 30);

    var r = scheduler.schedule(tasks: [a, b], now: now, workRule: rule);
    expect(r.nextTaskId, 'a');

    // Task 不可变（§3.2 C1）：snooze = 用新实例替换旧实例
    final aSnoozed = Task(
      id: a.id,
      title: a.title,
      deadline: a.deadline,
      estimatedWork: a.estimatedWork,
      remainingWork: a.remainingWork,
      importance: a.importance,
      status: TaskStatus.snoozed,
      snoozedUntil: DateTime(2026, 10, 7, 17, 0), // 尚未到期
      created: a.created,
    );

    r = scheduler.schedule(tasks: [aSnoozed, b], now: now, workRule: rule);
    expect(r.nextTaskId, 'b');
    expect(r.metricOf('a')!.displayStatus, TaskDisplayStatus.snoozed);
  });

  test('snooze 到期后重新参与调度', () {
    final a = task(
      id: 'a',
      deadline: DateTime(2026, 10, 7, 18, 0),
      remaining: 80,
      status: TaskStatus.snoozed,
      snoozedUntil: DateTime(2026, 10, 7, 15, 30), // 已过期
    );
    final r = scheduler.schedule(tasks: [a], now: now, workRule: rule);
    expect(r.nextTaskId, 'a');
    expect(r.metricOf('a')!.displayStatus, TaskDisplayStatus.normal);
  });

  test('available < remaining → 标记不可行，用最小间隔催', () {
    // available = 16:00→17:30 = 90min，remaining 100 → 装不下
    final r = scheduler.schedule(
      tasks: [
        task(id: 'a', deadline: DateTime(2026, 10, 7, 17, 30), remaining: 100),
      ],
      now: now,
      workRule: rule,
    );
    final m = r.metricOf('a')!;
    expect(m.displayStatus, TaskDisplayStatus.infeasible);
    expect(r.infeasibleTaskIds, ['a']);
    expect(m.urgency, greaterThan(1));
    expect(m.intervalMinutes, 30);
    expect(r.nextTaskId, 'a');
  });

  test('已过截止 → overdue，退出提醒循环', () {
    final r = scheduler.schedule(
      tasks: [
        task(id: 'a', deadline: DateTime(2026, 10, 7, 15, 0), remaining: 30),
      ],
      now: now,
      workRule: rule,
    );
    final m = r.metricOf('a')!;
    expect(m.displayStatus, TaskDisplayStatus.overdue);
    expect(r.overdueTaskIds, ['a']);
    expect(m.nextReminderAt, isNull);
    expect(r.nextReminderAt, isNull);
  });

  test('换算法也一样不筛提醒：锚点即下一站', () {
    final tasks = [
      task(id: 'a', deadline: DateTime(2026, 10, 7, 18, 0), remaining: 60),
    ];

    final r = scheduler.schedule(tasks: tasks, now: now, workRule: rule);
    expect(r.metricOf('a')!.nextReminderAt, DateTime(2026, 10, 7, 16, 30));
    expect(r.nextReminderAt, DateTime(2026, 10, 7, 16, 30));
  });
}

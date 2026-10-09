import 'package:flutter_test/flutter_test.dart';
import 'package:gtd_todo/application/task_service.dart';
import 'package:gtd_todo/domain/event.dart';
import 'package:gtd_todo/domain/task.dart';
import 'package:gtd_todo/domain/time_context.dart';
import 'package:gtd_todo/repository/memory_task_repository.dart';
import 'package:gtd_todo/scheduler/slack_scheduler.dart';

void main() {
  late MemoryTaskRepository repo;
  late TaskService svc;
  var now = DateTime(2026, 10, 7, 16, 0); // 周三 16:00

  setUp(() {
    repo = MemoryTaskRepository();
    now = DateTime(2026, 10, 7, 16, 0);
    svc = TaskService(
      repo: repo,
      scheduler: const SlackScheduler(),
      workRule: WorkTimeRule.standard,
      clock: () => now,
    );
  });

  Future<Task> createA() => svc.createTask(
        title: '紧急任务A',
        deadline: DateTime(2026, 10, 7, 18, 0), // 2h 后
        estimatedWorkMinutes: 60,
      );

  Future<Task> createB() => svc.createTask(
        title: '宽松任务B',
        deadline: DateTime(2026, 10, 9, 18, 0), // 周五
        estimatedWorkMinutes: 60,
      );

  test('核心循环：创建 → 调度 → snooze → 其他任务顶上 → 完成', () async {
    final a = await createA();
    await createB();
    expect(svc.lastSchedule!.nextTaskId, a.id); // urgency 0.5 vs ~0.06

    await svc.snoozeTask(a.id, minutes: 60);
    expect(svc.lastSchedule!.nextTaskId, isNot(a.id));
    expect((await repo.getTask(a.id))!.snoozedUntil,
        DateTime(2026, 10, 7, 17, 0));

    await svc.completeTask(a.id);
    expect((await repo.getTask(a.id))!.status, TaskStatus.completed);
    expect(svc.lastSchedule!.items.any((m) => m.taskId == a.id), isFalse);
  });

  test('logWork：剩余减少、紧急度下降、间隔变长', () async {
    final a = await createA();
    final before = svc.lastSchedule!.metricOf(a.id)!;

    await svc.logWork(a.id, minutes: 30);
    final after = svc.lastSchedule!.metricOf(a.id)!;

    expect((await repo.getTask(a.id))!.remainingWork, 30);
    expect(after.urgency, lessThan(before.urgency));
    expect(after.intervalMinutes!, greaterThan(before.intervalMinutes!));
    expect(after.slackMinutes, greaterThan(before.slackMinutes));
  });

  test('A1：updateTask 缩减预估时，剩余工时收敛到新预估内', () async {
    final a = await createA(); // est 60, remaining 60
    await svc.updateTask(a.id, estimatedWorkMinutes: 30);
    final t = (await repo.getTask(a.id))!;
    expect(t.estimatedWork, 30);
    expect(t.remainingWork, 30); // 若无守护会是 60 > 30，破坏不变量
  });

  test('A2：estimatedWork = 0 被拒绝', () {
    expectLater(
      svc.createTask(
        title: '零工时任务',
        deadline: DateTime(2026, 10, 8, 18, 0),
        estimatedWorkMinutes: 0,
      ),
      throwsArgumentError,
    );
  });

  test('D8：短推 snooze 按"自然时间"而非工作分钟', () async {
    now = DateTime(2026, 10, 9, 17, 45); // 周五傍晚
    final a = await svc.createTask(
      title: 'A',
      deadline: DateTime(2026, 10, 14, 18, 0),
      estimatedWorkMinutes: 60,
    );
    await svc.snoozeTask(a.id, minutes: 30);
    // 自然时间 30 分钟 = 周五 18:15；若是工作分钟会被推到下周一 09:15
    expect((await repo.getTask(a.id))!.snoozedUntil,
        DateTime(2026, 10, 9, 18, 15));
  });

  test('D8：到下个工作窗 = 显式跳过午休/夜间/周末', () async {
    now = DateTime(2026, 10, 9, 17, 45); // 周五
    final a = await svc.createTask(
      title: 'A',
      deadline: DateTime(2026, 10, 14, 18, 0),
      estimatedWorkMinutes: 60,
    );
    await svc.snoozeToNextWindow(a.id);
    expect((await repo.getTask(a.id))!.snoozedUntil,
        DateTime(2026, 10, 12, 9, 0)); // 周一 09:00
  });

  test('领域事件：命令发事件、origin=user、含重锚事件', () async {
    final evts = <DomainEvent>[];
    final sub = svc.events.listen(evts.add);
    addTearDown(sub.cancel);

    final a = await createA();
    await svc.completeTask(a.id);

    expect(
        evts.map((e) => e.type),
        containsAll([
          DomainEventType.taskCreated,
          DomainEventType.taskCompleted,
          DomainEventType.scheduleReanchored,
        ]));
    expect(evts.every((e) => e.origin == EventOrigin.user), isTrue);
  });

  test('snooze 到期后自动回到 active', () async {
    final a = await createA();
    await svc.snoozeTask(a.id, minutes: 30); // 16:30
    expect((await repo.getTask(a.id))!.status, TaskStatus.snoozed);

    now = DateTime(2026, 10, 7, 16, 31);
    await svc.refreshSchedule();
    expect((await repo.getTask(a.id))!.status, TaskStatus.active);
    expect(svc.lastSchedule!.nextTaskId, a.id);
  });

  test('pollReminder：未到点不触发、不重锚；到点触发并重新锚定', () async {
    await createA();
    final first = svc.lastSchedule!;
    final anchor = first.nextReminderAt!; // 16:30

    expect(await svc.pollReminder(), isNull);
    expect(identical(svc.lastSchedule, first), isTrue);

    now = anchor;
    final event = await svc.pollReminder();
    expect(event, isNotNull);
    expect(event!.schedule.nextReminderAt, anchor);
    expect(svc.lastSchedule!.nextReminderAt!.isAfter(anchor), isTrue); // 17:00
    expect(svc.lastSchedule!.computedAt, anchor);
  });

  test('手工改 deadline 后重新调度', () async {
    final a = await createA();
    await svc.updateTask(a.id, deadline: DateTime(2026, 10, 7, 17, 0));
    final m = svc.lastSchedule!.metricOf(a.id)!;
    expect(m.urgency, closeTo(1.0, 1e-9));
    expect(m.intervalMinutes, 30);
  });
}

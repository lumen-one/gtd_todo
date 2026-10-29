import 'package:flutter_test/flutter_test.dart';
import 'package:gtd_todo/application/task_service.dart';
import 'package:gtd_todo/domain/event.dart';
import 'package:gtd_todo/domain/schedule.dart';
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
    await svc.updateScheduleMode(ScheduleMode.full); // 本用例断言"会响"
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

  // ---------- 提醒一律发出与逐任务响铃（v1.9 决议 38 改写：门槛已取消）----------

  group('提醒', () {
    test('A3：importance 缺省 3——它就是"优先级"，也是调度优先级的乘数', () async {
      final a = await createA();
      expect(a.importance, 3);
    });

    test('默认标准模式：顺序与下一站都照给（有时间的任务一律提醒）', () async {
      final a = await createA();
      expect(svc.lastSchedule!.nextTaskId, a.id);
      expect(svc.lastSchedule!.nextReminderAt, DateTime(2026, 10, 7, 16, 30));
      expect(svc.lastSchedule!.nextReminderTaskId, a.id);
      final m = svc.lastSchedule!.metricOf(a.id)!;
      expect(m.nextReminderAt, DateTime(2026, 10, 7, 16, 30));
    });

    test('setTaskReminder：只写/删 metadata，不改下一站', () async {
      final a = await createA();
      final types = <DomainEventType>[];
      final sub = svc.events.listen((e) => types.add(e.type));
      addTearDown(sub.cancel);

      await svc.setTaskReminder(a.id, enabled: true);
      expect(svc.byId(a.id)!.ringEnabled, isTrue);
      expect(svc.byId(a.id)!.metadata['remind'], 'true',
          reason: '持久意图落 metadata（附录 B.2 登记键）');
      expect((await repo.getTask(a.id))!.ringEnabled, isTrue,
          reason: '写盘再读回来仍然有效');
      expect(svc.lastSchedule!.nextReminderAt, DateTime(2026, 10, 7, 16, 30),
          reason: '响铃不参与调度，锚点一格都不动');
      expect(types, contains(DomainEventType.taskReminderSet));

      await svc.setTaskReminder(a.id, enabled: false);
      expect(svc.byId(a.id)!.ringEnabled, isFalse);
      expect(svc.byId(a.id)!.metadata.containsKey('remind'), isFalse);
      expect(svc.lastSchedule!.nextReminderAt, DateTime(2026, 10, 7, 16, 30),
          reason: '关掉响铃只是变静音，提醒照发');
    });

    test('时点提醒不看响铃：开始型到点就是候选（三档一样）', () async {
      final meeting = await svc.createTask(
        title: '例会',
        type: TaskType.fixed,
        deadline: DateTime(2026, 10, 7, 18, 0),
      );
      expect(svc.nextPointReminder()!.taskId, meeting.id,
          reason: '没有门槛，标准档也响');

      await svc.updateScheduleMode(ScheduleMode.full);
      expect(svc.nextPointReminder()!.taskId, meeting.id);
    });

    test('切模式：立即重算，一个字节的数据都不动', () async {
      final a = await createA();
      final before = await repo.getTask(a.id);

      await svc.updateScheduleMode(ScheduleMode.full);
      expect(svc.lastSchedule!.nextReminderAt, DateTime(2026, 10, 7, 16, 30));

      await svc.updateScheduleMode(ScheduleMode.standard);
      expect(svc.lastSchedule!.nextReminderAt, DateTime(2026, 10, 7, 16, 30),
          reason: '两档只有"问什么"不同，提醒节奏一样');

      final after = await repo.getTask(a.id);
      expect(after!.metadata, before!.metadata);
      expect(after.status, before.status);
      expect(after.remainingWork, before.remainingWork);
    });
  });
}

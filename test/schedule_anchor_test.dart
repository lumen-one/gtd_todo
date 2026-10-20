import 'package:flutter_test/flutter_test.dart';
import 'package:gtd_todo/application/task_service.dart';
import 'package:gtd_todo/domain/schedule.dart';
import 'package:gtd_todo/domain/task.dart';
import 'package:gtd_todo/repository/memory_task_repository.dart';
import 'package:gtd_todo/scheduler/slack_priority_scheduler.dart';

/// 锚点身份（v1.25，C2 的另一半）与提醒间隔的两段式。
///
/// 这两条都是"算法算对了但送不出去"那一类：命令重锚会把别人的提醒往后推，
/// 硬顶会让远期任务天天响。断言写在 TaskService 层（命令 → 重锚 → 锚点），
/// 因为缺陷本身不在这两个纯函数里。
void main() {
  late DateTime now;
  late TaskService svc;

  setUp(() {
    now = DateTime(2026, 10, 7, 9, 0); // 周三 9:00，工作窗 9–12 / 13:30–18
    svc = TaskService(
      repo: MemoryTaskRepository(),
      scheduler: const SlackPriorityScheduler(),
      clock: () => now,
      scheduleMode: ScheduleMode.full, // 断言"会响"，所以走完整档
    );
  });

  test('无关命令不再推后别人的锚点，到点照响', () async {
    final a = await svc.createTask(
      title: 'A 写报告',
      deadline: DateTime(2026, 10, 8, 18, 0),
      estimatedWorkMinutes: 300,
    );
    final anchor = svc.lastSchedule!.metricOf(a.id)!.nextReminderAt!;
    expect(anchor, DateTime(2026, 10, 7, 15, 30),
        reason: '裕度 600 → 间隔 300 工作分钟（180 到午休，再 120）');

    // 每隔 40 分钟"做完一件无关任务"——这是最容易复现的日常操作节奏
    for (var i = 0; i < 4; i++) {
      final filler = await svc.createTask(
        title: '填充 $i',
        deadline: DateTime(2026, 10, 9, 18, 0),
        estimatedWorkMinutes: 30,
      );
      now = now.add(const Duration(minutes: 40));
      await svc.completeTask(filler.id);
      expect(
        svc.lastSchedule!.metricOf(a.id)!.nextReminderAt,
        anchor,
        reason: '第 $i 次：别人的操作与它无关，锚点不该动',
      );
    }

    // 锚点没被推走 → 到点仍然响得起来
    now = anchor;
    final event = await svc.pollReminder();
    expect(event, isNotNull);
    expect(event!.taskId, a.id);
  });

  test('任务自己改期才重算锚点', () async {
    final a = await svc.createTask(
      title: 'A',
      deadline: DateTime(2026, 10, 7, 18, 0),
      estimatedWorkMinutes: 300,
    );
    final anchor = svc.lastSchedule!.metricOf(a.id)!.nextReminderAt!;

    now = now.add(const Duration(minutes: 30));
    await svc.updateTask(a.id, deadline: DateTime(2026, 10, 9, 18, 0));

    final moved = svc.lastSchedule!.metricOf(a.id)!.nextReminderAt!;
    expect(moved, isNot(anchor));
    expect(moved.isAfter(anchor), isTrue, reason: '改到两天后 → 锚点跟着走远');
  });

  test('旧锚点迟到超过 30 分钟 → 视为错过，按现在重算', () async {
    final a = await svc.createTask(
      title: 'A',
      deadline: DateTime(2026, 10, 7, 18, 0),
      estimatedWorkMinutes: 300,
    );
    final anchor = svc.lastSchedule!.metricOf(a.id)!.nextReminderAt!; // 10:15

    now = anchor.add(const Duration(minutes: 45)); // 11:00，应用刚醒
    await svc.recomputeSchedule();

    final moved = svc.lastSchedule!.metricOf(a.id)!.nextReminderAt!;
    expect(moved.isAfter(now), isTrue, reason: '不补一个过去的锚点');
    expect(moved, DateTime(2026, 10, 7, 11, 30));
  });

  test('锚点迟到在宽限内 → 沿用（立刻响，而不是被推下一轮）', () {
    final at = DateTime(2026, 10, 7, 10, 15);
    expect(carriedAnchor(at, at), at, reason: '刚好到点');
    expect(carriedAnchor(at, at.add(const Duration(minutes: 20))), at,
        reason: '迟到 20 分钟仍在宽限内');
    expect(carriedAnchor(at, at.add(const Duration(minutes: 31))), isNull,
        reason: '超过 30 分钟算错过');
    expect(carriedAnchor(null, at), isNull, reason: '没有旧锚点');
  });

  test('snooze 到期由轮询叫醒（标准档也一样）', () async {
    await svc.updateScheduleMode(ScheduleMode.standard); // 默认档，下一站恒为空
    final a = await svc.createTask(
      title: 'A',
      deadline: DateTime(2026, 10, 8, 18, 0),
      estimatedWorkMinutes: 60,
    );
    await svc.snoozeTask(a.id, minutes: 60);
    expect(svc.byId(a.id)!.status, TaskStatus.snoozed);

    now = now.add(const Duration(minutes: 61));
    expect(await svc.pollReminder(), isNull, reason: '标准档不出声');
    expect(svc.byId(a.id)!.status, TaskStatus.active,
        reason: '状态要回来：pollReminder 是第一发现人');
    expect(svc.lastSchedule!.metricOf(a.id), isNotNull, reason: '重新进入调度');
  });

  test('pollReminder 不可重入：两路同时打进来只发一条', () async {
    final a = await svc.createTask(
      title: 'A',
      deadline: DateTime(2026, 10, 8, 18, 0),
      estimatedWorkMinutes: 300,
    );
    final anchor = svc.lastSchedule!.metricOf(a.id)!.nextReminderAt!;
    now = anchor; // 到点

    // 20 秒 tick 与闹钟回调不共享锁：同一时刻进来两次
    final results = await Future.wait([svc.pollReminder(), svc.pollReminder()]);
    expect(results.where((e) => e != null).length, 1,
        reason: '少发一条好过同一件事弹两次');
  });

  group('reminderInterval：两段式', () {
    test('拐点前按裕度线性缩短，slack ≤ 0 取最小间隔', () {
      expect(reminderInterval(-120), 30);
      expect(reminderInterval(0), 30);
      expect(reminderInterval(60), 30);
      expect(reminderInterval(600), 300);
      expect(reminderInterval(960), 480, reason: '恰好撞上拐点仍是线性段');
    });

    test('越过拐点后对数放缓，且全程单调不减', () {
      expect(reminderInterval(1920), 960, reason: '裕度翻一倍 → 加一个拐点');
      expect(reminderInterval(3840), greaterThan(960));
      expect(reminderInterval(20000), lessThanOrEqualTo(480 * 16),
          reason: '保底上限：再远也不至于"再也不响"');

      var prev = 0;
      for (var slack = 0; slack <= 20000; slack += 50) {
        final v = reminderInterval(slack);
        expect(v, greaterThanOrEqualTo(prev), reason: 'slack=$slack 处回头了');
        prev = v;
      }
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:gtd_todo/application/settings.dart';
import 'package:gtd_todo/application/task_service.dart';
import 'package:gtd_todo/application/today_view.dart';
import 'package:gtd_todo/domain/routine.dart';
import 'package:gtd_todo/domain/schedule.dart';
import 'package:gtd_todo/domain/task.dart';
import 'package:gtd_todo/domain/time_context.dart';
import 'package:gtd_todo/repository/memory_task_repository.dart';
import 'package:gtd_todo/scheduler/slack_priority_scheduler.dart';

/// 调度模式三档（v1.12 决议 43 / D17）：完整 → 标准 → 无排序，**逐级弱化**。
///
/// 无排序 = 标准的再弱化版——只把"算法排先后"这一层去掉，**今日清单的成员不变**
/// （仍按"提醒锚点落在今天 / 今天到期"准入）。内核完全不知道排序模式：
/// `Scheduler.schedule` 只收 reminderMode，手动序是业务层的查询口径。
void main() {
  const rule = WorkTimeRule.standard;
  const scheduler = SlackPriorityScheduler();
  final now = DateTime(2026, 10, 7, 16, 0); // 周三 16:00（工作窗 13:30–18:00）

  Task task({
    required String id,
    required DateTime? deadline,
    int remaining = 60,
    int estimated = 60,
    int importance = 3,
    TaskType type = TaskType.flex,
    Map<String, String> metadata = const {},
    DateTime? created,
  }) =>
      Task(
        id: id,
        title: id,
        deadline: deadline,
        estimatedWork: estimated,
        remainingWork: remaining,
        importance: importance,
        metadata: {...metadata, if (type != TaskType.flex) 'type': type.name},
        created: created ?? DateTime(2026, 10, 7, 15, 0),
      );

  DateTime wed(int h, int m) => DateTime(2026, 10, 7, h, m);

  group('三档是一条弱化谱系：互拆到内核门槛', () {
    test('只有完整档放行；标准与无排序都是"只排列不提醒"', () {
      expect(ScheduleMode.full.reminderMode, ReminderMode.full);
      expect(ScheduleMode.standard.reminderMode, ReminderMode.standard);
      expect(ScheduleMode.manual.reminderMode, ReminderMode.standard,
          reason: '无排序是标准的再弱化，不是另开一个安静维度');
      expect(ScheduleMode.manual.isManual, isTrue);
      expect(ScheduleMode.standard.isManual, isFalse);
      expect(ScheduleMode.full.isManual, isFalse);
    });

    test('byName 认得三档，认不出的落到默认标准', () {
      expect(ScheduleMode.byName('full'), ScheduleMode.full);
      expect(ScheduleMode.byName('manual'), ScheduleMode.manual);
      expect(ScheduleMode.byName('nonsense'), ScheduleMode.standard);
      expect(ScheduleMode.byName(null), ScheduleMode.standard);
    });
  });

  group('今日清单：成员不变，只改顺序', () {
    test('无排序不会把远期任务塞进今天——成员与标准完全一致', () {
      final tasks = [
        task(id: 'today', deadline: wed(18, 0)),
        task(id: 'far', deadline: DateTime(2026, 10, 20, 18, 0)),
      ];
      final schedule = scheduler.schedule(
          tasks: tasks, now: now, workRule: rule, reminderMode: ReminderMode.full);

      final auto = buildTodayView(
          tasks: tasks, schedule: schedule, now: now,
          scheduleMode: ScheduleMode.standard);
      final manual = buildTodayView(
          tasks: tasks, schedule: schedule, now: now,
          scheduleMode: ScheduleMode.manual);

      expect(auto.flex.map((t) => t.id).toList(), ['today'],
          reason: '锚点落在今天 / 今天到期才进');
      expect(manual.flex.map((t) => t.id).toList(), ['today'],
          reason: '无排序只换顺序，不换成员——远期任务仍然不进今日');
    });

    test('顺序：标准是插队 + 调度序；无排序是手动序，没有插队层', () {
      final tasks = [
        task(id: 'a', deadline: wed(18, 0), importance: 1,
            metadata: const {'manual_order': '2'}),
        task(id: 'b', deadline: wed(17, 30), importance: 5,
            metadata: const {'manual_order': '0'}),
        task(id: 'c', deadline: wed(18, 0), importance: 3,
            metadata: const {'manual_order': '1'}),
        task(id: 'pin', deadline: wed(18, 0), metadata: const {
          'pinned': '2026-10-07T15:30:00.000',
          'manual_order': '3',
        }),
      ];
      final schedule = scheduler.schedule(
          tasks: tasks, now: now, workRule: rule, reminderMode: ReminderMode.full);

      final standard = buildTodayView(
          tasks: tasks, schedule: schedule, now: now,
          scheduleMode: ScheduleMode.standard);
      expect(standard.pinned.map((t) => t.id).toList(), ['pin'],
          reason: '插队件压顶（决议 9）');
      expect(standard.flex.first.id, 'b', reason: '其余按调度序：裕度薄的在前');

      final manual = buildTodayView(
          tasks: tasks, schedule: schedule, now: now,
          scheduleMode: ScheduleMode.manual);
      expect(manual.pinned, isEmpty,
          reason: '顺序本身就是人定的，不需要插队这个补丁');
      expect(manual.flex.map((t) => t.id).toList(), ['b', 'c', 'a', 'pin']);
    });

    test('没排过序的沉在末尾，按 id 升序（新任务从末尾开始）', () {
      final view = buildTodayView(
        tasks: [
          task(id: 'new-1', deadline: wed(18, 0)),
          task(id: 'old', deadline: wed(18, 0),
              metadata: const {'manual_order': '0'}),
          task(id: 'new-0', deadline: wed(18, 0)),
        ],
        schedule: null,
        now: now,
        scheduleMode: ScheduleMode.manual,
      );
      expect(view.flex.map((t) => t.id).toList(), ['old', 'new-0', 'new-1']);
    });

    test('四处不跟着变：逾期置顶 / 固定时点按时刻 / 例行按时点 / 被挑散件在最后', () {
      final tasks = [
        task(id: 'overdue', deadline: DateTime(2026, 10, 6, 18, 0)),
        task(id: 'fixed-late', deadline: wed(19, 0), type: TaskType.fixed),
        task(id: 'fixed-early', deadline: wed(17, 0), type: TaskType.fixed),
        task(id: 'routine', deadline: wed(20, 0), type: TaskType.routine,
            metadata: const {'routine_date': '2026-10-07'}),
        task(id: 'picked', deadline: null,
            metadata: const {'picked_for_today': '2026-10-07'}),
        task(id: 'flex', deadline: wed(18, 0),
            metadata: const {'manual_order': '0'}),
      ];
      final view = buildTodayView(
        tasks: tasks,
        schedule: null,
        now: now,
        scheduleMode: ScheduleMode.manual,
      );
      expect(view.overdue.map((t) => t.id).toList(), ['overdue']);
      expect(view.fixed.map((t) => t.id).toList(), ['fixed-early', 'fixed-late'],
          reason: '时刻就是序，与排序模式无关');
      expect(view.flex.map((t) => t.id).toList(), ['flex']);
      expect(view.routines.map((t) => t.id).toList(), ['routine']);
      expect(view.picked?.id, 'picked');
    });
  });

  group('数学一行不动：ScheduleResult 不认得排序模式', () {
    test('裕度 / 风险 / 优先级 / 锚点 / 门槛在三档下完全一致', () {
      final tasks = [
        task(id: 'a', deadline: wed(18, 0)),
        task(id: 'b', deadline: DateTime(2026, 10, 9, 18, 0)),
      ];
      // 内核只有 reminderMode 一个入参：排序模式根本传不进去。
      final full = scheduler.schedule(
          tasks: tasks, now: now, workRule: rule, reminderMode: ReminderMode.full);
      final quiet = scheduler.schedule(
          tasks: tasks,
          now: now,
          workRule: rule,
          reminderMode: ScheduleMode.manual.reminderMode);
      for (final id in ['a', 'b']) {
        final x = full.metricOf(id)!;
        final y = quiet.metricOf(id)!;
        expect(y.slackMinutes, x.slackMinutes);
        expect(y.risk, closeTo(x.risk, 1e-12));
        expect(y.priority, closeTo(x.priority, 1e-12));
        expect(y.nextReminderAt, x.nextReminderAt);
      }
      expect(quiet.nextTaskId, full.nextTaskId,
          reason: '"下一站是谁"由门槛与数学定，与列表顺序无关');
    });
  });

  group('任务池：与调度模式无关（池子本来就是手动整理序）', () {
    test('计划段按 pool_order / 截止排，不认 manual_order', () {
      final all = [
        task(id: 'p-far', deadline: DateTime(2026, 10, 20, 18, 0),
            metadata: const {'manual_order': '0'}),
        task(id: 'p-near', deadline: DateTime(2026, 10, 9, 18, 0)),
      ];
      final view = buildPoolView(tasks: all, now: now);
      expect(view.plan.map((t) => t.id).toList(), ['p-near', 'p-far'],
          reason: '池子认 pool_order / 截止日期，manual_order 只对今日生效');
    });
  });

  group('TaskService：手动序与模式切换', () {
    late MemoryTaskRepository repo;
    late TaskService svc;

    setUp(() {
      repo = MemoryTaskRepository();
      svc = TaskService(
        repo: repo,
        scheduler: scheduler,
        workRule: rule,
        clock: () => now,
      );
    });

    test('setManualOrder 整段重编号并落盘；标准档下原样保留且不生效', () async {
      final a = await svc.createTask(title: 'a', deadline: wed(18, 0));
      final b = await svc.createTask(
          title: 'b', deadline: DateTime(2026, 10, 20, 18, 0));

      await svc.setManualOrder([b.id, a.id]);
      expect((await repo.getTask(b.id))!.manualOrder, 0);
      expect((await repo.getTask(a.id))!.manualOrder, 1);

      // 标准档：手动序在，但不参与排序（a 更紧，仍在前）。
      expect(svc.lastSchedule!.items.first.taskId, a.id);
      await svc.updateScheduleMode(ScheduleMode.manual);
      expect(svc.isManualSort, isTrue);

      // 切回标准，序号一个字节都没动。
      await svc.updateScheduleMode(ScheduleMode.standard);
      expect((await repo.getTask(b.id))!.manualOrder, 0);
      expect(svc.lastSchedule!.items.first.taskId, a.id);
    });

    test('切模式只重算，不动任何任务数据', () async {
      await svc.createTask(title: 'a', deadline: wed(18, 0));
      final before = await repo.loadAll();
      await svc.updateScheduleMode(ScheduleMode.manual);
      await svc.updateScheduleMode(ScheduleMode.full);
      final after = await repo.loadAll();
      expect(after.map((t) => t.metadata).toList(),
          before.map((t) => t.metadata).toList());
    });

    test('默认标准档：不传参就是原来那套行为', () {
      expect(svc.scheduleMode, ScheduleMode.standard);
      expect(AppSettings.defaults.scheduleMode, ScheduleMode.standard);
      expect(svc.isManualSort, isFalse);
    });
  });

  group('设置落盘：schedule_mode', () {
    test('三档往返与缺省', () {
      for (final mode in ScheduleMode.values) {
        final back = AppSettings.fromJson(AppSettings(scheduleMode: mode).toJson());
        expect(back.scheduleMode, mode);
      }
      expect(AppSettings.fromJson({}).scheduleMode, ScheduleMode.standard);
      expect(AppSettings.fromJson({'schedule_mode': 'nonsense'}).scheduleMode,
          ScheduleMode.standard);
    });

    test('兼容旧字段 reminder_mode（standard / full 两个值原样认）', () {
      expect(AppSettings.fromJson({'reminder_mode': 'full'}).scheduleMode,
          ScheduleMode.full);
      expect(AppSettings.fromJson({'reminder_mode': 'standard'}).scheduleMode,
          ScheduleMode.standard);
      expect(AppSettings.fromJson({'reminder_mode': 'nonsense'}).scheduleMode,
          ScheduleMode.standard);
      expect(
          AppSettings.fromJson(
                  {'reminder_mode': 'full', 'schedule_mode': 'manual'})
              .scheduleMode,
          ScheduleMode.manual,
          reason: '新字段优先');
    });
  });
}

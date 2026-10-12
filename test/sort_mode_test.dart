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

/// 无排序模式（v1.12 决议 43 / D17）：
/// 关掉排序键与今日可推组的锚点准入，顺序全按手动序；
/// 数学（裕度 / 风险 / 锚点 / 门槛）与"四处不跟着变"的地方全部照旧。
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

  group('Scheduler：无排序模式只改顺序，不动数学', () {
    test('自动模式按 priority 排；无排序模式按 manual_order 排', () {
      final tasks = [
        task(id: 'a', deadline: wed(18, 0), importance: 5),
        task(id: 'b', deadline: wed(17, 30), importance: 1),
        task(id: 'c', deadline: wed(18, 0), importance: 3),
      ];

      final auto = scheduler.schedule(
          tasks: tasks, now: now, workRule: rule, sortMode: SortMode.auto);
      expect(auto.items.map((m) => m.taskId).toList(), isNot(['b', 'a', 'c']));

      final manual = scheduler.schedule(
          tasks: tasks, now: now, workRule: rule, sortMode: SortMode.manual);
      // 都没排过序 → 沉末尾按 id 升序（定义好的稳定裁决）
      expect(manual.items.map((m) => m.taskId).toList(), ['a', 'b', 'c']);

      final ordered = [
        task(id: 'a', deadline: wed(18, 0),
            metadata: const {'manual_order': '2'}),
        task(id: 'b', deadline: wed(17, 30),
            metadata: const {'manual_order': '0'}),
        task(id: 'c', deadline: wed(18, 0),
            metadata: const {'manual_order': '1'}),
      ];
      final m2 = scheduler.schedule(
          tasks: ordered, now: now, workRule: rule, sortMode: SortMode.manual);
      expect(m2.items.map((m) => m.taskId).toList(), ['b', 'c', 'a']);
    });

    test('排序模式不影响裕度 / 风险 / 优先级 / 锚点 / 门槛', () {
      final tasks = [
        task(id: 'a', deadline: wed(18, 0)),
        task(id: 'b', deadline: DateTime(2026, 10, 9, 18, 0)),
      ];
      final auto = scheduler.schedule(
          tasks: tasks,
          now: now,
          workRule: rule,
          reminderMode: ReminderMode.full,
          sortMode: SortMode.auto);
      final manual = scheduler.schedule(
          tasks: tasks,
          now: now,
          workRule: rule,
          reminderMode: ReminderMode.full,
          sortMode: SortMode.manual);
      for (final id in ['a', 'b']) {
        final x = auto.metricOf(id)!;
        final y = manual.metricOf(id)!;
        expect(y.slackMinutes, x.slackMinutes);
        expect(y.risk, closeTo(x.risk, 1e-12));
        expect(y.priority, closeTo(x.priority, 1e-12));
        expect(y.nextReminderAt, x.nextReminderAt);
        expect(y.reminds, x.reminds);
      }
      // 下一站取"最早会响的那一站"，与谁排前面无关。
      expect(manual.nextReminderAt, auto.nextReminderAt);
    });

    test('没排过序的沉在末尾，按 id 升序（新任务从末尾开始）', () {
      final manual = scheduler.schedule(
        tasks: [
          task(id: 'new-1', deadline: wed(18, 0)),
          task(id: 'old', deadline: wed(18, 0),
              metadata: const {'manual_order': '0'}),
          task(id: 'new-0', deadline: wed(18, 0)),
        ],
        now: now,
        workRule: rule,
        sortMode: SortMode.manual,
      );
      expect(manual.items.map((m) => m.taskId).toList(),
          ['old', 'new-0', 'new-1']);
    });
  });

  group('今日清单：准入与顺序', () {
    test('无排序模式不再按锚点筛选——远期任务也进今日', () {
      final tasks = [
        task(id: 'today', deadline: wed(18, 0)),
        task(id: 'far', deadline: DateTime(2026, 10, 20, 18, 0)),
      ];
      final schedule = scheduler.schedule(
          tasks: tasks, now: now, workRule: rule, reminderMode: ReminderMode.full);

      final auto = buildTodayView(
          tasks: tasks, schedule: schedule, now: now, sortMode: SortMode.auto);
      expect(auto.flex.map((t) => t.id).toList(), ['today'],
          reason: '自动模式：锚点落今天/今天到期才进');

      final manual = buildTodayView(
          tasks: tasks, schedule: schedule, now: now, sortMode: SortMode.manual);
      expect(manual.flex.map((t) => t.id).toList(), ['far', 'today'],
          reason: '无排序模式：全部未完成、有截止的可推任务都进；'
              '都没排过序 → 按 id 升序');
    });

    test('无排序模式没有"插队"这一层；插队标记留在任务上不受影响', () {
      final tasks = [
        task(id: 'a', deadline: wed(18, 0),
            metadata: const {'manual_order': '1'}),
        task(id: 'b', deadline: wed(18, 0),
            metadata: const {'manual_order': '0'}),
        task(id: 'pinned', deadline: wed(18, 0), metadata: const {
          'pinned': '2026-10-07T15:00:00.000',
          'manual_order': '2',
        }),
      ];
      final schedule = scheduler.schedule(
          tasks: tasks, now: now, workRule: rule, reminderMode: ReminderMode.full);

      final auto = buildTodayView(
          tasks: tasks, schedule: schedule, now: now, sortMode: SortMode.auto);
      expect(auto.pinned.map((t) => t.id).toList(), ['pinned']);
      expect(auto.flex.first.id, isNot('pinned'));

      final manual = buildTodayView(
          tasks: tasks, schedule: schedule, now: now, sortMode: SortMode.manual);
      expect(manual.pinned, isEmpty);
      expect(manual.flex.map((t) => t.id).toList(), ['b', 'a', 'pinned']);
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
        sortMode: SortMode.manual,
      );
      expect(view.overdue.map((t) => t.id).toList(), ['overdue']);
      expect(view.fixed.map((t) => t.id).toList(),
          ['fixed-early', 'fixed-late'],
          reason: '时刻就是序，与排序模式无关');
      expect(view.flex.map((t) => t.id).toList(), ['flex']);
      expect(view.routines.map((t) => t.id).toList(), ['routine']);
      expect(view.picked?.id, 'picked');
    });
  });

  group('任务池：手动序 + 周期条目沉末尾', () {
    test('无排序模式：计划段与散件段都按手动序，周期条目接在后面', () {
      final planTasks = [
        task(id: 'p-far', deadline: DateTime(2026, 10, 20, 18, 0)),
        task(id: 'p-near', deadline: DateTime(2026, 10, 9, 18, 0)),
      ];
      final loose = [
        task(id: 'l-1', deadline: null),
        task(id: 'l-2', deadline: null, metadata: const {'manual_order': '0'}),
      ];
      final all = [...planTasks, ...loose];
      final occurrences = [
        RoutineOccurrence(
          routine: Routine(
              id: 'r-1',
              title: '晨跑',
              created: DateTime(2026, 10, 1),
              minuteOfDay: 7 * 60),
          at: DateTime(2026, 10, 8, 7, 0),
        ),
      ];

      final view = buildPoolView(
        tasks: all,
        now: now,
        routineOccurrences: occurrences,
        sortMode: SortMode.manual,
      );
      expect(view.plan.map((t) => t.id).toList(), ['p-far', 'p-near'],
          reason: '都没排过序 → 按 id 升序，不再是截止日期升序');
      expect(view.loose.map((t) => t.id).toList(), ['l-2', 'l-1'],
          reason: '排过序的在前');
      expect(view.rows.length, 3);
      expect(view.rows[0], isA<PoolTaskRow>());
      expect(view.rows[1], isA<PoolTaskRow>());
      expect(view.rows[2], isA<PoolRoutineRow>(),
          reason: '周期条目没有手动序，按发生日期接在手动排的任务之后');
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

    test('setManualOrder 整段重编号并落盘；自动模式下原样保留', () async {
      final a = await svc.createTask(title: 'a', deadline: wed(18, 0));
      final b = await svc.createTask(
          title: 'b', deadline: DateTime(2026, 10, 20, 18, 0));

      await svc.setManualOrder([b.id, a.id]);
      expect((await repo.getTask(b.id))!.manualOrder, 0);
      expect((await repo.getTask(a.id))!.manualOrder, 1);

      // 自动模式：手动序在，但不参与排序（a 更紧，仍在前面）。
      expect(svc.lastSchedule!.items.first.taskId, a.id);
      await svc.updateSortMode(SortMode.manual);
      expect(svc.lastSchedule!.items.map((m) => m.taskId).toList(),
          [b.id, a.id]);

      // 切回自动，序号一个字节都没动。
      await svc.updateSortMode(SortMode.auto);
      expect((await repo.getTask(b.id))!.manualOrder, 0);
      expect(svc.lastSchedule!.items.first.taskId, a.id);
    });

    test('切模式只重算视图：不动任何任务数据', () async {
      await svc.createTask(title: 'a', deadline: wed(18, 0));
      final before = await repo.loadAll();
      await svc.updateSortMode(SortMode.manual);
      final after = await repo.loadAll();
      expect(after.map((t) => t.id).toList(), before.map((t) => t.id).toList());
      expect(after.map((t) => t.metadata).toList(),
          before.map((t) => t.metadata).toList());
    });

    test('默认自动模式：不传参就是原来那套行为', () {
      expect(svc.sortMode, SortMode.auto);
      expect(AppSettings.defaults.sortMode, SortMode.auto);
    });
  });

  group('设置落盘：sort_mode', () {
    test('往返与缺省：认得 manual，其他一律落到 auto', () {
      const manual = AppSettings(sortMode: SortMode.manual);
      expect(manual.toJson()['sort_mode'], 'manual');
      final back = AppSettings.fromJson(manual.toJson());
      expect(back.sortMode, SortMode.manual);
      expect(back.reminderMode, ReminderMode.standard,
          reason: '两个模式互不干扰');

      expect(AppSettings.fromJson({}).sortMode, SortMode.auto);
      expect(AppSettings.fromJson({'sort_mode': 'nonsense'}).sortMode,
          SortMode.auto);
    });
  });
}

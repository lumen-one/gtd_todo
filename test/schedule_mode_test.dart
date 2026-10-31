import 'package:flutter_test/flutter_test.dart';
import 'package:gtd_todo/application/settings.dart';
import 'package:gtd_todo/application/task_service.dart';
import 'package:gtd_todo/application/today_view.dart';
import 'package:gtd_todo/domain/schedule.dart';
import 'package:gtd_todo/domain/task.dart';
import 'package:gtd_todo/domain/time_context.dart';
import 'package:gtd_todo/repository/memory_task_repository.dart';
import 'package:gtd_todo/scheduler/slack_priority_scheduler.dart';

/// 调度模式两档（决定卡 mode-as-information-depth）：一条**信息深度**的谱系——
/// 上一档多问工时。重要度不是档位，是标准档里的一个开关（`ask_importance`）：
/// 关掉时排序乘数取 1、表单里也不出现。
///
/// 无排序档不跑调度：③ 组只收"今天到期"的、顺序走手动序，提醒是截止前一次的
/// 时点提醒；另把散件段铺到今日页底（⑥）。内核完全不知道排序模式：
/// `Scheduler.schedule` 只认任务与时间，成员/顺序/散件都是业务层的查询口径。
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

  group('两档是信息深度的阶梯', () {
    test('差别只剩问什么、谁排序', () {
      expect(ScheduleMode.manual.isManual, isTrue);
      expect(ScheduleMode.standard.isManual, isFalse);
    });

    test('byName 只认两档；旧的 full 落到标准', () {
      expect(ScheduleMode.byName('manual'), ScheduleMode.manual);
      expect(ScheduleMode.byName('standard'), ScheduleMode.standard);
      expect(ScheduleMode.byName('full'), ScheduleMode.standard,
          reason: '那一档的额外行为由 ask_importance 接着（见设置落盘那组）');
      expect(ScheduleMode.byName('nonsense'), ScheduleMode.standard);
      expect(ScheduleMode.byName(null), ScheduleMode.standard);
    });
  });

  group('今日清单：无排序档只收今天到期', () {
    test('远期任务不会被塞进今天', () {
      final tasks = [
        task(id: 'today', deadline: wed(18, 0)),
        task(id: 'far', deadline: DateTime(2026, 10, 20, 18, 0)),
      ];
      final schedule = scheduler.schedule(
          tasks: tasks, now: now, workRule: rule);

      final auto = buildTodayView(
          tasks: tasks, schedule: schedule, now: now,
          scheduleMode: ScheduleMode.standard);
      final manual = buildTodayView(
          tasks: tasks, schedule: schedule, now: now,
          scheduleMode: ScheduleMode.manual);

      expect(auto.flex.map((t) => t.id).toList(), ['today'],
          reason: '锚点落在今天 / 今天到期才进');
      expect(manual.flex.map((t) => t.id).toList(), ['today'],
          reason: '无排序只认今天到期');
    });

    test('裕度薄、今天该动手的远期任务：标准档捞进来，无排序档留在池子', () {
      // 周五 18:00 截止、要 900 分钟：available 1020 → slack 120，锚点落今天 17:00。
      final tasks = [
        task(id: 'far-tight', deadline: DateTime(2026, 10, 9, 18, 0),
            remaining: 900, estimated: 900),
      ];
      final schedule = scheduler.schedule(
          tasks: tasks, now: now, workRule: rule);
      final metric = schedule.metricOf('far-tight')!;
      expect(metric.displayStatus, TaskDisplayStatus.normal);
      expect(metric.nextReminderAt!.day, 7, reason: '锚点落在今天 17:00');

      final auto = buildTodayView(
          tasks: tasks, schedule: schedule, now: now,
          scheduleMode: ScheduleMode.standard);
      expect(auto.flex.map((t) => t.id).toList(), ['far-tight'],
          reason: '标准档按锚点提前介入');

      final manual = buildTodayView(
          tasks: tasks, schedule: null, now: now,
          scheduleMode: ScheduleMode.manual);
      expect(manual.flex, isEmpty,
          reason: '无排序档没有锚点这一层，远期件等当天到期才出现');
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
          tasks: tasks, now: now, workRule: rule);

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

    test('三处不跟着变：逾期置顶 / 开始型按时刻 / 例行按时点', () {
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
      expect(view.picked, isNull, reason: '这一档不跑定期挑，⑤ 不出现');
      expect(view.loose.map((t) => t.id).toList(), ['picked'],
          reason: '带被挑标记的散件照样进 ⑥——标记这一档不参与分区');
    });
  });

  group('内核与档位无关：ScheduleResult 不认得排序模式', () {
    test('同样的入参下算出来的量完全一致', () {
      final tasks = [
        task(id: 'a', deadline: wed(18, 0)),
        task(id: 'b', deadline: DateTime(2026, 10, 9, 18, 0)),
      ];
      // 排序模式根本传不进内核：两次调用给的是同一份入参。
      final full = scheduler.schedule(tasks: tasks, now: now, workRule: rule);
      final quiet = scheduler.schedule(tasks: tasks, now: now, workRule: rule);
      for (final id in ['a', 'b']) {
        final x = full.metricOf(id)!;
        final y = quiet.metricOf(id)!;
        expect(y.slackMinutes, x.slackMinutes);
        expect(y.risk, closeTo(x.risk, 1e-12));
        expect(y.priority, closeTo(x.priority, 1e-12));
        expect(y.nextReminderAt, x.nextReminderAt);
      }
      expect(quiet.nextTaskId, full.nextTaskId,
          reason: '"下一站是谁"由数学定，与列表顺序无关');
    });
  });

  group('⑥ 散件段（v1.27）：无排序档把散件铺到今日页底', () {
    test('标准档：散件不进今日（仍归任务池散件段）', () {
      final view = buildTodayView(
        tasks: [task(id: 'loose', deadline: null)],
        schedule: null,
        now: now,
        scheduleMode: ScheduleMode.standard,
      );
      expect(view.loose, isEmpty, reason: '标准档一行不变');
      expect(view.isEmpty, isTrue);
    });

    test('无排序档：散件进 ⑥，按整理序（pool_order → 创建时间）', () {
      final view = buildTodayView(
        tasks: [
          task(id: 'newest', deadline: null,
              created: DateTime(2026, 10, 7, 15, 30)),
          task(id: 'ordered-1', deadline: null,
              created: DateTime(2026, 10, 7, 15, 20),
              metadata: const {'pool_order': '1'}),
          task(id: 'ordered-0', deadline: null,
              created: DateTime(2026, 10, 7, 15, 10),
              metadata: const {'pool_order': '0'}),
          task(id: 'older', deadline: null,
              created: DateTime(2026, 10, 7, 14, 0),
              metadata: const {'manual_order': '0'}),
        ],
        schedule: null,
        now: now,
        scheduleMode: ScheduleMode.manual,
      );
      expect(
          view.loose.map((t) => t.id).toList(),
          ['ordered-0', 'ordered-1', 'older', 'newest'],
          reason: '整理过的在前；manual_order 是 ③ 的序号，对 ⑥ 无效');
    });

    test('无排序档不挑：被挑标记忽略，散件全在 ⑥；挂起件两段都不占', () {
      final view = buildTodayView(
        tasks: [
          task(id: 'picked-for-today', deadline: null,
              metadata: const {'picked_for_today': '2026-10-07'}),
          task(id: 'hanging', deadline: null,
              metadata: const {'in_progress': '2026-10-06T09:00:00.000'}),
          task(id: 'plain', deadline: null),
        ],
        schedule: null,
        now: now,
        scheduleMode: ScheduleMode.manual,
      );
      expect(view.picked, isNull, reason: '这一档不跑定期挑，⑤ 不出现');
      expect(view.loose.map((t) => t.id).toList(),
          ['picked-for-today', 'plain'],
          reason: '被挑标记这一档不参与分区；挂起件只在 ⓿');
      expect(view.inProgress.map((t) => t.id).toList(), ['hanging']);
    });

    test('搬到池子的散件（loose_home: pool）不在 ⑥', () {
      final view = buildTodayView(
        tasks: [
          task(id: 'stays', deadline: null),
          task(id: 'moved', deadline: null,
              metadata: const {'loose_home': 'pool'}),
        ],
        schedule: null,
        now: now,
        scheduleMode: ScheduleMode.manual,
      );
      expect(view.loose.map((t) => t.id).toList(), ['stays']);
    });
  });

  group('任务池：散件按 loose_home 分家（无排序档）', () {
    test('splitLoose 时只收搬过来的那些，其余计数给空状态文案', () {
      final all = [
        task(id: 'loose-1', deadline: null),
        task(id: 'loose-2', deadline: null),
      ];
      final shown = buildPoolView(tasks: all, now: now);
      expect(shown.loose.map((t) => t.id).toList(), ['loose-1', 'loose-2']);

      final split = buildPoolView(tasks: all, now: now, splitLoose: true);
      expect(split.loose, isEmpty);
      expect(split.hiddenLooseCount, 2);
      expect(split.isEmpty, isTrue);
    });

    test('搬过来的那一件住池子，计数只算留在今日页的', () {
      final all = [
        task(id: 'stays', deadline: null),
        task(id: 'moved', deadline: null,
            metadata: const {'loose_home': 'pool'}),
      ];
      final split = buildPoolView(tasks: all, now: now, splitLoose: true);
      expect(split.loose.map((t) => t.id).toList(), ['moved']);
      expect(split.hiddenLooseCount, 1);
    });

    test('标准档不认 loose_home：散件照旧全在池子', () {
      final all = [
        task(id: 'moved', deadline: null,
            metadata: const {'loose_home': 'pool'}),
      ];
      final view = buildPoolView(tasks: all, now: now);
      expect(view.loose.map((t) => t.id).toList(), ['moved']);
    });

    test('计划段照旧：搬走的只有散件段', () {
      final all = [
        task(id: 'loose', deadline: null),
        task(id: 'plan', deadline: DateTime(2026, 10, 9, 18, 0)),
      ];
      final view = buildPoolView(tasks: all, now: now, splitLoose: true);
      expect(view.plan.map((t) => t.id).toList(), ['plan']);
      expect(view.hiddenLooseCount, 1);
    });
  });

  group('任务池：与调度模式无关', () {
    test('计划段只按日期排：pool_order 与 manual_order 都压不到它上面', () {
      final all = [
        task(id: 'p-far', deadline: DateTime(2026, 10, 20, 18, 0),
            metadata: const {'manual_order': '0', 'pool_order': '0'}),
        task(id: 'p-near', deadline: DateTime(2026, 10, 9, 18, 0)),
      ];
      final view = buildPoolView(tasks: all, now: now);
      expect(view.plan.map((t) => t.id).toList(), ['p-near', 'p-far'],
          reason: '计划段按日期升序；整理序只剩散件段用，manual_order 只对今日生效');
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
      await svc.updateScheduleMode(ScheduleMode.standard);
      final after = await repo.loadAll();
      expect(after.map((t) => t.metadata).toList(),
          before.map((t) => t.metadata).toList());
    });

    test('TaskService 不传参 = 标准档（装配点随后按设置覆盖）', () {
      expect(svc.scheduleMode, ScheduleMode.standard);
      expect(svc.isManualSort, isFalse);
    });

    test('『问重要度』只改乘数：关掉取 1，打开乘 importance，任务数据不动', () async {
      final a = await svc.createTask(
          title: 'a', deadline: wed(18, 0), estimatedWorkMinutes: 120,
          importance: 5);
      final off = svc.lastSchedule!.metricOf(a.id)!.priority;

      await svc.updateAskImportance(true);
      expect(svc.askImportance, isTrue);
      expect(svc.lastSchedule!.metricOf(a.id)!.priority,
          closeTo(off * 5, 1e-9), reason: '乘数从 1 换成 importance');

      await svc.updateAskImportance(false);
      expect(svc.lastSchedule!.metricOf(a.id)!.priority,
          closeTo(off, 1e-9), reason: '关回去不残留');
      expect((await repo.getTask(a.id))!.importance, 5,
          reason: '已经存下的值原样留着，开关不动任务数据');
    });

    test('新装默认档 = 无排序（设定文件都不存在时走 defaults）', () {
      expect(AppSettings.defaults.scheduleMode, ScheduleMode.manual);
      expect(AppSettings.defaults.scheduleMode.isManual, isTrue);
    });
  });

  group('设置落盘：schedule_mode', () {
    test('无排序档的提前量：默认 30 分钟，往返不丢，越界夹回', () {
      expect(AppSettings.defaults.manualLeadMinutes, 30);
      expect(
          AppSettings.fromJson({'manual_lead_minutes': 90}).manualLeadMinutes, 90);
      expect(AppSettings.fromJson({'manual_lead_minutes': 1}).manualLeadMinutes, 5);
      expect(AppSettings.fromJson({'manual_lead_minutes': 99999})
          .manualLeadMinutes, 1440);
      expect(AppSettings.fromJson({'manual_lead_minutes': 'x'}).manualLeadMinutes,
          30);
      final back = AppSettings.fromJson(
          const AppSettings(manualLeadMinutes: 60).toJson());
      expect(back.manualLeadMinutes, 60);
    });
    test('两档往返与缺省', () {
      for (final mode in ScheduleMode.values) {
        final back = AppSettings.fromJson(AppSettings(scheduleMode: mode).toJson());
        expect(back.scheduleMode, mode);
      }
      // 文件在、只是缺键 = 老装机：兜底标准，升级不改人家已经排好的清单
      expect(AppSettings.fromJson({}).scheduleMode, ScheduleMode.standard);
      expect(AppSettings.fromJson({'schedule_mode': 'nonsense'}).scheduleMode,
          ScheduleMode.standard);
      // 『问重要度』：缺省关，往返不丢
      expect(AppSettings.defaults.askImportance, isFalse);
      expect(
          AppSettings.fromJson(
                  const AppSettings(askImportance: true).toJson())
              .askImportance,
          isTrue);
    });

    test('兼容旧值 full：落到标准，并把『问重要度』打开', () {
      expect(AppSettings.fromJson({'schedule_mode': 'full'}).scheduleMode,
          ScheduleMode.standard);
      expect(AppSettings.fromJson({'schedule_mode': 'full'}).askImportance,
          isTrue, reason: '那一档当初要的就是"问重要度"');
      expect(AppSettings.fromJson({'reminder_mode': 'full'}).askImportance,
          isTrue, reason: '更老的字段同一套');
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
      // 文件里显式写了这个开关就以文件为准——不替人把它打开
      expect(
          AppSettings.fromJson(
                  {'schedule_mode': 'full', 'ask_importance': false})
              .askImportance,
          isFalse);
    });
  });
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gtd_todo/application/routine_service.dart';
import 'package:gtd_todo/application/task_service.dart';
import 'package:gtd_todo/application/today_view.dart';
import 'package:gtd_todo/domain/event.dart';
import 'package:gtd_todo/domain/routine.dart';
import 'package:gtd_todo/domain/schedule.dart';
import 'package:gtd_todo/domain/task.dart';
import 'package:gtd_todo/domain/time_context.dart';
import 'package:gtd_todo/repository/markdown_routine_codec.dart';
import 'package:gtd_todo/repository/markdown_routine_repository.dart';
import 'package:gtd_todo/repository/markdown_task_repository.dart';
import 'package:gtd_todo/repository/memory_routine_repository.dart';
import 'package:gtd_todo/repository/memory_task_repository.dart';
import 'package:gtd_todo/scheduler/slack_scheduler.dart';

/// 周期任务（决议 5/10/12/23/27）的契约测试。
void main() {
  Routine makeRoutine({
    String id = 'routine-1',
    String title = '晨跑',
    RoutineFrequency frequency = RoutineFrequency.daily,
    List<int> weekdays = const [],
    int? minuteOfDay,
    bool remind = false,
    bool enabled = true,
  }) =>
      Routine(
        id: id,
        title: title,
        frequency: frequency,
        weekdays: weekdays,
        minuteOfDay: minuteOfDay,
        remind: remind,
        enabled: enabled,
        created: DateTime(2026, 10, 1, 9, 0),
      );

  group('Routine 纯函数（频率 / 发生时刻 / 下一次）', () {
    test('daily：每天都发生；weekly：只在选中的星期', () {
      final daily = makeRoutine();
      final weekly = makeRoutine(
          frequency: RoutineFrequency.weekly, weekdays: [1, 3, 5]);
      // 2026-10-07 是周三
      expect(daily.occursOn(DateTime(2026, 10, 7)), isTrue);
      expect(weekly.occursOn(DateTime(2026, 10, 7)), isTrue); // 周三
      expect(weekly.occursOn(DateTime(2026, 10, 8)), isFalse); // 周四
      expect(makeRoutine(enabled: false).occursOn(DateTime(2026, 10, 7)),
          isFalse);
    });

    test('nextOccurrence：跳过不匹配的日子；不限时刻返回当天零点', () {
      final weekly = makeRoutine(
          frequency: RoutineFrequency.weekly,
          weekdays: [1],
          minuteOfDay: 7 * 60);
      // 周三 → 下周一 07:00
      expect(weekly.nextOccurrence(DateTime(2026, 10, 7, 12, 0)),
          DateTime(2026, 10, 12, 7, 0));
      final loose = makeRoutine();
      expect(loose.nextOccurrence(DateTime(2026, 10, 7, 12, 0)),
          DateTime(2026, 10, 7));
      expect(loose.nextOccurrence(DateTime(2026, 10, 7, 12, 0), includeToday: false),
          DateTime(2026, 10, 8));
    });

    test('校验：设了响必须有时刻；每周必须选天；标题非空', () {
      expect(() => makeRoutine(remind: true).validate(), throwsArgumentError);
      expect(
          () => makeRoutine(frequency: RoutineFrequency.weekly).validate(),
          throwsArgumentError);
      expect(() => makeRoutine(title: '  ').validate(), throwsArgumentError);
    });
  });

  group('routines.md codec（字段级保真）', () {
    test('往返：新建 → 解码一致（含时刻/响/启用）', () {
      final codec = MarkdownRoutineCodec();
      final raw = codec.encode([
        makeRoutine(
            frequency: RoutineFrequency.weekly,
            weekdays: [3, 1, 5, 1],
            minuteOfDay: 7 * 60 + 30,
            remind: true),
      ]);
      final back = codec.decode(raw).routines.single;
      expect(back.id, 'routine-1');
      expect(back.title, '晨跑');
      expect(back.frequency, RoutineFrequency.weekly);
      expect(back.weekdays, [1, 3, 5]);
      expect(back.minuteOfDay, 450);
      expect(back.remind, isTrue);
      expect(back.enabled, isTrue);
    });

    test('未知字段/注释/正文原样保留；应用字段原地改写', () {
      final codec = MarkdownRoutineCodec();
      const raw = '---\n'
          'id: routine-1\n'
          'title: 晨跑\n'
          '# 手写注释\n'
          'mood: 好\n'
          'freq: daily\n'
          'remind: false\n'
          'enabled: true\n'
          'created: 2026-10-01T09:00\n'
          '---\n'
          '\n'
          '备注正文，应用不改。\n';
      final decoded = codec.decode(raw).routines.single;
      expect(decoded.extra['mood'], '好');

      final re = codec.encode(
        [decoded.copyWith(title: '夜跑')],
        originalRaw: raw,
      );
      expect(re, contains('# 手写注释'));
      expect(re, contains('mood: 好'));
      expect(re, contains('title: 夜跑'));
      expect(re, contains('备注正文，应用不改。'));
      expect(re, isNot(contains('title: 晨跑')));
    });

    test('正文被改则重写正文；规则被移除则条目消失', () {
      final codec = MarkdownRoutineCodec();
      final raw = codec.encode([makeRoutine()]);
      final decoded = codec.decode(raw).routines.single;
      final re = codec.encode(
          [decoded.copyWith(description: '新的备注')], originalRaw: raw);
      expect(re, contains('新的备注'));

      final empty = codec.encode(const [], originalRaw: raw);
      expect(empty.trim(), isEmpty);
    });

    test('多条目：按 id 分别合并', () {
      final codec = MarkdownRoutineCodec();
      final raw = codec.encode([
        makeRoutine(id: 'routine-a', title: 'A'),
        makeRoutine(id: 'routine-b', title: 'B', minuteOfDay: 22 * 60),
      ]);
      expect(codec.decode(raw).routines, hasLength(2));
      final list = codec.decode(raw).routines;
      final merged = codec.encode([
        list[0].copyWith(title: 'A2'),
        list[1],
      ], originalRaw: raw);
      final back = codec.decode(merged).routines;
      expect(back.map((r) => r.title), ['A2', 'B']);
      expect(back[1].minuteOfDay, 22 * 60);
    });
  });

  group('RoutineService（命令 + 当天实例）', () {
    late MemoryTaskRepository taskRepo;
    late RoutineService routines;
    late TaskService tasks;
    var now = DateTime(2026, 10, 7, 8, 0); // 周三

    setUp(() async {
      now = DateTime(2026, 10, 7, 8, 0);
      taskRepo = MemoryTaskRepository();
      tasks = TaskService(
        repo: taskRepo,
        scheduler: const SlackScheduler(),
        workRule: WorkTimeRule.standard,
        clock: () => now,
      );
      routines = RoutineService(
        repo: MemoryRoutineRepository(),
        tasks: tasks,
        clock: () => now,
      );
      await routines.load();
    });

    test('create：规则入库 + 生成当天实例（不占工时、不进调度）', () async {
      final r = await routines.create(
          title: '晨跑', minuteOfDay: 7 * 60, remind: true);
      final instance = tasks.byId(TaskService.routineInstanceId(r.id, '2026-10-07'));
      expect(instance, isNotNull);
      expect(instance!.type, TaskType.routine);
      expect(instance.routineId, r.id);
      expect(instance.estimatedWork, 0);
      expect(instance.isCompleted, isFalse, reason: '0 工时不判完成');
      expect(instance.routineRemind, isTrue);
      expect(instance.deadline, DateTime(2026, 10, 7, 7, 0));

      // 不进 Slack 调度（可推组为空）
      await tasks.refreshSchedule();
      expect(tasks.lastSchedule!.items, isEmpty);
    });

    test('generateTodayInstances：幂等；停用的规则不生成', () async {
      final r = await routines.create(title: '晨跑');
      final again = await routines.generateTodayInstances();
      expect(again, 0, reason: '已有实例，不重复生成');
      await routines.setEnabled(r.id, false);
      expect(tasks.byId(TaskService.routineInstanceId(r.id, '2026-10-07')),
          isNull, reason: '停用后未完成的实例被清掉');
    });

    test('weekly 只在选中的日子生成实例', () async {
      await routines.create(
          title: '周报',
          frequency: RoutineFrequency.weekly,
          weekdays: [5]); // 周五
      expect(tasks.tasks, isEmpty, reason: '周三不生成');
      now = DateTime(2026, 10, 9, 8, 0); // 周五
      await routines.generateTodayInstances();
      expect(tasks.tasks, hasLength(1));
    });

    test('update：改标题/时刻同步到今日实例（不提供"编辑实例"）', () async {
      final r = await routines.create(title: '晨跑', minuteOfDay: 7 * 60);
      await routines.update(r.id, title: '夜跑', minuteOfDay: 21 * 60);
      final instance = tasks.byId(TaskService.routineInstanceId(r.id, '2026-10-07'))!;
      expect(instance.title, '夜跑');
      expect(instance.deadline, DateTime(2026, 10, 7, 21, 0));
      // 实例不能被 updateTask 改（决议 23）
      await expectLater(
          tasks.updateTask(instance.id, title: '手改'), throwsArgumentError);
    });

    test('跳过今天：不完成、今日不再显示，次日再生', () async {
      final r = await routines.create(title: '晨跑');
      final id = TaskService.routineInstanceId(r.id, '2026-10-07');
      await tasks.skipRoutineToday(id);
      final view = buildTodayView(
          tasks: tasks.tasks, schedule: tasks.lastSchedule, now: now);
      expect(view.routines, isEmpty);
      expect(tasks.byId(id)!.isCompleted, isFalse);

      now = DateTime(2026, 10, 8, 8, 0);
      await routines.generateTodayInstances();
      final next = buildTodayView(
          tasks: tasks.tasks, schedule: tasks.lastSchedule, now: now);
      expect(next.routines.map((t) => t.title), ['晨跑']);
    });

    test('delete：规则移除 + 未完成实例一并清掉', () async {
      final r = await routines.create(title: '晨跑');
      await routines.delete(r.id);
      expect(routines.routines, isEmpty);
      expect(tasks.tasks, isEmpty);
    });

    test('规则同步：内容未变不落盘（防两个引擎互相触发的写回环）', () async {
      final r = await routines.create(title: '晨跑', minuteOfDay: 7 * 60);
      final types = <DomainEventType>[];
      final sub = tasks.events.listen((e) => types.add(e.type));
      // 第二次生成 + 显式同步：内容一致 → 不应产生任何写盘事件
      await routines.generateTodayInstances();
      await tasks.syncRoutineForDay(r, DateTime(2026, 10, 7, 9, 0));
      await Future<void>.delayed(Duration.zero);
      expect(types.where((t) => t == DomainEventType.routineUpdated), isEmpty);
      await sub.cancel();

      // 规则改了 → 应当同步到当天实例
      final changed = r.copyWith(title: '夜跑');
      await tasks.syncRoutineForDay(changed, DateTime(2026, 10, 7, 9, 0));
      expect(
          tasks.byId(TaskService.routineInstanceId(r.id, '2026-10-07'))!.title,
          '夜跑');
    });

    test('事件流：routineCreated/Updated/Deleted（origin 可审计）', () async {
      final seen = <DomainEventType>[];
      final sub = routines.events.listen((e) => seen.add(e.type));
      final r = await routines.create(title: '晨跑');
      await routines.update(r.id, title: '夜跑');
      await routines.delete(r.id);
      await Future<void>.delayed(Duration.zero);
      expect(seen, [
        DomainEventType.routineCreated,
        DomainEventType.routineUpdated,
        DomainEventType.routineDeleted,
      ]);
      await sub.cancel();
    });
  });

  group('落盘回归：新建文件的 metadata 必须写回（模拟器实测抓到的 bug）', () {
    test('规则实例经 Markdown 落盘 → 重新加载仍是 routine 实例', () async {
      final dir = await Directory.systemTemp.createTemp('gtd-routine-');
      final taskRepo = MarkdownTaskRepository(dir.path);
      DateTime clock() => DateTime(2026, 10, 7, 9, 0);
      final tasks = TaskService(
        repo: taskRepo,
        scheduler: const SlackScheduler(),
        workRule: WorkTimeRule.standard,
        clock: clock,
      );
      final routines = RoutineService(
        repo: MarkdownRoutineRepository(dir.path),
        tasks: tasks,
        clock: clock,
      );
      await routines.load();
      await routines.create(title: '晨跑', minuteOfDay: 7 * 60);

      // 落盘内容必须带 type/routine/routine_date：它们在**内核属性文档**里
      final id = TaskService.routineInstanceId(
          routines.routines.single.id, '2026-10-07');
      final raw = await File('${dir.path}${Platform.pathSeparator}'
              '.gtd${Platform.pathSeparator}$id.md')
          .readAsString();
      expect(raw, contains('type: routine'));
      expect(raw, contains('routine: '));

      // 重新装配（等价于重启应用）后仍然进今日清单的例行组
      final reloaded = TaskService(
        repo: MarkdownTaskRepository(dir.path),
        scheduler: const SlackScheduler(),
        workRule: WorkTimeRule.standard,
        clock: clock,
      );
      await reloaded.refreshSchedule();
      final view = buildTodayView(
          tasks: reloaded.tasks,
          schedule: reloaded.lastSchedule,
          now: DateTime(2026, 10, 7, 9, 0));
      expect(view.routines.map((t) => t.title), ['晨跑']);
      await dir.delete(recursive: true);
    });

    test('fixed 任务落盘后重新加载仍是 fixed（不被误判完成）', () async {
      final dir = await Directory.systemTemp.createTemp('gtd-fixed-');
      DateTime clock() => DateTime(2026, 10, 7, 9, 0);
      final svc = TaskService(
        repo: MarkdownTaskRepository(dir.path),
        scheduler: const SlackScheduler(),
        workRule: WorkTimeRule.standard,
        clock: clock,
      );
      await svc.createTask(
          title: '例会', type: TaskType.fixed,
          deadline: DateTime(2026, 10, 7, 14, 0));
      final reloaded = TaskService(
        repo: MarkdownTaskRepository(dir.path),
        scheduler: const SlackScheduler(),
        workRule: WorkTimeRule.standard,
        // 本用例要断言"时点提醒还在"，所以要出声（默认标准模式不产出提醒）。
        scheduleMode: ScheduleMode.full,
        clock: clock,
      );
      await reloaded.refreshSchedule();
      final t = reloaded.tasks.single;
      expect(t.type, TaskType.fixed);
      expect(t.isCompleted, isFalse);
      expect(reloaded.nextPointReminder()!.at, DateTime(2026, 10, 7, 14, 0));
      await dir.delete(recursive: true);
    });
  });

  group('今日清单 ④ 例行组 + 任务池计划段（决议 12/27）', () {
    test('实例进例行组、参与编号顺序（在可推组之后）', () async {
      final routineRepo = MemoryRoutineRepository();
      final tasks = TaskService(
        repo: MemoryTaskRepository(),
        scheduler: const SlackScheduler(),
        workRule: WorkTimeRule.standard,
        clock: () => DateTime(2026, 10, 7, 9, 0),
      );
      final routines = RoutineService(
          repo: routineRepo, tasks: tasks, clock: () => DateTime(2026, 10, 7, 9, 0));
      await routines.load();
      await routines.create(title: '晨跑', minuteOfDay: 7 * 60);
      await tasks.createTask(
          title: '写周报',
          deadline: DateTime(2026, 10, 7, 18, 0),
          estimatedWorkMinutes: 60);
      await tasks.refreshSchedule();

      final view = buildTodayView(
          tasks: tasks.tasks,
          schedule: tasks.lastSchedule,
          now: DateTime(2026, 10, 7, 9, 0));
      expect(view.flex.map((t) => t.title), ['写周报']);
      expect(view.routines.map((t) => t.title), ['晨跑']);
    });

    test('计划段：周期条目按发生日期与任务混排；开关关闭时消失', () {
      final tasks = [
        Task(
          id: 'task-1',
          title: '明天的事',
          deadline: DateTime(2026, 10, 8, 18, 0),
          estimatedWork: 60,
          created: DateTime(2026, 10, 7, 9, 0),
        ),
      ];
      final rule = Routine(
        id: 'routine-1',
        title: '晨跑',
        minuteOfDay: 7 * 60,
        created: DateTime(2026, 10, 1),
      );
      final occurrences = [
        RoutineOccurrence(routine: rule, at: DateTime(2026, 10, 8, 7, 0)),
      ];
      final view = buildPoolView(
        tasks: tasks,
        now: DateTime(2026, 10, 7, 12, 0),
        routineOccurrences: occurrences,
      );
      expect(view.rows.map((r) => r.runtimeType.toString()),
          ['PoolRoutineRow', 'PoolTaskRow'],
          reason: '10-08 07:00 的例行排在 10-08 18:00 的任务之前');

      final off = buildPoolView(
        tasks: tasks,
        now: DateTime(2026, 10, 7, 12, 0),
        routineOccurrences: occurrences,
        routineShowInPool: false,
      );
      expect(off.rows, hasLength(1));
    });
  });
}

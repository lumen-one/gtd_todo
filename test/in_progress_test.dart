import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gtd_todo/application/task_service.dart';
import 'package:gtd_todo/application/today_view.dart';
import 'package:gtd_todo/domain/event.dart';
import 'package:gtd_todo/domain/schedule.dart';
import 'package:gtd_todo/domain/task.dart';
import 'package:gtd_todo/domain/time_context.dart';
import 'package:gtd_todo/repository/markdown_task_repository.dart';
import 'package:gtd_todo/repository/memory_task_repository.dart';
import 'package:gtd_todo/repository/task_codec.dart';
import 'package:gtd_todo/repository/task_sidecar.dart';
import 'package:gtd_todo/scheduler/slack_priority_scheduler.dart';

/// '挂起进行'（v1.18 / D19 / ui 决议 47）的验收测试：
///
/// - 长期任务（三无、默认'长期'）可『挂起进行』——今日页最顶的**挂起组**顶置呈现，
///   无编号、组内可拖调序；**只有长期任务能挂**（取消不限）；
/// - **多件可挂**：组内按挂起时刻降序（后挂在上）；拖动 = 整段重写时刻；
/// - **保持到完成或主动取消，不按天过期**：`completeTask` 顺手清标记；
/// - 挂起中的任务**不进其余任何组**（含被挑散件）、**任务池两段隐藏**；
/// - **三档调度模式下挂起组都在最顶**——持久意图不是算法排序；
/// - metadata `in_progress` 在两个 codec 都登记：漏登记会让标记在命令自己的
///   重锚里蒸发（v1.7/v1.8 两次"开关蒸发"事故的教训）；
/// - 内核一行不动：长期任务没有截止，本就被 B1/B2 挡在派生之外。
void main() {
  final now = DateTime(2026, 10, 7, 16, 0); // 周三 16:00
  final today1800 = DateTime(2026, 10, 7, 18, 0);

  Task longTask({
    required String id,
    Map<String, String> metadata = const {},
  }) =>
      Task(
        id: id,
        title: id,
        created: now,
        estimatedWork: null, // '长期'：不估工时
        importance: null,
        metadata: metadata,
      );

  // ------------------------------------------------------------------
  // 视图口径：挂起组（buildTodayView / buildPoolView）
  // ------------------------------------------------------------------

  group('今日视图：挂起组', () {
    test('挂起中的任务进挂起组、按时刻降序（后挂在上）', () {
      final view = buildTodayView(
        tasks: [
          longTask(id: 'old', metadata: const {
            'in_progress': '2026-10-07T10:00:00.000',
          }),
          longTask(id: 'new', metadata: const {
            'in_progress': '2026-10-07T15:00:00.000',
          }),
        ],
        schedule: null,
        now: now,
      );
      expect(view.inProgress.map((t) => t.id).toList(), ['new', 'old'],
          reason: '时刻新的在上 = 后挂在上（决议 47）');
      expect(view.isEmpty, isFalse);
    });

    test('挂起中的任务不进其余任何组（含逾期 / 截止型 / 被挑散件）', () {
      final view = buildTodayView(
        tasks: [
          // 挂着又今天到期的截止型件：只进挂起组，不再进截止型组。
          Task(
            id: 'flex-hung',
            title: 'flex-hung',
            deadline: today1800,
            estimatedWork: 60,
            remainingWork: 60,
            importance: 3,
            created: now,
            metadata: const {'in_progress': '2026-10-07T15:00:00.000'},
          ),
          // 挂着又过期的：只进挂起组，不再进逾期组。
          Task(
            id: 'overdue-hung',
            title: 'overdue-hung',
            deadline: DateTime(2026, 10, 6, 18, 0),
            estimatedWork: 60,
            remainingWork: 60,
            importance: 3,
            created: now,
            metadata: const {'in_progress': '2026-10-07T14:00:00.000'},
          ),
          // 挂着又恰好被挑到今天：显示位置是挂起组（ picked 是当日标记，
          // 取消挂起后才回⑤）。
          longTask(id: 'picked-hung', metadata: const {
            'in_progress': '2026-10-07T13:00:00.000',
            'picked_for_today': '2026-10-07',
          }),
        ],
        schedule: null,
        now: now,
      );
      expect(view.inProgress.map((t) => t.id).toList(),
          ['flex-hung', 'overdue-hung', 'picked-hung']);
      expect(view.flex, isEmpty);
      expect(view.overdue, isEmpty);
      expect(view.picked, isNull,
          reason: '挂起优先于被挑：这件不该在⑤再出现一次');
    });

    test('三档调度模式下挂起组都在最顶、顺序一致', () {
      final tasks = [
        longTask(id: 'a', metadata: const {
          'in_progress': '2026-10-07T10:00:00.000',
        }),
        longTask(id: 'b', metadata: const {
          'in_progress': '2026-10-07T11:00:00.000',
        }),
      ];
      for (final mode in ScheduleMode.values) {
        final view = buildTodayView(
          tasks: tasks,
          schedule: null,
          now: now,
          scheduleMode: mode,
        );
        expect(view.inProgress.map((t) => t.id).toList(), ['b', 'a'],
            reason: '挂起组与调度模式无关（$mode）');
      }
    });

    test('任务池两段都隐藏挂起中的任务（与被挑散件同一规则）', () {
      final pool = buildPoolView(
        tasks: [
          longTask(id: 'loose-hung', metadata: const {
            'in_progress': '2026-10-07T15:00:00.000',
          }),
          longTask(id: 'loose-free'),
          // 挂着又带截止的（'转正'后仍占挂位）：计划段也不出现。
          Task(
            id: 'plan-hung',
            title: 'plan-hung',
            deadline: DateTime(2026, 10, 20, 18, 0),
            estimatedWork: 60,
            remainingWork: 60,
            importance: 3,
            created: now,
            metadata: const {'in_progress': '2026-10-07T15:00:00.000'},
          ),
        ],
        now: now,
      );
      expect(pool.loose.map((t) => t.id).toList(), ['loose-free']);
      expect(pool.plan, isEmpty);
    });
  });

  // ------------------------------------------------------------------
  // 命令：setInProgress / setInProgressStack / completeTask 清标记
  // ------------------------------------------------------------------

  group('TaskService：挂起命令', () {
    late MemoryTaskRepository repo;
    late TaskService svc;

    setUp(() {
      repo = MemoryTaskRepository();
      svc = TaskService(
        repo: repo,
        scheduler: const SlackPriorityScheduler(),
        workRule: WorkTimeRule.standard,
        clock: () => now,
      );
    });

    test('长期任务可挂可取消；标记落盘、重启不丢', () async {
      final a = await svc.createTask(title: '学一门外语');
      expect(a.isLongTerm, isTrue);
      expect(a.inProgressAt, isNull);

      await svc.setInProgress(a.id, enabled: true);
      expect(svc.byId(a.id)!.inProgressAt, isNotNull);
      expect((await repo.getTask(a.id))!.inProgressAt, isNotNull);

      await svc.setInProgress(a.id, enabled: false);
      expect(svc.byId(a.id)!.inProgressAt, isNull);
      expect((await repo.getTask(a.id))!.inProgressAt, isNull);
    });

    test('非长期任务拒绝挂起（有截止的事归调度管）', () async {
      final a = await svc.createTask(title: '写周报', deadline: today1800);
      expect(a.isLongTerm, isFalse);
      expectLater(
        svc.setInProgress(a.id, enabled: true),
        throwsArgumentError,
      );
    });

    test('取消不受限："转正"后仍占挂位的也要能取消', () async {
      final a = await svc.createTask(title: '学一门外语');
      await svc.setInProgress(a.id, enabled: true);
      // 转正 = 补截止 + 换具体工时（D18：编辑里显式设）。
      await svc.updateTask(a.id, deadline: today1800, estimatedWorkMinutes: 60);
      expect(svc.byId(a.id)!.isLongTerm, isFalse);
      expect(svc.byId(a.id)!.inProgressAt, isNotNull,
          reason: '转正不清挂起位（决议 47）');

      final cleared = await svc.setInProgress(a.id, enabled: false);
      expect(cleared.inProgressAt, isNull);
    });

    test('完成即清：completeTask 顺手去掉挂起标记', () async {
      final a = await svc.createTask(title: '学一门外语');
      await svc.setInProgress(a.id, enabled: true);

      final done = await svc.completeTask(a.id);
      expect(done.isCompleted, isTrue);
      expect(done.inProgressAt, isNull);
      expect((await repo.getTask(a.id))!.inProgressAt, isNull,
          reason: '落盘的也没有——否则从盘回流后又挂回来了');

      final view = buildTodayView(tasks: svc.tasks, schedule: null, now: now);
      expect(view.inProgress, isEmpty);
    });

    test('setInProgressStack 整段重写：顺序决定谁在最顶', () async {
      final a = await svc.createTask(title: 'a');
      final b = await svc.createTask(title: 'b');
      final c = await svc.createTask(title: 'c');
      await svc.setInProgress(a.id, enabled: true);
      await svc.setInProgress(b.id, enabled: true);
      await svc.setInProgress(c.id, enabled: true);

      // 拖动结果：c 最顶、a 次之、b 沉底。
      await svc.setInProgressStack([c.id, a.id, b.id]);
      final view = buildTodayView(tasks: svc.tasks, schedule: null, now: now);
      expect(view.inProgress.map((t) => t.id).toList(), [c.id, a.id, b.id]);

      // 时刻严格递减 1 毫秒（同毫秒并列会让 sort 落位随机）。
      final times = [c, a, b]
          .map((t) => DateTime.parse(svc.byId(t.id)!.inProgressAt!))
          .toList();
      expect(times[0].compareTo(times[1]) > 0, isTrue);
      expect(times[1].compareTo(times[2]) > 0, isTrue);
      expect(
        times[0].difference(times[1]).inMilliseconds, 1,
        reason: '整段一次落盘，不是 N 次单条写',
      );
    });

    test('setInProgressStack 只重写已挂起的（不在组的 id 忽略）', () async {
      final a = await svc.createTask(title: 'a');
      final b = await svc.createTask(title: 'b');
      await svc.setInProgress(a.id, enabled: true);

      await svc.setInProgressStack([b.id, a.id]); // b 没挂起 → 忽略
      final view = buildTodayView(tasks: svc.tasks, schedule: null, now: now);
      expect(view.inProgress.map((t) => t.id).toList(), [a.id]);
    });

    test('命令发 taskInProgressSet 事件（UI 刷新靠现有事件流）', () async {
      final a = await svc.createTask(title: 'a');
      final seen = <DomainEventType>[];
      final sub = svc.events.listen((e) => seen.add(e.type));

      await svc.setInProgress(a.id, enabled: true);
      await svc.setInProgressStack([a.id]);
      await svc.setInProgress(a.id, enabled: false);
      await Future.delayed(Duration.zero);
      await sub.cancel();

      expect(seen, contains(DomainEventType.taskInProgressSet));
    });
  });

  // ------------------------------------------------------------------
  // 存储：两个 codec 都登记 in_progress（漏登记 = 命令重锚里蒸发）
  // ------------------------------------------------------------------

  group('存储：in_progress 登记与往返', () {
    late Directory tmp;
    late MarkdownTaskRepository repo;
    late TaskService svc;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('gtd_in_progress_test');
      repo = MarkdownTaskRepository(tmp.path);
      svc = TaskService(
        repo: repo,
        scheduler: const SlackPriorityScheduler(),
        workRule: WorkTimeRule.standard,
        clock: () => now,
      );
    });

    tearDown(() {
      try {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    File kernel(String id) => File('${tmp.path}/.gtd/$id.md');

    test('长期任务的 sidecar：id + in_progress，仍没有 work_intensity', () async {
      final t = await svc.createTask(title: '学一门外语');
      await svc.setInProgress(t.id, enabled: true);

      final side = kernel(t.id).readAsStringSync();
      expect(side, contains('id: ${t.id}'));
      expect(side, contains('in_progress: '));
      expect(side, isNot(contains('work_intensity')),
          reason: "长期任务的内核文档仍只有 id 一行 + 登记的 metadata 键（D18）");
    });

    test('重读不蒸发：从盘回流后挂起标记还在', () async {
      final t = await svc.createTask(title: '学一门外语');
      await svc.setInProgress(t.id, enabled: true);

      final reloaded = MarkdownTaskRepository(tmp.path);
      final loaded = (await reloaded.loadAll()).single;
      expect(loaded.id, t.id);
      expect(loaded.inProgressAt, isNotNull);
      expect(loaded.isLongTerm, isTrue);
    });

    test('codec：sidecar 解码认得 in_progress，编码跟随任务对象删行', () {
      const codec = TaskSidecarCodec();
      final raw = '---\nid: task-777\nin_progress: 2026-10-07T15:00:00.000\n---\n';
      final decoded = codec.decode(raw).task;
      expect(decoded.inProgressAt, '2026-10-07T15:00:00.000');

      // 键在 metadata 里消失 → 整行移除（"键消失则行删"）。
      final cleared = decoded.copyWith(metadata: const {});
      final encoded = codec.encode(EncodedTask(task: cleared, originalRaw: raw));
      expect(encoded, isNot(contains('in_progress')));
      expect(encoded, contains('id: task-777'));
    });
  });
}

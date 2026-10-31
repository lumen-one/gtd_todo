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

/// '挂起进行'（v1.18 / D19 / ui 决议 47，决定卡 2026-10-31-suspend-daily-habit）的
/// 验收测试：
///
/// - **只有长期散件能挂**（'长期'且无截止）：加了截止或换了数字工时的件不是散件，
///   命令层清标记、视图与菜单也不再把它当挂起；
/// - **挂起是每天一挂**：`in_progress` = 今天这一挂（组内排序的载体），
///   `in_progress_daily` = 最近一次"今天做过"的日期（每日回挂的凭据）；
/// - **点一下 = 今天做过**：删 `in_progress`、退回原来的家，同一天里重启不跳回来，
///   换一天由 `resumeDailyInProgress` 挂回挂起组最顶；
/// - **多件可挂**：组内按挂起时刻降序（后挂在上）；拖动 = 整段重写时刻；
/// - 挂起中的任务**不进其余任何组**（含被挑散件）、**任务池两段隐藏**；
/// - **两档调度模式下挂起组都在最顶**——每日标记不是算法排序；
/// - metadata `in_progress` / `in_progress_daily` 在两个 codec 都登记：漏登记会让标记
///   在命令自己的重锚里蒸发（v1.7/v1.8 两次"开关蒸发"事故的教训）；
/// - 内核一行不动：长期任务没有截止，本就被 B1/B2 挡在派生之外。
void main() {
  final now = DateTime(2026, 10, 7, 16, 0); // 周三 16:00
  final today1800 = DateTime(2026, 10, 7, 18, 0);
  // 命令组用可变时钟：每日回挂要能把"今天"推到明天（其余组仍用定死的 now）。
  var clockNow = now;

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

    test('挂了又失去资格的件（加了截止）：不当挂起，回它的调度组', () {
      final view = buildTodayView(
        tasks: [
          // 散件转成截止型（今天到期）却还残留着挂起标记：挂起位无效，
          // 它必须回到截止型组——否则两边都不显示它。
          Task(
            id: 'flex-stale',
            title: 'flex-stale',
            deadline: today1800,
            estimatedWork: 60,
            remainingWork: 60,
            importance: 3,
            created: now,
            metadata: const {'in_progress': '2026-10-07T15:00:00.000'},
          ),
          // 同样残留标记的过期件：回逾期组。
          Task(
            id: 'overdue-stale',
            title: 'overdue-stale',
            deadline: DateTime(2026, 10, 6, 18, 0),
            estimatedWork: 60,
            remainingWork: 60,
            importance: 3,
            created: now,
            metadata: const {'in_progress': '2026-10-07T14:00:00.000'},
          ),
          longTask(id: 'still-hung', metadata: const {
            'in_progress': '2026-10-07T13:00:00.000',
          }),
        ],
        schedule: null,
        now: now,
      );
      expect(view.inProgress.map((t) => t.id).toList(), ['still-hung'],
          reason: '只有长期散件才占得了挂起位');
      expect(view.flex.map((t) => t.id).toList(), ['flex-stale']);
      expect(view.overdue.map((t) => t.id).toList(), ['overdue-stale']);
    });

    test('挂着又恰好被挑到今天：显示位置是挂起组，不进 ⑤', () {
      final view = buildTodayView(
        tasks: [
          longTask(id: 'picked-hung', metadata: const {
            'in_progress': '2026-10-07T13:00:00.000',
            'picked_for_today': '2026-10-07',
          }),
        ],
        schedule: null,
        now: now,
      );
      expect(view.inProgress.map((t) => t.id).toList(), ['picked-hung']);
      expect(view.picked, isNull,
          reason: '挂起优先于被挑：这件不该在⑤再出现一次');
    });

    test('两档调度模式下挂起组都在最顶、顺序一致', () {
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

    test('任务池两段都隐藏挂起中的件；残留标记的件照常出现在计划段', () {
      final pool = buildPoolView(
        tasks: [
          longTask(id: 'loose-hung', metadata: const {
            'in_progress': '2026-10-07T15:00:00.000',
          }),
          longTask(id: 'loose-free'),
          // 挂着又带截止的（失去了挂起资格）：它归调度管，计划段照常出现。
          Task(
            id: 'plan-stale',
            title: 'plan-stale',
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
      expect(pool.plan.map((t) => t.id).toList(), ['plan-stale']);
    });
  });

  // ------------------------------------------------------------------
  // 命令：setInProgress / setInProgressStack / completeTask 清标记
  // ------------------------------------------------------------------

  group('TaskService：挂起命令', () {
    late MemoryTaskRepository repo;
    late TaskService svc;

    setUp(() {
      clockNow = now;
      repo = MemoryTaskRepository();
      svc = TaskService(
        repo: repo,
        scheduler: const SlackPriorityScheduler(),
        workRule: WorkTimeRule.standard,
        clock: () => clockNow,
      );
    });

    test('长期散件可挂；今天做过只清今天那一挂，每日标记留着', () async {
      final a = await svc.createTask(title: '学一门外语');
      expect(a.isLongTerm, isTrue);
      expect(a.inProgressAt, isNull);

      final hung = await svc.setInProgress(a.id, enabled: true);
      expect(hung.inProgressAt, isNotNull);
      expect(hung.inProgressDailyDate, '2026-10-07');

      // 点一下 = 今天做过：退出挂起组，但明天还要回挂（标记改成今天）。
      final done = await svc.setInProgress(a.id, enabled: false);
      expect(done.inProgressAt, isNull);
      expect(done.inProgressDailyDate, '2026-10-07');
      expect((await repo.getTask(a.id))!.inProgressAt, isNull,
          reason: '落盘的也清了——否则从盘回流后又挂回来');
      expect(
        buildTodayView(tasks: svc.tasks, schedule: null, now: now).inProgress,
        isEmpty,
      );
    });

    test('非长期散件拒绝挂起（有截止的事归调度管）', () async {
      final a = await svc.createTask(title: '写周报', deadline: today1800);
      expect(a.isLongTerm, isFalse);
      expectLater(
        svc.setInProgress(a.id, enabled: true),
        throwsArgumentError,
      );

      // '长期'但有截止：也不是散件（开始型、只加了日期的截止型都在这一类）。
      final b = await svc.createTask(title: '每年体检');
      await svc.updateTask(b.id, deadline: today1800);
      expect(svc.byId(b.id)!.isLongTerm, isTrue);
      expectLater(
        svc.setInProgress(b.id, enabled: true),
        throwsArgumentError,
      );
    });

    test('失去资格即清：转正（加截止 + 数字工时）把两个标记一起清掉', () async {
      final a = await svc.createTask(title: '学一门外语');
      await svc.setInProgress(a.id, enabled: true);

      final turned = await svc.updateTask(a.id,
          deadline: today1800, estimatedWorkMinutes: 60);
      expect(turned.isLongTerm, isFalse);
      expect(turned.inProgressAt, isNull);
      expect(turned.inProgressDailyDate, isNull,
          reason: '每日回挂也一并退出——这件归调度管了');

      // 视图不再把它当挂起件：它出现在截止型组里。
      final view = buildTodayView(tasks: svc.tasks, schedule: null, now: now);
      expect(view.inProgress, isEmpty);
      expect(view.flex.map((t) => t.id).toList(), [a.id]);
    });

    test('只加截止（仍是\'长期\'）也清挂起位：散件这个身份没了', () async {
      final a = await svc.createTask(title: '每年体检');
      await svc.setInProgress(a.id, enabled: true);

      final dated = await svc.updateTask(a.id, deadline: today1800);
      expect(dated.isLongTerm, isTrue, reason: "工时没动，仍是'长期'");
      expect(dated.inProgressAt, isNull);
      expect(dated.inProgressDailyDate, isNull);
    });

    test('完成即清：completeTask 把两个标记一起去掉', () async {
      final a = await svc.createTask(title: '学一门外语');
      await svc.setInProgress(a.id, enabled: true);

      final done = await svc.completeTask(a.id);
      expect(done.isCompleted, isTrue);
      expect(done.inProgressAt, isNull);
      expect(done.inProgressDailyDate, isNull,
          reason: '完成了就彻底离开每日循环');
      expect((await repo.getTask(a.id))!.inProgressAt, isNull,
          reason: '落盘的也没有——否则从盘回流后又挂回来了');

      final view = buildTodayView(tasks: svc.tasks, schedule: null, now: now);
      expect(view.inProgress, isEmpty);
    });

    test('每日回挂：同一天不跳回来，换一天自动挂上', () async {
      final a = await svc.createTask(title: '练琴');
      await svc.setInProgress(a.id, enabled: true);
      await svc.setInProgress(a.id, enabled: false); // 今天做过

      expect(await svc.resumeDailyInProgress(), 0,
          reason: '同一天里点掉又重启（bootstrap/tick 都会调）不该当天跳回来');

      clockNow = DateTime(2026, 10, 8, 7, 0);
      expect(await svc.resumeDailyInProgress(), 1);
      final back = svc.byId(a.id)!;
      expect(back.inProgressAt, isNotNull);
      expect(back.inProgressDailyDate, '2026-10-08');
      expect(
        buildTodayView(tasks: svc.tasks, schedule: null, now: clockNow)
            .inProgress
            .map((t) => t.id)
            .toList(),
        [a.id],
      );
      expect(await svc.resumeDailyInProgress(), 0, reason: '幂等：已挂上的不再挂');
    });

    test('每日回挂：一批一次落盘，时刻递减 1 毫秒（组内落位确定）', () async {
      final a = await svc.createTask(title: 'a');
      final b = await svc.createTask(title: 'b');
      await svc.setInProgress(a.id, enabled: true);
      await svc.setInProgress(b.id, enabled: true);
      await svc.setInProgress(a.id, enabled: false);
      await svc.setInProgress(b.id, enabled: false);

      clockNow = DateTime(2026, 10, 8, 7, 0);
      expect(await svc.resumeDailyInProgress(), 2);

      final ta = DateTime.parse(svc.byId(a.id)!.inProgressAt!);
      final tb = DateTime.parse(svc.byId(b.id)!.inProgressAt!);
      expect(ta.difference(tb).inMilliseconds, 1,
          reason: '按任务列表顺序递减：先建的在上（同毫秒并列会让 sort 落位随机）');
    });

    test('不再每日挂起：两个标记一起清，第二天也不回挂', () async {
      final a = await svc.createTask(title: '偶尔翻翻的旧项目');
      await svc.setInProgress(a.id, enabled: true);

      final stopped = await svc.stopDailyInProgress(a.id);
      expect(stopped.inProgressAt, isNull);
      expect(stopped.inProgressDailyDate, isNull);

      clockNow = DateTime(2026, 10, 8, 7, 0);
      expect(await svc.resumeDailyInProgress(), 0);
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
  // 存储：两个 codec 都登记 in_progress / in_progress_daily（漏登记 = 命令重锚里蒸发）
  // ------------------------------------------------------------------

  group('存储：挂起标记的登记与往返', () {
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

    test('长期任务的 sidecar：id + 两个挂起键，仍没有 work_intensity', () async {
      final t = await svc.createTask(title: '学一门外语');
      await svc.setInProgress(t.id, enabled: true);

      final side = kernel(t.id).readAsStringSync();
      expect(side, contains('id: ${t.id}'));
      expect(side, contains('in_progress: '));
      expect(side, contains('in_progress_daily: '));
      expect(side, isNot(contains('work_intensity')),
          reason: "长期任务的内核文档仍只有 id 一行 + 登记的 metadata 键（D18）");
    });

    test('重读不蒸发：从盘回流后两个挂起标记都在', () async {
      final t = await svc.createTask(title: '学一门外语');
      await svc.setInProgress(t.id, enabled: true);

      final reloaded = MarkdownTaskRepository(tmp.path);
      final loaded = (await reloaded.loadAll()).single;
      expect(loaded.id, t.id);
      expect(loaded.inProgressAt, isNotNull);
      expect(loaded.inProgressDailyDate, '2026-10-07');
      expect(loaded.isLongTerm, isTrue);
    });

    test('codec：sidecar 解码认得两个挂起键，编码跟随任务对象删行', () {
      const codec = TaskSidecarCodec();
      const raw = '---\nid: task-777\n'
          'in_progress: 2026-10-07T15:00:00.000\n'
          'in_progress_daily: 2026-10-07\n'
          '---\n';
      final decoded = codec.decode(raw).task;
      expect(decoded.inProgressAt, '2026-10-07T15:00:00.000');
      expect(decoded.inProgressDailyDate, '2026-10-07');

      // 键在 metadata 里消失 → 整行移除（"键消失则行删"）。
      final cleared = decoded.copyWith(metadata: const {});
      final encoded = codec.encode(EncodedTask(task: cleared, originalRaw: raw));
      expect(encoded, isNot(contains('in_progress')));
      expect(encoded, contains('id: task-777'));
    });
  });
}

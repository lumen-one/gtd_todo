import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:qixing/application/routine_service.dart';
import 'package:qixing/application/task_service.dart';
import 'package:qixing/application/today_view.dart';
import 'package:qixing/domain/event.dart';
import 'package:qixing/domain/task.dart';
import 'package:qixing/domain/time_context.dart';
import 'package:qixing/repository/markdown_task_repository.dart';
import 'package:qixing/repository/memory_routine_repository.dart';
import 'package:qixing/repository/memory_task_repository.dart';
import 'package:qixing/scheduler/slack_scheduler.dart';

/// 已完成页（ui-interaction.md §6.7）的验收测试：
///
/// - buildCompletedView：今天/昨天/更早三组，组内按完成时刻降序；Obsidian
///   手勾无完成时刻的归『更早』末尾（按创建时间降序垫底）；未完成的不进；
/// - TaskService.reopenTask：撤销一次完成——status 回 active、清 completedAt、
///   remainingWork 回满；长期任务保持缺位；例行实例拒绝；未完成的调它无操作；
/// - 往返：reopen 后人类文档那行回 `- [ ]` 且无『完成 <时刻>』、sidecar 的
///   completed_at 移除（两个 codec 都由 completedAt 驱动，不写行逻辑）。
void main() {
  final now = DateTime(2026, 10, 7, 16, 0); // 周三 16:00

  Task done({
    required String id,
    required DateTime? completedAt,
    DateTime? created,
  }) =>
      Task(
        id: id,
        title: id,
        created: created ?? now,
        estimatedWork: 60,
        remainingWork: 0,
        status: TaskStatus.completed,
        completedAt: completedAt,
      );

  // ------------------------------------------------------------------
  // 视图口径：buildCompletedView（三组 + 组内降序 + 手勾件垫底）
  // ------------------------------------------------------------------

  group('buildCompletedView：三组与组内排序', () {
    test('今天/昨天/更早分组，组内按完成时刻降序', () {
      final view = buildCompletedView(
        tasks: [
          done(id: 't-early', completedAt: DateTime(2026, 10, 7, 9, 0)),
          done(id: 't-late', completedAt: DateTime(2026, 10, 7, 15, 30)),
          done(id: 'y', completedAt: DateTime(2026, 10, 6, 21, 0)),
          done(id: 'e', completedAt: DateTime(2026, 9, 30, 12, 0)),
        ],
        now: now,
      );
      expect(view.today.map((t) => t.id).toList(), ['t-late', 't-early']);
      expect(view.yesterday.map((t) => t.id).toList(), ['y']);
      expect(view.earlier.map((t) => t.id).toList(), ['e']);
      expect(view.isEmpty, isFalse);
    });

    test('手勾无完成时刻：归『更早』末尾，按创建时间降序', () {
      final view = buildCompletedView(
        tasks: [
          done(id: 'stamped',
              completedAt: DateTime(2026, 9, 1, 8, 0),
              created: DateTime(2026, 8, 1)),
          done(id: 'manual-old',
              completedAt: null,
              created: DateTime(2026, 8, 20)),
          done(id: 'manual-new',
              completedAt: null,
              created: DateTime(2026, 9, 20)),
        ],
        now: now,
      );
      expect(view.today, isEmpty);
      expect(view.yesterday, isEmpty);
      // 有时刻的在前；两个手勾件彼此按创建时间新的在前（垫底但不乱序）。
      expect(view.earlier.map((t) => t.id).toList(),
          ['stamped', 'manual-new', 'manual-old'],
          reason: '完成日期属人写的那半边，内核不猜——无时刻的垫底');
    });

    test('未完成的任务不进这一页', () {
      final view = buildCompletedView(
        tasks: [
          Task(
            id: 'live',
            title: 'live',
            created: now,
            estimatedWork: 60,
            remainingWork: 60,
          ),
          done(id: 'done-1', completedAt: DateTime(2026, 10, 7, 10, 0)),
        ],
        now: now,
      );
      expect(view.today.map((t) => t.id).toList(), ['done-1']);
    });

    test('长期任务完成后同样归档（完成态只认 completedAt，D14/D18）', () {
      final view = buildCompletedView(
        tasks: [
          Task(
            id: 'long-done',
            title: 'long-done',
            created: now,
            estimatedWork: null,
            importance: null,
            status: TaskStatus.completed,
            completedAt: DateTime(2026, 10, 7, 14, 0),
          ),
        ],
        now: now,
      );
      expect(view.today.single.id, 'long-done');
    });

    test('跨月边界：昨天的判断按自然日算', () {
      final monthStart = DateTime(2026, 10, 1, 9, 0);
      final view = buildCompletedView(
        tasks: [
          done(id: 'sep30', completedAt: DateTime(2026, 9, 30, 23, 0)),
          done(id: 'oct1', completedAt: DateTime(2026, 10, 1, 8, 0)),
        ],
        now: monthStart,
      );
      expect(view.today.map((t) => t.id).toList(), ['oct1']);
      expect(view.yesterday.map((t) => t.id).toList(), ['sep30']);
      expect(view.earlier, isEmpty);
    });

    test('空态：一个完成的都没有', () {
      final view = buildCompletedView(
        tasks: [
          Task(
            id: 'live',
            title: 'live',
            created: now,
            estimatedWork: 60,
            remainingWork: 60,
          ),
        ],
        now: now,
      );
      expect(view.isEmpty, isTrue);
    });
  });

  // ------------------------------------------------------------------
  // 命令：reopenTask（撤销一次完成）
  // ------------------------------------------------------------------

  group('TaskService.reopenTask：撤销一次完成', () {
    late MemoryTaskRepository repo;
    late TaskService svc;

    setUp(() {
      repo = MemoryTaskRepository();
      svc = TaskService(
        repo: repo,
        scheduler: const SlackScheduler(),
        workRule: WorkTimeRule.standard,
        clock: () => now,
      );
    });

    test('往返：完成 → 恢复，状态/时刻/剩余工作量三项还原', () async {
      final a = await svc.createTask(
          title: '交周报', deadline: DateTime(2026, 10, 7, 18, 0));
      await svc.completeTask(a.id);
      expect(svc.byId(a.id)!.isCompleted, isTrue);

      final back = await svc.reopenTask(a.id);
      expect(back.status, TaskStatus.active);
      expect(back.completedAt, isNull);
      expect(back.isCompleted, isFalse);
      expect(back.remainingWork, back.estimatedWork, reason: '剩余工作量回满');
      expect((await repo.getTask(a.id))!.isCompleted, isFalse,
          reason: '落盘的也还原');
    });

    test('恢复后回到未完成该在的地方：今日清单收它', () async {
      final a = await svc.createTask(
          title: '交周报', deadline: DateTime(2026, 10, 7, 18, 0));
      await svc.completeTask(a.id);
      expect(buildTodayView(tasks: svc.tasks, schedule: null, now: now).flex,
          isEmpty);

      await svc.reopenTask(a.id);
      final view = buildTodayView(tasks: svc.tasks, schedule: null, now: now);
      expect(view.flex.map((t) => t.id), [a.id], reason: '今天到期 → 回今日清单');
    });

    test('长期任务恢复后仍没有工时/优先级（D18）', () async {
      final a = await svc.createTask(title: '学一门外语'); // 三无 → 长期
      await svc.completeTask(a.id);

      final back = await svc.reopenTask(a.id);
      expect(back.isLongTerm, isTrue);
      expect(back.estimatedWork, isNull);
      expect(back.remainingWork, isNull);
      expect(back.importance, isNull);
    });

    test('例行实例拒绝恢复（恢复往日实例会从所有清单里消失）', () async {
      final routines = RoutineService(
        repo: MemoryRoutineRepository(),
        tasks: svc,
        clock: () => now,
      );
      await routines.load();
      final r = await routines.create(title: '晨跑');
      final instanceId = TaskService.routineInstanceId(r.id, '2026-10-07');
      await svc.completeTask(instanceId);
      expect(svc.byId(instanceId)!.isCompleted, isTrue);

      expectLater(svc.reopenTask(instanceId), throwsArgumentError);
    });

    test('没完成的任务调它是无操作（不冲掉已记的工时）', () async {
      // 60 分钟工时记 30： remaining 剩 30、**没干完**（干完即完成是另一条路，
      // 那边走 completeTask 的形状，不归这个命令管）。
      final a = await svc.createTask(
          title: '写论文',
          deadline: DateTime(2026, 10, 9, 18, 0),
          estimatedWorkMinutes: 60);
      await svc.logWork(a.id, minutes: 30);
      expect(svc.byId(a.id)!.isCompleted, isFalse);
      expect(svc.byId(a.id)!.remainingWork, 30);

      final same = await svc.reopenTask(a.id);
      expect(same.remainingWork, 30, reason: '幂等：未完成就不该被"恢复"改动');
    });

    test('命令发 taskReopened 事件（UI 刷新靠现有事件流）', () async {
      final a = await svc.createTask(title: '交周报');
      await svc.completeTask(a.id);
      final seen = <DomainEventType>[];
      final sub = svc.events.listen((e) => seen.add(e.type));

      await svc.reopenTask(a.id);
      await Future.delayed(Duration.zero);
      await sub.cancel();

      expect(seen, contains(DomainEventType.taskReopened));
    });
  });

  // ------------------------------------------------------------------
  // 存储：reopen 后两个文档都还原（codec 由 completedAt 驱动，不写行逻辑）
  // ------------------------------------------------------------------

  group('存储：reopen 往返（人类文档 + sidecar）', () {
    late Directory tmp;
    late MarkdownTaskRepository repo;
    late TaskService svc;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('gtd_completed_test');
      repo = MarkdownTaskRepository(tmp.path);
      svc = TaskService(
        repo: repo,
        scheduler: const SlackScheduler(),
        workRule: WorkTimeRule.standard,
        clock: () => now,
      );
    });

    tearDown(() {
      try {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('人类文档那行回 - [ ] 且无『完成 <时刻>』；sidecar 无 completed_at',
        () async {
      final a = await svc.createTask(
          title: '交房租', deadline: DateTime(2026, 10, 7, 18, 0));
      await svc.completeTask(a.id);

      final md = File('${tmp.path}/tasks.md').readAsStringSync();
      expect(md, contains('- [x]'));
      expect(md, contains('完成'));

      await svc.reopenTask(a.id);

      final md2 = File('${tmp.path}/tasks.md').readAsStringSync();
      expect(md2, contains('- [ ] 交房租'));
      expect(md2, isNot(contains('完成')), reason: '完成章随 completedAt 一起消失');
      final side = File('${tmp.path}/.gtd/${a.id}.md').readAsStringSync();
      expect(side, isNot(contains('completed_at')));
      expect(side, contains('status: active'));

      // 从盘回流：仍是未完成（指纹配对没被"完成"章骗过去）。
      final reloaded = MarkdownTaskRepository(tmp.path);
      final loaded = (await reloaded.loadAll()).single;
      expect(loaded.id, a.id);
      expect(loaded.isCompleted, isFalse);
      expect(loaded.status, TaskStatus.active);
    });
  });
}

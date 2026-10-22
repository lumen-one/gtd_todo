import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gtd_todo/application/task_service.dart';
import 'package:gtd_todo/domain/event.dart';
import 'package:gtd_todo/domain/schedule.dart';
import 'package:gtd_todo/domain/task.dart';
import 'package:gtd_todo/domain/time_context.dart';
import 'package:gtd_todo/repository/memory_task_repository.dart';
import 'package:gtd_todo/scheduler/slack_scheduler.dart';
import 'package:gtd_todo/ui/app_controller.dart';
import 'package:gtd_todo/ui/panels/today_panel.dart';
import 'package:gtd_todo/ui/widgets/panel_dock.dart';
import 'package:gtd_todo/ui/widgets/task_selection.dart';

/// 多选（ui-interaction.md §10#23）的验收测试：
///
/// - 批量命令：一次手势**一个事件 + 一次重算**，同一批共用一个完成时刻，
///   已完成件跳过（不改写人写的完成时刻）；批量删除与撤销走回收站；
/// - 选择模式是 UI 临时态：长按菜单最后一行『多选』进模式，点条目 = 勾选，
///   拖把手消失；『取消』退出。
void main() {
  group('批量命令', () {
    late MemoryTaskRepository repo;
    late TaskService svc;
    final now = DateTime(2026, 10, 7, 16, 0); // 周三 16:00

    setUp(() {
      repo = MemoryTaskRepository();
      svc = TaskService(
        repo: repo,
        scheduler: const SlackScheduler(),
        workRule: WorkTimeRule.standard,
        clock: () => now,
      );
    });

    Future<Task> add(String title) => svc.createTask(
          title: title,
          deadline: DateTime(2026, 10, 8, 18, 0),
          estimatedWorkMinutes: 60,
        );

    test('completeTasks：一个事件、同一完成时刻、已完成的跳过', () async {
      final a = await add('A');
      final b = await add('B');
      final c = await add('C');
      await svc.completeTask(c.id);
      final cStamp = (await repo.getTask(c.id))!.completedAt;

      final events = <DomainEvent>[];
      final sub = svc.events.listen(events.add);
      addTearDown(sub.cancel);

      final done = await svc.completeTasks([a.id, b.id, c.id]);
      await Future<void>.delayed(Duration.zero);

      expect(done.map((t) => t.id), [a.id, b.id], reason: '已完成的 c 不进这批');
      expect(
        events.where((e) => e.type == DomainEventType.taskCompleted).length,
        1,
        reason: '一次手势只发一个事件（逐条发 = 清单一条条闪）',
      );
      final aAfter = (await repo.getTask(a.id))!;
      final bAfter = (await repo.getTask(b.id))!;
      expect(aAfter.status, TaskStatus.completed);
      expect(bAfter.status, TaskStatus.completed);
      expect(aAfter.completedAt, bAfter.completedAt, reason: '同一批共用一个时刻');
      expect((await repo.getTask(c.id))!.completedAt, cStamp,
          reason: '不改写已有完成时刻');
      expect(svc.lastSchedule!.items.any((m) => m.taskId == a.id), isFalse);
    });

    test('deleteTasks → restoreTasks：一批进出回收站，各一个事件', () async {
      final a = await add('A');
      final b = await add('B');
      final c = await add('C');

      final events = <DomainEvent>[];
      final sub = svc.events.listen(events.add);
      addTearDown(sub.cancel);

      await svc.deleteTasks([a.id, b.id]);
      await Future<void>.delayed(Duration.zero);
      expect(svc.byId(a.id), isNull);
      expect(svc.byId(c.id), isNotNull);
      expect((await repo.loadTrash()).length, 2);
      expect(
        events.where((e) => e.type == DomainEventType.taskDeleted).length,
        1,
      );

      await svc.restoreTasks([a.id, b.id]);
      await Future<void>.delayed(Duration.zero);
      expect(svc.byId(a.id), isNotNull, reason: '撤销恢复整批');
      expect(svc.byId(b.id), isNotNull);
      expect((await repo.loadTrash()), isEmpty);
      expect(
        events.where((e) => e.type == DomainEventType.taskRestored).length,
        1,
      );
    });

    test('deleteTasks / completeTasks 收到空列表或陌生 id 时不动', () async {
      final a = await add('A');
      await svc.deleteTasks([]);
      expect(svc.byId(a.id), isNotNull);
      expect(await svc.completeTasks(['不存在的 id']), isEmpty);
      expect(svc.byId(a.id)!.status, isNot(TaskStatus.completed));
    });
  });

  group('选择模式（UI）', () {
    Future<AppController> build(WidgetTester tester) async {
      final tmp = Directory.systemTemp.createTempSync('gtd_selection');
      addTearDown(() {
        try {
          if (tmp.existsSync()) tmp.deleteSync(recursive: true);
        } catch (_) {}
      });
      // 内存仓储：这些用例只验证 UI 与命令的接线，不测落盘（落盘由 service
      // 层那组与 markdown_task_repository_test 覆盖），省掉真实 IO 的等待。
      final repo = MemoryTaskRepository();
      final svc = TaskService(
        repo: repo,
        scheduler: const SlackScheduler(),
        workRule: WorkTimeRule.standard,
      );
      final now = DateTime.now();
      final endOfDay = DateTime(now.year, now.month, now.day, 23, 59);
      await svc.createTask(
        title: '交周报',
        deadline: endOfDay,
        estimatedWorkMinutes: 60,
      );
      await svc.createTask(
        title: '回邮件',
        deadline: endOfDay,
        estimatedWorkMinutes: 30,
      );
      return AppController(service: svc, taskDir: tmp.path);
    }

    /// 菜单有六行（今日页那套）+『多选』：默认 800×600 的测试屏会把
    /// bottom sheet 顶出限高，换成竖屏比例。
    void tallScreen(WidgetTester tester) {
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
    }

    testWidgets('长按菜单最后一行是多选；进模式后点条目 = 勾选、拖把手消失',
        (tester) async {
      tallScreen(tester);
      final controller = await build(tester);
      final selection = TaskSelection();
      addTearDown(selection.dispose);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: TodayPanel(controller: controller, selection: selection),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.drag_handle), findsWidgets, reason: '平时可拖');

      await tester.longPress(find.text('交周报'));
      await tester.pumpAndSettle();
      expect(find.text('多选'), findsOneWidget);
      expect(find.text('完成'), findsOneWidget, reason: '命令行照旧在');

      await tester.tap(find.text('多选'));
      await tester.pumpAndSettle();
      expect(selection.selecting, isTrue);
      expect(selection.count, 1, reason: '长按的那条一并选上');
      expect(find.byIcon(Icons.drag_handle), findsNothing,
          reason: '选择模式下不渲染拖把手');

      await tester.tap(find.text('回邮件'));
      await tester.pumpAndSettle();
      expect(selection.count, 2);
      expect(selection.selectedIds.length, 2);

      await tester.tap(find.text('回邮件'));
      await tester.pumpAndSettle();
      expect(selection.count, 1, reason: '再点一次取消勾选');
    });

    testWidgets('批处理条：完成执行后退出选择模式', (tester) async {
      tallScreen(tester);
      final controller = await build(tester);
      final selection = TaskSelection();
      addTearDown(selection.dispose);

      final ids = [for (final t in controller.tasks) t.id];
      selection.begin(ids.first);
      selection.toggle(ids.last);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Stack(children: [
            SelectionBar(controller: controller, selection: selection),
          ]),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('已选 2'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.check));
      await tester.pumpAndSettle();
      expect(selection.selecting, isFalse, reason: '执行完退出选择模式');
      expect(controller.tasks.where((t) => t.isCompleted).length, 2);
    });

    testWidgets('SelectionBar 的删除：一批进回收站，撤销恢复整批', (tester) async {
      tallScreen(tester);
      final controller = await build(tester);
      final selection = TaskSelection();
      addTearDown(selection.dispose);

      final ids = [for (final t in controller.tasks) t.id];
      selection.begin(ids.first);
      selection.toggle(ids.last);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Stack(children: [
            SelectionBar(controller: controller, selection: selection),
          ]),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle();
      expect(controller.tasks.length, 0);
      await controller.refreshTrash();
      expect(controller.trashTasks.length, 2);

      expect(find.text('已删除 2 件'), findsOneWidget);
      await tester.tap(find.text('撤销'));
      await tester.pumpAndSettle();
      expect(controller.tasks.length, 2, reason: '撤销恢复整批');
    });
  });
}

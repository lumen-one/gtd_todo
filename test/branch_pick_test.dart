import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gtd_todo/application/branch_service.dart';
import 'package:gtd_todo/application/task_service.dart';
import 'package:gtd_todo/domain/branch.dart';
import 'package:gtd_todo/domain/schedule.dart';
import 'package:gtd_todo/domain/time_context.dart';
import 'package:gtd_todo/repository/memory_branch_repository.dart';
import 'package:gtd_todo/repository/memory_task_repository.dart';
import 'package:gtd_todo/scheduler/slack_scheduler.dart';
import 'package:gtd_todo/ui/app_controller.dart';
import 'package:gtd_todo/ui/panels/today_panel.dart';
import 'package:gtd_todo/ui/widgets/task_actions.dart';
import 'package:gtd_todo/ui/widgets/task_selection.dart';

/// 从任务这一侧归堆（panels/branch.md『从任务这一侧归堆』）：长按菜单里的
/// 『归到支线』打开勾选 sheet，一件任务可以同时挂几条线，也能在原地拿出来。
void main() {
  Future<(AppController, TaskService)> build(
    WidgetTester tester, {
    List<Branch> branches = const [],
  }) async {
    final tasks = TaskService(
      repo: MemoryTaskRepository(),
      scheduler: const SlackScheduler(),
      workRule: WorkTimeRule.standard,
      scheduleMode: ScheduleMode.manual,
    );
    final branchService = BranchService(
      repo: MemoryBranchRepository(branches),
      titleOf: (id) => tasks.byId(id)?.title,
    );
    await branchService.load();
    final controller = AppController(
      service: tasks,
      taskDir: '/tmp/tasks',
      branchService: branchService,
    );
    await tester.runAsync(() async {
      await tasks.createTask(title: '收拾房间');
    });
    await controller.updateSettings(
      controller.settings.copyWith(scheduleMode: ScheduleMode.manual),
    );
    return (controller, tasks);
  }

  Future<void> pumpToday(WidgetTester tester, AppController controller) async {
    final selection = TaskSelection();
    addTearDown(selection.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: TodayPanel(controller: controller, selection: selection)),
    ));
    await tester.pumpAndSettle();
  }

  /// 长按散件打开菜单，点『归到支线』。
  Future<void> openSheet(WidgetTester tester) async {
    await tester.longPress(find.text('收拾房间'));
    await tester.pumpAndSettle();
    expect(find.text('归到支线'), findsOneWidget, reason: '长按菜单里有这一条');
    await tester.tap(find.text('归到支线'));
    await tester.pumpAndSettle();
  }

  testWidgets('长按 → 勾一条支线，任务挂上去；再点一下拿出来', (tester) async {
    final (controller, tasks) =
        await build(tester, branches: [Branch(name: '读书')]);
    final id = controller.tasks.firstWhere((t) => t.title == '收拾房间').id;

    await pumpToday(tester, controller);
    await openSheet(tester);

    expect(find.text('读书'), findsOneWidget);
    expect(controller.branches.first.contains(id), isFalse);

    await tester.tap(find.text('读书'));
    await tester.pumpAndSettle();
    expect(controller.branches.first.contains(id), isTrue,
        reason: '勾上就是加进这条线');
    expect(tasks.byId(id), isNotNull, reason: '支线只存引用，任务本身不动');

    // 再点一下：从这条线拿出来。sheet 留着，可以接着勾别的线。
    await tester.tap(find.text('读书'));
    await tester.pumpAndSettle();
    expect(controller.branches.first.contains(id), isFalse);
  });

  testWidgets('一件任务可以同时挂两条线（勾选不是单选）', (tester) async {
    final (controller, _) = await build(
      tester,
      branches: [Branch(name: '读书'), Branch(name: '家务')],
    );
    final id = controller.tasks.firstWhere((t) => t.title == '收拾房间').id;

    await pumpToday(tester, controller);
    await openSheet(tester);

    await tester.tap(find.text('读书'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('家务'));
    await tester.pumpAndSettle();

    expect(controller.branchNamesOf(id), ['读书', '家务']);
  });

  testWidgets('还没有支线：就地新建一条，任务直接进去', (tester) async {
    final (controller, _) = await build(tester);
    final id = controller.tasks.firstWhere((t) => t.title == '收拾房间').id;

    await pumpToday(tester, controller);
    await openSheet(tester);

    expect(find.textContaining('还没有支线'), findsOneWidget);

    await tester.tap(find.text('新建一条支线…'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '读书');
    await tester.tap(find.byTooltip('建这条线'));
    await tester.pumpAndSettle();

    expect(controller.branches.length, 1);
    expect(controller.branches.first.name, '读书');
    expect(controller.branches.first.contains(id), isTrue,
        reason: '建完直接放进去，省掉再勾一次');
  });

  testWidgets('已完成页与例行实例不给这一条', (tester) async {
    final (controller, tasks) =
        await build(tester, branches: [Branch(name: '读书')]);
    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    await tester.pumpAndSettle();
    final context = tester.element(find.byType(Scaffold));
    final task = tasks.byId(controller.tasks.first.id)!;

    Iterable<String> labels(TaskMenuKind kind) => taskMenuEntries(
          context,
          controller,
          task,
          kind,
        ).map((e) => e.$1);

    expect(labels(TaskMenuKind.flex), contains('归到支线'));
    expect(labels(TaskMenuKind.pool), contains('归到支线'));
    expect(labels(TaskMenuKind.loose), contains('归到支线'));
    expect(labels(TaskMenuKind.completed), isNot(contains('归到支线')));
    expect(labels(TaskMenuKind.routine), isNot(contains('归到支线')));
  });
}

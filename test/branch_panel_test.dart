import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qixing/application/branch_service.dart';
import 'package:qixing/application/plan_service.dart';
import 'package:qixing/application/task_service.dart';
import 'package:qixing/domain/branch.dart';
import 'package:qixing/domain/time_context.dart';
import 'package:qixing/repository/memory_branch_repository.dart';
import 'package:qixing/repository/memory_plan_repository.dart';
import 'package:qixing/repository/memory_task_repository.dart';
import 'package:qixing/scheduler/slack_scheduler.dart';
import 'package:qixing/ui/app_controller.dart';
import 'package:qixing/ui/panels/plan_panel.dart';
import 'package:qixing/ui/panels/today_panel.dart';
import 'package:qixing/ui/widgets/task_selection.dart';

/// 支线（§6.12）：入口、卡片渲染、勾完沉底。
void main() {
  final day = DateTime(2026, 10, 22);

  Future<(AppController, TaskService)> makeController(
      {List<Branch> branches = const []}) async {
    final tasks = TaskService(
      repo: MemoryTaskRepository(),
      scheduler: const SlackScheduler(),
      workRule: WorkTimeRule.standard,
      clock: () => DateTime(2026, 10, 22, 9),
    );
    final branchService = BranchService(
      repo: MemoryBranchRepository(branches),
      titleOf: (id) => tasks.byId(id)?.title,
    );
    await branchService.load();
    final controller = AppController(
      service: tasks,
      taskDir: '/tmp/tasks',
      planService: PlanService(repo: MemoryPlanRepository()),
      branchService: branchService,
    );
    return (controller, tasks);
  }

  Future<void> pumpOverlay(WidgetTester tester, AppController c) async {
    c.openBranch();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 320,
          height: 620,
          child: AnimatedBuilder(
            animation: c,
            builder: (context, _) => PlanOverlay(
              controller: c,
              onClose: () {},
              day: day,
              now: DateTime(2026, 10, 22, 22, 30),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('空态：一句引导 + 新建一条就出现空文件夹', (tester) async {
    final (c, _) = await makeController();
    await pumpOverlay(tester, c);

    expect(find.text('还没有支线'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '新建支线'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, '校招');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(c.branches.single.name, '校招');
    expect(find.text('校招'), findsOneWidget);
    expect(find.text('空文件夹'), findsOneWidget);
  });

  testWidgets('行是任务本身：勾一下就完成，划掉的沉到卡片末尾', (tester) async {
    final (c, tasks) = await makeController(branches: [Branch(name: 'A')]);
    final first = await tasks.createTask(title: '第一件');
    final second = await tasks.createTask(title: '第二件');
    await c.addTaskToBranch(0, first.id);
    await c.addTaskToBranch(0, second.id);
    await pumpOverlay(tester, c);

    // 默认收起（§6.12）：卡片头挂着进度，里面的行不摆出来。
    expect(find.text('0/2'), findsOneWidget);
    expect(find.text('第一件'), findsNothing);
    await tester.tap(find.text('A'));
    await tester.pumpAndSettle();

    expect(tester.getTopLeft(find.text('第一件')).dy,
        lessThan(tester.getTopLeft(find.text('第二件')).dy));

    // 点勾 = 完成那个任务（不是给支线记一笔）。
    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();

    expect(tasks.byId(first.id)!.isCompleted, isTrue);
    expect(find.text('1/2'), findsOneWidget);
    // 已完成沉底：第一件跑到第二件下面。
    expect(tester.getTopLeft(find.text('第一件')).dy,
        greaterThan(tester.getTopLeft(find.text('第二件')).dy));
  });

  testWidgets('候选只列清单与池子里的任务，落一条就进支线', (tester) async {
    final (c, tasks) = await makeController(branches: [Branch(name: 'A')]);
    final only = await tasks.createTask(title: '写落地页');
    await pumpOverlay(tester, c);

    // 收起态里没有『添加任务』那一行：先点开卡片头。
    expect(find.text('添加任务'), findsNothing);
    await tester.tap(find.text('A'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加任务'));
    await tester.pumpAndSettle();
    expect(find.text('写落地页'), findsOneWidget);

    await tester.tap(find.text('写落地页'));
    await tester.pumpAndSettle();
    expect(c.branches.single.entries.single.taskId, only.id);
  });

  testWidgets('候选超过框高就在框里自己滚，不撑高卡片', (tester) async {
    final (c, tasks) = await makeController(branches: [Branch(name: 'A')]);
    for (final title in ['一', '二', '三', '四', '五', '六']) {
      await tasks.createTask(title: '任务$title');
    }
    await pumpOverlay(tester, c);
    await tester.tap(find.text('A'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加任务'));
    await tester.pumpAndSettle();

    final box = find.byKey(const ValueKey('branchCandidates'));
    expect(box, findsOneWidget);
    final boxed = tester
        .state<ScrollableState>(
            find.descendant(of: box, matching: find.byType(Scrollable)))
        .position;
    expect(boxed.maxScrollExtent, greaterThan(0));
    final page = tester
        .state<ScrollableState>(
            find.ancestor(of: box, matching: find.byType(Scrollable)).first)
        .position;
    final pageBefore = page.pixels;

    await tester.drag(box, const Offset(0, -120));
    await tester.pumpAndSettle();
    expect(boxed.pixels, greaterThan(0));
    expect(page.pixels, pageBefore);
  });

  testWidgets('今日页日期行右端是支线入口，点了落支线视图', (tester) async {
    final (c, _) = await makeController();
    final selection = TaskSelection();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 320,
          height: 620,
          child: AnimatedBuilder(
            animation: c,
            builder: (context, _) => TodayPanel(
              controller: c,
              selection: selection,
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // 今日清单空着时日期行也在：空态不该把支线的入口吞掉。
    expect(find.byTooltip('支线'), findsOneWidget);
    await tester.tap(find.byTooltip('支线'));
    await tester.pumpAndSettle();

    expect(c.planOpen, isTrue);
    expect(c.arrangeView, ArrangeView.branch);
  });
}

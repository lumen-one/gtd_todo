import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gtd_todo/application/plan_service.dart';
import 'package:gtd_todo/application/task_service.dart';
import 'package:gtd_todo/domain/plan.dart';
import 'package:gtd_todo/domain/time_context.dart';
import 'package:gtd_todo/repository/memory_plan_repository.dart';
import 'package:gtd_todo/repository/memory_task_repository.dart';
import 'package:gtd_todo/scheduler/slack_scheduler.dart';
import 'package:gtd_todo/ui/app_controller.dart';
import 'package:gtd_todo/ui/panel_pages.dart';
import 'package:gtd_todo/ui/panels/plan_panel.dart';
import 'package:gtd_todo/ui/panels/side_panel.dart';
import 'package:gtd_todo/ui/panels/today_panel.dart';

/// 今日编排（§6.11）：下拉进覆盖页、时间轴渲染、添加与拖动。
void main() {
  final day = DateTime(2026, 10, 22);

  AppController makeController({List<DayPlan> plan = const []}) {
    final tasks = TaskService(
      repo: MemoryTaskRepository(),
      scheduler: const SlackScheduler(),
      workRule: WorkTimeRule.standard,
      clock: () => DateTime(2026, 10, 22, 9),
    );
    return AppController(
      service: tasks,
      taskDir: '/tmp/tasks',
      planService: PlanService(repo: MemoryPlanRepository(plan)),
    );
  }

  Future<void> pumpOverlay(WidgetTester tester, AppController c) async {
    // 真实装配里由 SidePanel 监听控制器重建；这里补一层同样的关系。
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 320,
          height: 620,
          child: AnimatedBuilder(
            animation: c,
            builder: (_, __) =>
                PlanOverlay(controller: c, onClose: () {}, day: day),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('时间轴：时刻 + 标题，没有时刻显示 —', (tester) async {
    final c = makeController(plan: [
      DayPlan(day: day, entries: const [
        PlanEntry(title: '晨会', minutesOfDay: 8 * 60 + 30),
        PlanEntry(title: '临时的事'),
      ]),
    ]);
    await c.planService!.load();
    await pumpOverlay(tester, c);

    expect(find.text('08:30'), findsOneWidget);
    expect(find.text('晨会'), findsOneWidget);
    expect(find.text('临时的事'), findsOneWidget);
    expect(find.text('—'), findsOneWidget);
    expect(find.text('2 项'), findsOneWidget);
  });

  testWidgets('添加：末条之后展开输入，回车即落一条', (tester) async {
    final c = makeController();
    await pumpOverlay(tester, c);

    // 空态也有加号，且它就在时间轴末尾
    expect(find.text('今天还没有编排'), findsOneWidget);
    await tester.tap(find.text('添加一项'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '晨会');
    await tester.tap(find.byIcon(Icons.check));
    await tester.pumpAndSettle();

    expect(c.planEntriesFor(day).single.title, '晨会');
    expect(find.text('晨会'), findsOneWidget);
    // 加号留在原位：输入框还在，可以接着写
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('快捷添加：候选来自今日清单与任务池，点一条直接落账', (tester) async {
    final c = makeController();
    await c.createTask(title: '写方案');
    await pumpOverlay(tester, c);

    await tester.tap(find.text('添加一项'));
    await tester.pumpAndSettle();
    expect(find.text('写方案'), findsOneWidget);

    await tester.tap(find.text('写方案'));
    await tester.pumpAndSettle();

    final entry = c.planEntriesFor(day).single;
    expect(entry.title, '写方案');
    expect(entry.minutesOfDay, isNotNull); // 时刻用默认，不是空
    // 只借标题：任务本身没有被改（还在池子里，没被挑、没完成）
    expect(c.service.tasks.single.title, '写方案');
    expect(c.service.tasks.single.isCompleted, isFalse);
    // 落过一条后候选还在（可以连点连排），并标了已排
    expect(find.text('已排'), findsOneWidget);
  });

  testWidgets('快捷添加：输入框里的字用来筛候选', (tester) async {
    final c = makeController();
    await c.createTask(title: '写方案');
    await c.createTask(title: '回邮件');
    await pumpOverlay(tester, c);

    await tester.tap(find.text('添加一项'));
    await tester.pumpAndSettle();
    expect(find.text('写方案'), findsOneWidget);
    expect(find.text('回邮件'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '邮件');
    await tester.pumpAndSettle();
    expect(find.text('写方案'), findsNothing);
    expect(find.text('回邮件'), findsOneWidget);
  });

  testWidgets('窄面板：添加行的输入区不被时刻与两颗图标挤没', (tester) async {
    final c = makeController();
    await pumpOverlay(tester, c); // 320 宽（接近最窄的拖动下限）
    await tester.tap(find.text('添加一项'));
    await tester.pumpAndSettle();

    final width = tester.getSize(find.byType(TextField)).width;
    // 原来两颗图标各 48dp、时刻按钮也松散，320 宽下输入区只有 103dp，窄面板上
    // 提示文字被截成"几…"。图标收到 34、时刻字号降一档后是 141dp——再塞回大
    // 图标就会掉回一百出头，这里守住。
    expect(width, greaterThan(130));
  });

  test('展开面板亮编排：今天有条目、默认页是今日清单', () async {
    final c = makeController(plan: [
      DayPlan(day: day, entries: const [
        PlanEntry(title: '晨会', minutesOfDay: 8 * 60 + 30),
      ]),
    ]);
    await c.planService!.load();

    expect(c.landOnPlanForToday(today: day), isTrue);
    expect(c.planOpen, isTrue);
  });

  test('每次展开亮一次：亮着的时候不再叠，收起后再拉会再亮', () async {
    final c = makeController(plan: [
      DayPlan(day: day, entries: const [
        PlanEntry(title: '晨会', minutesOfDay: 8 * 60 + 30),
      ]),
    ]);
    await c.planService!.load();

    expect(c.landOnPlanForToday(today: day), isTrue);
    // 已经亮着：同一次展开里不再叠一层
    expect(c.landOnPlanForToday(today: day), isFalse);
    // 收起面板（宿主 _closePanel 会关覆盖页）→ 再拉出来又亮
    c.closePlan();
    expect(c.landOnPlanForToday(today: day), isTrue);
  });

  test('展开面板不亮：默认页不是今日清单', () async {
    final c = makeController(plan: [
      DayPlan(day: day, entries: const [
        PlanEntry(title: '晨会', minutesOfDay: 8 * 60 + 30),
      ]),
    ]);
    await c.planService!.load();
    await c.setDefaultPage(PanelPage.pool);

    expect(c.landOnPlanForToday(today: day), isFalse);
    expect(c.planOpen, isFalse);
  });

  test('展开面板不亮：今天没有条目', () async {
    final c = makeController();
    await c.planService!.load();

    expect(c.landOnPlanForToday(today: day), isFalse);
    expect(c.planOpen, isFalse);
  });

  testWidgets('编辑：点条目开面板，改标题后落盘', (tester) async {
    final c = makeController(plan: [
      DayPlan(day: day, entries: const [
        PlanEntry(title: '晨会', minutesOfDay: 8 * 60 + 30),
      ]),
    ]);
    await c.planService!.load();
    await pumpOverlay(tester, c);

    await tester.tap(find.text('晨会'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '晨会（改）');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(c.planEntriesFor(day).single.title, '晨会（改）');
    expect(find.text('晨会（改）'), findsOneWidget);
  });

  testWidgets('拖动：长按整条改顺序（只改行序，不动时刻）', (tester) async {
    final c = makeController(plan: [
      DayPlan(day: day, entries: const [
        PlanEntry(title: '晨会', minutesOfDay: 8 * 60 + 30),
        PlanEntry(title: '评审', minutesOfDay: 9 * 60 + 30),
        PlanEntry(title: '写方案', minutesOfDay: 11 * 60),
      ]),
    ]);
    await c.planService!.load();
    await pumpOverlay(tester, c);

    final from = tester.getCenter(find.text('晨会'));
    final gesture = await tester.startGesture(from);
    await tester.pump(const Duration(milliseconds: 700)); // 长按起拖
    await gesture.moveBy(const Offset(0, 90));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    final titles = [for (final e in c.planEntriesFor(day)) e.title];
    expect(titles.first, isNot('晨会'));
    // 时刻跟着条目走，没有变
    final moved = c.planEntriesFor(day).firstWhere((e) => e.title == '晨会');
    expect(moved.timeText, '08:30');
  });

  testWidgets('今日页到顶再下拉：覆盖页滑下来，返回键/返回按钮收回', (tester) async {
    final c = makeController();
    final pageCtrl = PageController(initialPage: PanelPage.today.index);
    await tester.pumpWidget(MaterialApp(
      home: Center(
        child: SizedBox(
          width: 300,
          height: 620,
          child: SidePanel(
            controller: c,
            pageCtrl: pageCtrl,
            onOpenCalendar: () {},
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(c.planOpen, isFalse);

    await tester.drag(
      find
          .descendant(
            of: find.byType(TodayPanel),
            matching: find.byType(Scrollable),
          )
          .first,
      const Offset(0, 200),
    );
    await tester.pumpAndSettle();

    expect(c.planOpen, isTrue);
    expect(find.text('今日编排'), findsOneWidget);

    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    expect(c.planOpen, isFalse);
  });

  testWidgets('没拉到一截就松手：不进覆盖页', (tester) async {
    final c = makeController();
    final pageCtrl = PageController(initialPage: PanelPage.today.index);
    await tester.pumpWidget(MaterialApp(
      home: Center(
        child: SizedBox(
          width: 300,
          height: 620,
          child: SidePanel(
            controller: c,
            pageCtrl: pageCtrl,
            onOpenCalendar: () {},
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.drag(
      find
          .descendant(
            of: find.byType(TodayPanel),
            matching: find.byType(Scrollable),
          )
          .first,
      const Offset(0, 20),
    );
    await tester.pumpAndSettle();
    expect(c.planOpen, isFalse);
  });
}

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

  Future<void> pumpOverlay(WidgetTester tester, AppController c,
      {double width = 320}) async {
    // 真实装配里由 SidePanel 监听控制器重建；这里补一层同样的关系。
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: width,
          height: 620,
          child: AnimatedBuilder(
            animation: c,
            builder: (context, _) => PlanOverlay(
              controller: c,
              onClose: () {},
              day: day,
              // 固定"现在"：游标位置与默认时刻都不该随跑测试的钟点变。
              now: DateTime(2026, 10, 22, 22, 30),
            ),
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

  testWidgets('时间轴：现在游标落在"第一个还没到的条目"之前', (tester) async {
    final c = makeController(plan: [
      DayPlan(day: day, entries: const [
        PlanEntry(title: '晨会', minutesOfDay: 9 * 60),
        PlanEntry(title: '收尾', minutesOfDay: 23 * 60 + 50),
      ]),
    ]);
    await c.planService!.load();
    await pumpOverlay(tester, c);

    // 现在是 22:30：两条都还在后面？不——09:00 已过、23:50 没到，游标在两者之间。
    expect(find.text('现在'), findsOneWidget);
    final cursorY = tester.getCenter(find.text('现在')).dy;
    expect(cursorY, greaterThan(tester.getCenter(find.text('09:00')).dy));
    expect(cursorY, lessThan(tester.getCenter(find.text('23:50')).dy));
  });

  testWidgets('时间轴滚到底再上滑：覆盖页收回', (tester) async {
    final c = makeController(plan: [
      DayPlan(day: day, entries: const [
        PlanEntry(title: '晨会', minutesOfDay: 9 * 60),
      ]),
    ]);
    await c.planService!.load();
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
    c.openPlan();
    await tester.pumpAndSettle();
    expect(c.planOpen, isTrue);

    // 内容不满一屏也已经在末尾：往上拖就是"末尾之后"。
    await tester.drag(
      find
          .descendant(
            of: find.byType(PlanOverlay),
            matching: find.byType(Scrollable),
          )
          .first,
      const Offset(0, -300),
    );
    await tester.pumpAndSettle();

    expect(c.planOpen, isFalse);
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
    expect(find.text('编排'), findsOneWidget);

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

  // ---- 日期轴（昨天 / 今天 / 明天）----

  testWidgets('左滑到明天：页头跟着走，落账落在明天且默认 09:00', (tester) async {
    final c = makeController();
    await pumpOverlay(tester, c);

    await tester.drag(find.byType(PageView), const Offset(-280, 0));
    await tester.pumpAndSettle();
    expect(find.text('明天还没有编排'), findsOneWidget);

    await tester.tap(find.text('添加一项'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '准备明天的会');
    await tester.tap(find.byIcon(Icons.check));
    await tester.pumpAndSettle();

    final tomorrow = DateTime(2026, 10, 23);
    expect(c.planEntriesFor(tomorrow).single.title, '准备明天的会');
    // 晚上排明天：默认落 09:00，不是"现在"的 22:30
    expect(c.planEntriesFor(tomorrow).single.minutesOfDay, 9 * 60);
    expect(c.planEntriesFor(day), isEmpty);
  });

  testWidgets('点页头标签直接跳页（桌面没有横滑的手感）', (tester) async {
    final c = makeController();
    await pumpOverlay(tester, c);

    expect(find.text('昨天 21'), findsOneWidget);
    expect(find.text('今天 22'), findsOneWidget);
    expect(find.text('明天 23'), findsOneWidget);

    await tester.tap(find.text('明天 23'));
    await tester.pumpAndSettle();
    expect(find.text('明天还没有编排'), findsOneWidget);
  });

  testWidgets('昨天只读：没有添加行，点条目不弹编辑', (tester) async {
    final c = makeController(plan: [
      DayPlan(day: DateTime(2026, 10, 21), entries: const [
        PlanEntry(title: '昨天的会', minutesOfDay: 10 * 60),
      ]),
    ]);
    await c.planService!.load();
    await pumpOverlay(tester, c);

    await tester.drag(find.byType(PageView), const Offset(280, 0));
    await tester.pumpAndSettle();

    expect(find.text('昨天的会'), findsOneWidget);
    expect(find.text('添加一项'), findsNothing);

    await tester.tap(find.text('昨天的会'));
    await tester.pumpAndSettle();
    expect(find.text('保存'), findsNothing);
  });

  testWidgets('新增默认时刻：上一条 + 一小时', (tester) async {
    final c = makeController(plan: [
      DayPlan(day: day, entries: const [
        PlanEntry(title: '晨会', minutesOfDay: 8 * 60 + 30),
      ]),
    ]);
    await c.planService!.load();
    await pumpOverlay(tester, c);

    await tester.tap(find.text('添加一项'));
    await tester.pumpAndSettle();
    // 08:30 + 1h（时刻按钮上显示）
    expect(find.text('09:30'), findsOneWidget);
  });

  testWidgets('窄面板 240dp：页头三段标签与添加行都不溢出', (tester) async {
    final c = makeController(plan: [
      DayPlan(day: day, entries: const [
        PlanEntry(title: '一个很长很长的标题会不会把这一行撑破', minutesOfDay: 8 * 60),
      ]),
    ]);
    await c.planService!.load();
    await pumpOverlay(tester, c, width: 240);

    await tester.tap(find.text('添加一项'));
    await tester.pumpAndSettle();
    // 走到这儿还没炸，就说明页头与添加行在 240dp 下都排得开
    expect(find.text('昨天 21'), findsOneWidget);
  });

  testWidgets('改时刻后整轴归位：最新改的那条按时刻插进去', (tester) async {
    final c = makeController(plan: [
      DayPlan(day: day, entries: const [
        PlanEntry(title: '晨会', minutesOfDay: 8 * 60),
        PlanEntry(title: '评审', minutesOfDay: 10 * 60),
      ]),
    ]);
    await c.planService!.load();
    await pumpOverlay(tester, c);

    // 直接把 B 通过服务挪到 07:00（编辑面板里的时刻选择器在测试里走不通）
    await c.updatePlanEntry(day, 1, const PlanEntry(title: '评审', minutesOfDay: 7 * 60));
    await tester.pumpAndSettle();
    expect([for (final e in c.planEntriesFor(day)) e.title], ['评审', '晨会']);

    final review = tester.getCenter(find.text('评审')).dy;
    expect(review, lessThan(tester.getCenter(find.text('晨会')).dy));
  });
}

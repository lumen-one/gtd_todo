import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gtd_todo/application/plan_service.dart';
import 'package:gtd_todo/application/task_service.dart';
import 'package:gtd_todo/domain/plan.dart';
import 'package:gtd_todo/domain/time_context.dart';
import 'package:gtd_todo/repository/memory_plan_repository.dart';
import 'package:gtd_todo/repository/memory_task_repository.dart';
import 'package:gtd_todo/repository/plan_repository.dart';
import 'package:gtd_todo/scheduler/slack_scheduler.dart';
import 'package:gtd_todo/ui/app_controller.dart';
import 'package:gtd_todo/ui/panel_pages.dart';
import 'package:gtd_todo/ui/panels/plan_panel.dart';
import 'package:gtd_todo/ui/panels/side_panel.dart';
import 'package:gtd_todo/ui/panels/today_panel.dart';

/// 落盘永远不回来的编排仓储：用来验证"顺序不等落盘"。
class _StuckPlanRepository implements PlanRepository {
  _StuckPlanRepository(this._days);

  final List<DayPlan> _days;

  final Completer<void> saved = Completer<void>();

  @override
  List<String> get warnings => const [];

  @override
  Future<List<DayPlan>> loadAll() async => List.of(_days);

  @override
  Future<void> saveAll(List<DayPlan> days) => saved.future;
}

/// 今日编排（§6.11）：下拉进覆盖页、时间轴渲染、添加与拖动。
void main() {
  final day = DateTime(2026, 10, 22);

  AppController makeController(
      {List<DayPlan> plan = const [], PlanRepository? repo}) {
    final tasks = TaskService(
      repo: MemoryTaskRepository(),
      scheduler: const SlackScheduler(),
      workRule: WorkTimeRule.standard,
      clock: () => DateTime(2026, 10, 22, 9),
    );
    return AppController(
      service: tasks,
      taskDir: '/tmp/tasks',
      planService: PlanService(repo: repo ?? MemoryPlanRepository(plan)),
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

  testWidgets('快捷添加：六条候选撑满时在框里自己滚，不带动时间轴', (tester) async {
    final c = makeController();
    for (final title in ['任务一', '任务二', '任务三', '任务四', '任务五', '任务六']) {
      await c.createTask(title: title);
    }
    await pumpOverlay(tester, c);
    await tester.tap(find.text('添加一项'));
    await tester.pumpAndSettle();

    // 六条约 230dp，超过框高上限（176）：框内自己滚，不再把整页撑开。
    final box = find.byKey(const ValueKey('planCandidates'));
    expect(box, findsOneWidget);
    final boxed = tester
        .state<ScrollableState>(
            find.descendant(of: box, matching: find.byType(Scrollable)))
        .position;
    expect(boxed.maxScrollExtent, greaterThan(0));
    final timeline = tester
        .state<ScrollableState>(
            find.ancestor(of: box, matching: find.byType(Scrollable)).first)
        .position;
    final timelineBefore = timeline.pixels;

    // 手指按在候选上拖：滚的是候选框自己，时间轴一寸不动。
    await tester.drag(box, const Offset(0, -120));
    await tester.pumpAndSettle();
    expect(boxed.pixels, greaterThan(0));
    expect(timeline.pixels, timelineBefore);
  });

  // 曾经这里带一个"最多六条"：挂起组排在最前，挂起件一到六件，池子里的任务就再也
  // 进不了候选表——看着像"候选里只有挂起的任务"（panels/plan.md『添加、拖动、编辑』）。
  testWidgets('候选不被挂起件吃满：滚到框底能看到池子里的任务', (tester) async {
    final c = makeController();
    for (var i = 0; i < 7; i++) {
      final t = await c.createTask(title: '挂起的长期任务 $i');
      await c.setInProgress(t.id, enabled: true);
    }
    await c.createTask(title: '写方案');
    await pumpOverlay(tester, c);
    await tester.tap(find.text('添加一项'));
    await tester.pumpAndSettle();

    // 前四条半被挂起件占着，池子那一件在框底。
    expect(find.text('写方案'), findsNothing);
    await tester.drag(
        find.byKey(const ValueKey('planCandidates')), const Offset(0, -240));
    await tester.pumpAndSettle();
    expect(find.text('写方案'), findsOneWidget);
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

  /// 游标（带 GlobalKey 的定位锚）就挂在某一条的 Column 里：拖那一条时它会被
  /// 搬到拖拽代理里重建，两处不能同时挂在树上（重复 GlobalKey 会直接炸）。
  testWidgets('拖动游标所在的那一条不炸（锚点不会重复挂）', (tester) async {
    final c = makeController(plan: [
      DayPlan(day: day, entries: const [
        PlanEntry(title: '晨会', minutesOfDay: 9 * 60),
        PlanEntry(title: '收尾', minutesOfDay: 23 * 60 + 50),
      ]),
    ]);
    await c.planService!.load();
    await pumpOverlay(tester, c);
    // 现在 22:30：游标正好落在"收尾"这一条的前面
    expect(tester.getCenter(find.text('现在')).dy,
        lessThan(tester.getCenter(find.text('收尾')).dy));

    final gesture = await tester.startGesture(tester.getCenter(find.text('收尾')));
    await tester.pump(const Duration(milliseconds: 700));
    await gesture.moveBy(const Offset(0, -40));
    await tester.pump();
    await gesture.moveBy(const Offset(0, -80));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect([for (final e in c.planEntriesFor(day)) e.title], ['收尾', '晨会']);
  });

  /// 落盘是"读整份 → 改一天 → 整份写回"，等它回来才重排的话，松手那一帧会先
  /// 弹回原位、写完再跳到新位——看着就是来回闪两下。
  testWidgets('拖动松手：新序当帧生效，不等落盘', (tester) async {
    final repo = _StuckPlanRepository([
      DayPlan(day: day, entries: const [
        PlanEntry(title: '晨会', minutesOfDay: 8 * 60 + 30),
        PlanEntry(title: '评审', minutesOfDay: 9 * 60 + 30),
        PlanEntry(title: '写方案', minutesOfDay: 11 * 60),
      ]),
    ]);
    final c = makeController(repo: repo);
    await c.planService!.load();
    await pumpOverlay(tester, c);

    final gesture = await tester.startGesture(tester.getCenter(find.text('晨会')));
    await tester.pump(const Duration(milliseconds: 700)); // 长按起拖
    await gesture.moveBy(const Offset(0, 90));
    await tester.pump();
    await gesture.up();
    // 松手 → 代理落回动画跑完（250ms）→ 新序生效；这期间落盘一直没回来
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.getCenter(find.text('晨会')).dy,
        greaterThan(tester.getCenter(find.text('评审')).dy));
    // 控制器的数据还没变（saveAll 卡着）：界面这一份是本地先定住的
    expect(c.planEntriesFor(day).first.title, '晨会');
    expect(repo.saved.isCompleted, isFalse);
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

  testWidgets('打开就落在『现在』：日子一长也不会停在开头', (tester) async {
    // 06:00 起每半小时一条排到 23:30：一屏放不下，"现在 22:30" 落在靠后。
    final c = makeController(plan: [
      DayPlan(day: day, entries: [
        for (var m = 6 * 60; m <= 23 * 60 + 30; m += 30)
          PlanEntry(title: '第 $m 分钟', minutesOfDay: m),
      ]),
    ]);
    await c.planService!.load();
    await pumpOverlay(tester, c);

    final panel = tester.getRect(find.byType(PlanOverlay));
    final cursor = tester.getRect(find.text('现在'));
    expect(cursor.center.dy, greaterThan(panel.top));
    expect(cursor.center.dy, lessThan(panel.bottom));
    // 而且确实滚下去了：第一条（06:00）被推到面板上方。它在预建范围里但已经
    // 不在视口内（offstage），所以按"看不见的"去找。
    final first = tester.getRect(find.text('06:00', skipOffstage: false));
    expect(first.bottom, lessThan(panel.top));
  });

  testWidgets('已过的条目：标题跟时刻一起压淡', (tester) async {
    final c = makeController(plan: [
      DayPlan(day: day, entries: const [
        PlanEntry(title: '已经过去的事', minutesOfDay: 9 * 60),
        PlanEntry(title: '还没到的事', minutesOfDay: 23 * 60 + 50),
      ]),
    ]);
    await c.planService!.load();
    await pumpOverlay(tester, c);

    final pastTime = tester.widget<Text>(find.text('09:00')).style!.color;
    final pastTitle = tester.widget<Text>(find.text('已经过去的事')).style!.color;
    final futureTitle = tester.widget<Text>(find.text('还没到的事')).style!.color;

    // 与时刻列同一个值：整行是一档，不是时刻淡、标题正常
    expect(pastTitle, pastTime);
    expect(pastTitle, isNot(futureTitle));
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

  /// 展开面板那一拍先立编排（`landOnPlanForToday`），覆盖页第一帧就该是全开位。
  ///
  /// 反例是"帧后再亮"：那 200ms 里滑下来的是覆盖页，露着的是它底下的今日清单，
  /// 看着就是先给清单、再切成编排。
  testWidgets('展开即编排：一出来就是全开位，不播进场动画', (tester) async {
    final c = makeController(plan: [
      DayPlan(day: day, entries: const [
        PlanEntry(title: '晨会', minutesOfDay: 8 * 60 + 30),
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
    expect(find.text('编排'), findsNothing);

    expect(c.landOnPlanForToday(today: day), isTrue);
    await tester.pump(); // 只推一帧：还在播动画的话，这一帧覆盖页还在面板顶上

    final panelTop = tester.getRect(find.byType(SidePanel)).top;
    expect(tester.getRect(find.text('编排')).top, greaterThan(panelTop));
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

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gtd_todo/application/mainline_service.dart';
import 'package:gtd_todo/application/task_service.dart';
import 'package:gtd_todo/domain/mainline.dart';
import 'package:gtd_todo/domain/time_context.dart';
import 'package:gtd_todo/repository/memory_mainline_repository.dart';
import 'package:gtd_todo/repository/memory_task_repository.dart';
import 'package:gtd_todo/scheduler/slack_scheduler.dart';
import 'package:gtd_todo/ui/app_controller.dart';
import 'package:gtd_todo/ui/panels/side_panel.dart';

/// 主线入口（ui-interaction.md §6.9）：顶栏第二行 + 覆盖页。
void main() {
  AppController makeController({List<Mainline> prefix = const []}) {
    final tasks = TaskService(
      repo: MemoryTaskRepository(),
      scheduler: const SlackScheduler(),
      workRule: WorkTimeRule.standard,
      clock: () => DateTime(2026, 10, 21, 9),
    );
    return AppController(
      service: tasks,
      taskDir: '/tmp/tasks',
      mainlineService: MainlineService(
        repo: MemoryMainlineRepository(prefix),
        clock: () => DateTime(2026, 10, 21, 9),
      ),
    );
  }

  Future<void> pumpPanel(
    WidgetTester tester,
    AppController controller, {
    double width = 300,
    double height = 620,
  }) async {
    final pageCtrl = PageController();
    await tester.pumpWidget(MaterialApp(
      home: Center(
        child: SizedBox(
          width: width,
          height: height,
          child: SidePanel(
            controller: controller,
            pageCtrl: pageCtrl,
            onOpenCalendar: () {},
            onOpenSettings: () {},
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  Mainline sample() => Mainline(
        id: 'ml-1',
        title: '论文冲刺',
        created: DateTime(2026, 10, 18, 9),
        steps: [
          MainlineStep(
            title: '列提纲',
            done: true,
            doneAt: DateTime(2026, 10, 19, 9),
          ),
          const MainlineStep(title: '写第三章'),
          const MainlineStep(title: '通读一遍'),
        ],
        logs: [
          MainlineLog.range(
            start: DateTime(2026, 10, 19),
            end: DateTime(2026, 10, 21),
            text: '连续三天都在写',
          ),
        ],
      );

  testWidgets('没有主线：顶栏第二行是新建入口，点开是空态', (tester) async {
    final controller = makeController();
    await tester.runAsync(() => controller.mainlineService!.load());
    await pumpPanel(tester, controller);

    expect(find.text('＋ 新建主线'), findsOneWidget);

    await tester.tap(find.text('＋ 新建主线'));
    await tester.pumpAndSettle();
    expect(find.text('还没有主线'), findsOneWidget);
    expect(find.text('新建主线'), findsOneWidget);
  });

  testWidgets('有主线：顶栏显示名字与进度，点开盖住面板显示行为链', (tester) async {
    final controller = makeController(prefix: [sample()]);
    await tester.runAsync(() => controller.mainlineService!.load());
    await pumpPanel(tester, controller);

    // 第二行：名字 + 进度（1/3）
    expect(find.text('论文冲刺'), findsOneWidget);
    expect(find.text('1/3'), findsOneWidget);

    await tester.tap(find.text('论文冲刺'));
    await tester.pumpAndSettle();

    // 覆盖页：自带返回 + 步骤 + 归档入口
    expect(find.byIcon(Icons.arrow_back), findsOneWidget);
    expect(find.text('列提纲'), findsOneWidget);
    expect(find.text('写第三章'), findsOneWidget);
    expect(find.text('通读一遍'), findsOneWidget);
    expect(find.textContaining('已完成的主线'), findsOneWidget);

    // 返回 → 回到原来的四页
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
    expect(find.text('列提纲'), findsNothing);
    expect(find.text('论文冲刺'), findsOneWidget);
  });

  testWidgets('行为链滚到底再上滑：覆盖页收回', (tester) async {
    final controller = makeController(prefix: [sample()]);
    await tester.runAsync(() => controller.mainlineService!.load());
    await pumpPanel(tester, controller);

    await tester.tap(find.text('论文冲刺'));
    await tester.pumpAndSettle();
    expect(controller.mainlineOpen, isTrue);

    // 行为链不满一屏，已经"在底"：往上拖就是末尾之后的那一下。
    await tester.drag(find.byType(ListView).first, const Offset(0, -300));
    await tester.pumpAndSettle();

    expect(controller.mainlineOpen, isFalse);
    expect(find.text('列提纲'), findsNothing);
  });

  testWidgets('覆盖页进出都是滑动：途中在落点上方，退场滑完才摘子树', (tester) async {
    final controller = makeController(prefix: [sample()]);
    await tester.runAsync(() => controller.mainlineService!.load());
    await pumpPanel(tester, controller);

    await tester.tap(find.text('论文冲刺'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    final midTop = tester.getTopLeft(find.text('写第三章')).dy;

    await tester.pumpAndSettle();
    final restTop = tester.getTopLeft(find.text('写第三章')).dy;

    // 整块从面板顶边上方滑下来：半路上还离落点一段距离
    expect(midTop, lessThan(restTop - 40));

    // 退场同一条路：点返回后先滑上去，途中覆盖页仍在树上（编辑态与守卫不能提前撤）
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(find.text('写第三章'), findsOneWidget);
    expect(tester.getTopLeft(find.text('写第三章')).dy, lessThan(restTop - 40));

    // 滑完才摘：覆盖页整块消失，回到底下的四页
    await tester.pumpAndSettle();
    expect(find.text('写第三章'), findsNothing);
    expect(find.text('论文冲刺'), findsOneWidget);
  });

  testWidgets('覆盖页铅笔进编辑态：可加一步、保存后进度跟着变', (tester) async {    final controller = makeController(prefix: [sample()]);
    await tester.runAsync(() => controller.mainlineService!.load());
    await pumpPanel(tester, controller);

    await tester.tap(find.text('论文冲刺'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();

    expect(find.text('编辑主线'), findsOneWidget);
    expect(find.text('添加一步'), findsOneWidget);

    await tester.tap(find.text('添加一步'));
    await tester.pumpAndSettle();
    // 新那一步是空输入框（提示文案 = 第 4 步）
    expect(find.text('第 4 步'), findsOneWidget);

    final field = find.widgetWithText(TextField, '第 4 步');
    await tester.enterText(field, '补附录');
    await tester.tap(find.byIcon(Icons.check));
    await tester.pumpAndSettle();

    final saved = controller.activeMainline!;
    expect(saved.steps.length, 4);
    expect(saved.steps.last.title, '补附录');
    expect(find.text('编辑主线'), findsNothing);
  });

  testWidgets('记录页：按住拖选一段 → 写文字 → 落成日历上的圈', (tester) async {
    final plain = Mainline(
      id: 'ml-2',
      title: '写作',
      created: DateTime(2026, 10, 1, 9),
      steps: const [MainlineStep(title: '开头')],
    );
    final controller = makeController(prefix: [plain]);
    await tester.runAsync(() => controller.mainlineService!.load());
    await pumpPanel(tester, controller);

    await tester.tap(find.text('写作'));
    await tester.pumpAndSettle();
    // 页头 1/2 = 翻到记录（记录页里横滑归日历，翻页只能点它）
    await tester.tap(find.text('1/2'));
    await tester.pumpAndSettle();
    expect(find.text('2026 年 10 月'), findsOneWidget);

    final from = tester.getCenter(find.text('19'));
    final to = tester.getCenter(find.text('21'));
    final gesture = await tester.startGesture(from);
    await tester.pump(const Duration(milliseconds: 30));
    await gesture.moveTo(to);
    await tester.pump(const Duration(milliseconds: 30));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('这一段记点什么'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, '补记三天');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    final logs = controller.activeMainline!.logs;
    expect(logs, hasLength(1));
    expect(logs.single.start, DateTime(2026, 10, 19));
    expect(logs.single.end, DateTime(2026, 10, 21));
    expect(logs.single.text, '补记三天');
    // 圈里就有这段字（不用点开）
    expect(find.text('补记三天'), findsOneWidget);
  });

  testWidgets('记录页下半区向右滑 → 回行为链（日历区域仍归圈日期）', (tester) async {
    final plain = Mainline(
      id: 'ml-3',
      title: '写作',
      created: DateTime(2026, 10, 1, 9),
      steps: const [MainlineStep(title: '开头')],
    );
    final controller = makeController(prefix: [plain]);
    await tester.runAsync(() => controller.mainlineService!.load());
    await pumpPanel(tester, controller);

    await tester.tap(find.text('写作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1/2'));
    await tester.pumpAndSettle();
    expect(find.text('2026 年 10 月'), findsOneWidget);

    // 空提示那块 = 下半区：向右拖 → 回行为链
    await tester.drag(
      find.text('点某一天看当天，或按住拖选一段日期写记录；向右滑回行为链'),
      const Offset(160, 0),
    );
    await tester.pumpAndSettle();
    expect(find.text('开头'), findsOneWidget);
    expect(find.text('2026 年 10 月'), findsNothing);
  });

  testWidgets('记录页：点当天详情里的圈改文字，改的是那一条', (tester) async {
    final now = DateTime.now();
    final mainline = Mainline(
      id: 'ml-5',
      title: '写作',
      created: DateTime(2026, 10, 1, 9),
      steps: const [MainlineStep(title: '开头')],
      logs: [
        MainlineLog.range(
          start: DateTime(now.year, now.month, 11),
          end: DateTime(now.year, now.month, 12),
          text: '这一段在改稿',
        ),
      ],
    );
    final controller = makeController(prefix: [mainline]);
    await tester.runAsync(() => controller.mainlineService!.load());
    await pumpPanel(tester, controller);

    await tester.tap(find.text('写作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1/2'));
    await tester.pumpAndSettle();

    // 点圈里的 11 号 → 下半区列出覆盖这天的圈（格子上那条横条也带同样的文字）
    await tester.tap(find.text('11'));
    await tester.pumpAndSettle();
    expect(find.text('这一段在改稿'), findsWidgets);

    await tester.tap(find.text('这一段在改稿').last);
    await tester.pumpAndSettle();
    expect(find.text('改这一段'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, '改成新的说法');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    final logs = controller.activeMainline!.logs;
    expect(logs, hasLength(1));
    expect(logs.single.text, '改成新的说法');
    expect(logs.single.start, DateTime(now.year, now.month, 11));
  });

  testWidgets('记录页：点月头年月切成月记，写一句落库，再点切回日历', (tester) async {
    final plain = Mainline(
      id: 'ml-4',
      title: '写作',
      created: DateTime(2026, 10, 1, 9),
      steps: const [MainlineStep(title: '开头')],
    );
    final controller = makeController(prefix: [plain]);
    await tester.runAsync(() => controller.mainlineService!.load());
    await pumpPanel(tester, controller);

    await tester.tap(find.text('写作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1/2'));
    await tester.pumpAndSettle();

    // 日历落在哪个月由真实时钟决定，所以期望文本也照它算。
    final now = DateTime.now();
    final monthLabel = '${now.year} 年 ${now.month} 月';

    await tester.tap(find.text(monthLabel));
    await tester.pumpAndSettle();
    expect(find.text('${now.year} 年'), findsOneWidget);
    expect(find.text('记一句'), findsNWidgets(12), reason: '一年十二行，一月都没写');

    await tester.tap(find.text('${now.month} 月'));
    await tester.pumpAndSettle();
    expect(find.text('一个月写一句：这个月在做什么'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, '把第三章写完');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    final note = controller.activeMainline!.monthNoteOf(now.year, now.month);
    expect(note?.text, '把第三章写完');
    expect(find.text('把第三章写完'), findsOneWidget);
    expect(find.text('记一句'), findsNWidgets(11), reason: '写过的那行不再提示');

    // 再点年份 → 切回月历
    await tester.tap(find.text('${now.year} 年'));
    await tester.pumpAndSettle();
    expect(find.text(monthLabel), findsOneWidget);
  });

  testWidgets('窄面板 240dp：顶栏两行与覆盖页都不溢出', (tester) async {
    final controller = makeController(prefix: [sample()]);
    await tester.runAsync(() => controller.mainlineService!.load());
    await pumpPanel(tester, controller, width: 240, height: 480);

    expect(find.text('论文冲刺'), findsOneWidget);
    await tester.tap(find.text('论文冲刺'));
    await tester.pumpAndSettle();
    expect(find.text('写第三章'), findsOneWidget);

    // 切到记录页：日历在 240×480 的剩余高度里也要能画出来
    await tester.tap(find.text('1/2'));
    await tester.pumpAndSettle();
    expect(find.text('2026 年 10 月'), findsOneWidget);
  });
}

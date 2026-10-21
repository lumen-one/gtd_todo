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

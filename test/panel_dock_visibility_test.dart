import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qixing/application/task_service.dart';
import 'package:qixing/domain/time_context.dart';
import 'package:qixing/repository/memory_task_repository.dart';
import 'package:qixing/scheduler/slack_scheduler.dart';
import 'package:qixing/ui/app_controller.dart';
import 'package:qixing/ui/panel_pages.dart';
import 'package:qixing/ui/panels/side_panel.dart';
import 'package:qixing/ui/widgets/panel_dock.dart';
import 'package:qixing/ui/widgets/task_selection.dart';

/// 右下角双钮的两条规矩（docs/panels/README.md『右下角双钮』）：
/// 灵感页不摆；列表上滑藏起来、下滑或滚回顶部才回来。
void main() {
  AppController makeController() => AppController(
        service: TaskService(
          repo: MemoryTaskRepository(),
          scheduler: const SlackScheduler(),
          workRule: WorkTimeRule.standard,
          clock: () => DateTime(2026, 10, 8, 9, 0),
        ),
        taskDir: 'ignored',
      );

  testWidgets('灵感页不摆双钮，翻到今日清单才出现', (tester) async {
    final controller = makeController();
    final pageCtrl = PageController(initialPage: PanelPage.notes.index);
    addTearDown(pageCtrl.dispose);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SidePanel(
          controller: controller,
          pageCtrl: pageCtrl,
          onOpenCalendar: () {},
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(PanelDock), findsNothing, reason: '灵感页不摆双钮');

    pageCtrl.jumpToPage(PanelPage.today.index);
    await tester.pumpAndSettle();
    expect(find.byType(PanelDock), findsOneWidget);
    expect(find.byTooltip('添加待办'), findsOneWidget);
  });

  /// 一条能滚的列表 + 一颗双钮，两者共用同一份藏钮开关。
  Widget harness(ValueNotifier<bool> hidden, AppController controller) =>
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 360,
            height: 640,
            child: Stack(
              children: [
                DockScrollListener(
                  hidden: hidden,
                  child: ListView.builder(
                    itemCount: 80,
                    itemBuilder: (context, i) =>
                        SizedBox(height: 48, child: Text('第 $i 行')),
                  ),
                ),
                PanelDock(
                  controller: controller,
                  selection: TaskSelection(),
                  onOpenCalendar: () {},
                  hidden: hidden,
                ),
              ],
            ),
          ),
        ),
      );

  double dockOpacity(WidgetTester tester) =>
      tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity;

  testWidgets('上滑藏钮，停手也不回来', (tester) async {
    final controller = makeController();
    final hidden = ValueNotifier<bool>(false);
    addTearDown(hidden.dispose);
    await tester.pumpWidget(harness(hidden, controller));
    await tester.pumpAndSettle();
    expect(dockOpacity(tester), 1);

    await tester.drag(find.byType(ListView), const Offset(0, -260));
    await tester.pumpAndSettle();
    expect(hidden.value, isTrue);
    expect(dockOpacity(tester), 0, reason: '上滑之后两颗钮藏起来');
  });

  testWidgets('下滑让它回来', (tester) async {
    final controller = makeController();
    final hidden = ValueNotifier<bool>(false);
    addTearDown(hidden.dispose);
    await tester.pumpWidget(harness(hidden, controller));
    await tester.pumpAndSettle();

    await tester.drag(find.byType(ListView), const Offset(0, -260));
    await tester.pumpAndSettle();
    expect(hidden.value, isTrue);

    await tester.drag(find.byType(ListView), const Offset(0, 120));
    await tester.pumpAndSettle();
    expect(hidden.value, isFalse);
    expect(dockOpacity(tester), 1);
  });

  testWidgets('藏起来的时候点不到', (tester) async {
    final controller = makeController();
    final hidden = ValueNotifier<bool>(false);
    addTearDown(hidden.dispose);
    await tester.pumpWidget(harness(hidden, controller));
    await tester.pumpAndSettle();

    await tester.drag(find.byType(ListView), const Offset(0, -260));
    await tester.pumpAndSettle();
    final gate = tester.widget<IgnorePointer>(find
        .descendant(
            of: find.byType(PanelDock), matching: find.byType(IgnorePointer))
        .first);
    expect(gate.ignoring, isTrue, reason: '透明的钮不能还能点');
  });
}

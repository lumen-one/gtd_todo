import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qixing/application/settings.dart';
import 'package:qixing/application/task_service.dart';
import 'package:qixing/domain/task.dart';
import 'package:qixing/domain/time_context.dart';
import 'package:qixing/repository/memory_task_repository.dart';
import 'package:qixing/scheduler/slack_scheduler.dart';
import 'package:qixing/ui/app_controller.dart';
import 'package:qixing/ui/panel_pages.dart';
import 'package:qixing/ui/shells/android_shell.dart';

/// App 内的入口（ui-interaction.md §6.0 / §9 第 12 条）。
///
/// 侧边栏本体只有系统级悬浮面板那一套：贴屏把手恒开，App 内**没有**自己的一份
/// 把手与滑出面板，也没有右下角那颗『侧边栏』FAB。App 内只剩抽屉一条路——它同时
/// 是悬浮窗被拒时的兜底（§11），落点跟着设置的默认页走。
void main() {
  final now = DateTime(2026, 10, 7, 10, 0);

  Future<AppController> pumpShell(WidgetTester tester,
      {String? defaultPage}) async {
    final svc = TaskService(
      repo: MemoryTaskRepository(),
      scheduler: const SlackScheduler(),
      workRule: WorkTimeRule.standard,
      clock: () => now,
    );
    final controller = AppController(
      service: svc,
      taskDir: 'ignored',
      // guideSeen：否则首次展开会弹引导对话框，干扰后面的断言。
      settingsPort: _MemorySettingsPort(
          AppSettings.defaults.copyWith(guideSeen: true, defaultPage: defaultPage)),
    );
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(controller.bootstrap);
    await tester
        .pumpWidget(MaterialApp(home: AndroidShell(controller: controller)));
    await tester.pumpAndSettle();
    return controller;
  }

  /// 抽屉当前停在哪一页：读 TabBarView 头上那个控制器，比"哪段文字在屏幕上"
  /// 靠谱——TabBarView 会留着相邻页，文字只能证明它在树里。
  int drawerPage(WidgetTester tester) =>
      DefaultTabController.of(tester.element(find.byType(TabBarView))).index;

  testWidgets('设置页没有『侧边栏』FAB（v1.31 撤掉的那颗）', (tester) async {
    await pumpShell(tester);

    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
    expect(scaffold.floatingActionButton, isNull);
    // 面板右下角那对 FAB（日历 / +）是另一回事：按文案排掉，只查入口这颗。
    expect(find.widgetWithText(FloatingActionButton, '侧边栏'), findsNothing);
  });

  testWidgets('抽屉那条路还在：点菜单仍能呼出四页', (tester) async {
    await pumpShell(tester);

    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();

    expect(find.byType(TabBar), findsOneWidget, reason: '抽屉已展开');
  });

  testWidgets('抽屉起手页 = 设置里的默认页（§9 第 12 条）', (tester) async {
    final controller = await pumpShell(tester, defaultPage: 'completed');

    controller.requestOpenPanel();
    await tester.pumpAndSettle();

    expect(drawerPage(tester), PanelPage.completed.index,
        reason: '设成已完成，抽屉就该落在已完成页');
  });

  testWidgets('点通知定位压过默认页：落在目标页', (tester) async {
    final controller = await pumpShell(tester, defaultPage: 'completed');

    final task = await controller.service.createTask(
      title: '交水电费',
      deadline: DateTime(2026, 10, 7, 14, 0),
      type: TaskType.fixed,
    );
    controller.locateTask(task.id);
    await tester.pumpAndSettle();

    expect(drawerPage(tester), PanelPage.today.index,
        reason: '今天的件定位到今日清单，不被默认页（已完成）盖掉');
  });
}

/// 内存版 SettingsPort：测试里不碰磁盘（bootstrap 只用它读一次）。
class _MemorySettingsPort implements SettingsPort {
  AppSettings current;

  _MemorySettingsPort(this.current);

  @override
  Future<AppSettings> load() async => current;

  @override
  Future<void> save(AppSettings settings) async {
    current = settings;
  }
}

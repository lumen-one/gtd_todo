import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gtd_todo/application/settings.dart';
import 'package:gtd_todo/application/task_service.dart';
import 'package:gtd_todo/domain/time_context.dart';
import 'package:gtd_todo/repository/memory_task_repository.dart';
import 'package:gtd_todo/scheduler/slack_scheduler.dart';
import 'package:gtd_todo/ui/app_controller.dart';
import 'package:gtd_todo/ui/shells/android_shell.dart';

/// App 壳的侧边栏入口（ui-interaction.md §6.0，v1.31）。
///
/// 右下角那颗『▏▎ 侧边栏』FAB 撤掉了：同一动作上原本摆着三条路（把手拖出 /
/// 抽屉 / FAB），而它是唯一一颗压在设置页**内容区**上的常驻按钮。留下的两条
/// 各有分工——把手在哪都常驻，抽屉在页面内。这条测试守住"撤掉的那条别回来"。
void main() {
  Future<AppController> pumpShell(WidgetTester tester) async {
    final svc = TaskService(
      repo: MemoryTaskRepository(),
      scheduler: const SlackScheduler(),
      workRule: WorkTimeRule.standard,
      clock: () => DateTime(2026, 10, 7, 10, 0),
    );
    final controller = AppController(
      service: svc,
      taskDir: 'ignored',
      // guideSeen：否则首次展开会弹引导对话框，干扰后面的断言。
      settingsPort: _MemorySettingsPort(
          AppSettings.defaults.copyWith(guideSeen: true)),
    );
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(controller.bootstrap);
    await tester
        .pumpWidget(MaterialApp(home: AndroidShell(controller: controller)));
    await tester.pumpAndSettle();
    return controller;
  }

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

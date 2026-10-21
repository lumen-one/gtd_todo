import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gtd_todo/application/settings.dart';
import 'package:gtd_todo/application/task_service.dart';
import 'package:gtd_todo/domain/time_context.dart';
import 'package:gtd_todo/repository/memory_task_repository.dart';
import 'package:gtd_todo/scheduler/slack_scheduler.dart';
import 'package:gtd_todo/ui/app_controller.dart';
import 'package:gtd_todo/ui/shells/android_shell.dart';

/// 抽屉兜底与系统栏（ui-interaction.md §11 的兜底形态）。
///
/// 抽屉里装的是**它自己的 Scaffold**，`appBar` 槽里塞的是裸 `TabBar`——
/// 那不是 AppBar，没人替它避让状态栏。不包 SafeArea 时四个页名会直接压在
/// 状态栏的时钟与信号栏底下（OPPO 真机反馈：页名与顶部栏重叠）。
void main() {
  /// 状态栏 24dp / 导航栏 16dp（测试视图默认是 0，真机不是）。
  const statusBar = 24.0;
  const navBar = 16.0;

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
      settingsPort: _MemorySettingsPort(
          AppSettings.defaults.copyWith(guideSeen: true)),
    );
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    // 物理像素给（测试视图的 devicePixelRatio 是 3）。
    tester.view.padding = const FakeViewPadding(top: statusBar * 3, bottom: navBar * 3);
    addTearDown(tester.view.resetPadding);
    await tester.runAsync(controller.bootstrap);
    await tester
        .pumpWidget(MaterialApp(home: AndroidShell(controller: controller)));
    await tester.pumpAndSettle();
    return controller;
  }

  Future<void> openDrawer(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    expect(find.byType(TabBar), findsOneWidget, reason: '抽屉已展开');
  }

  testWidgets('抽屉的页名条落在状态栏下面，不与顶部栏重叠', (tester) async {
    await pumpShell(tester);
    await openDrawer(tester);

    final tabs = tester.getRect(find.byType(TabBar));
    expect(tabs.top, greaterThanOrEqualTo(statusBar),
        reason: '页名条（TabBar）不能钻到状态栏底下');
  });

  testWidgets('抽屉内容整块避开上下系统栏', (tester) async {
    await pumpShell(tester);
    await openDrawer(tester);

    // 页内容（今日清单的空态提示）也要在状态栏之下。
    final body = find.descendant(
        of: find.byType(Drawer), matching: find.text('今天没有会响的事'));
    expect(body, findsOneWidget);
    expect(tester.getRect(body).top, greaterThanOrEqualTo(statusBar));

    // 右下角双钮不能压在导航栏上（PanelActions 距底 14dp）。
    final fabs = find.descendant(
        of: find.byType(Drawer), matching: find.byType(FloatingActionButton));
    expect(fabs, findsWidgets);
    expect(tester.getRect(fabs.last).bottom, lessThanOrEqualTo(800 - navBar));
  });

  testWidgets('抽屉底色与页面内容同一个值（不吃 M3 的 surfaceContainerLow）',
      (tester) async {
    await pumpShell(tester);
    await openDrawer(tester);

    // 抽屉底（SafeArea 露出的状态栏那条 + 页名条都压在它上面）与内容区
    // 必须同色，否则中间横着一条色差（v1.31，§8）。
    final drawer = tester.widget<Drawer>(find.byType(Drawer));
    final theme = Theme.of(tester.element(find.byType(Drawer)));
    expect(drawer.backgroundColor, theme.scaffoldBackgroundColor);
  });

  testWidgets('页名条左缘对齐页内容留白（不吃 52dp 起始偏移）', (tester) async {
    await pumpShell(tester);
    await openDrawer(tester);

    // 四页页内容横向留白都是 18dp（today/pool/completed/notes）：
    // 页名左缘落在 18dp，下面日期行才不会显得"缩进对不上"。
    final label = find.descendant(
        of: find.byType(TabBar), matching: find.text('灵感'));
    expect(tester.getRect(label).left, closeTo(18, 1.5));
  });
}

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

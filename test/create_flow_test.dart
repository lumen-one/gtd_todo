import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gtd_todo/application/settings.dart';
import 'package:gtd_todo/application/task_service.dart';
import 'package:gtd_todo/domain/time_context.dart';
import 'package:gtd_todo/repository/memory_task_repository.dart';
import 'package:gtd_todo/scheduler/slack_scheduler.dart';
import 'package:gtd_todo/ui/app_controller.dart';
import 'package:gtd_todo/ui/shells/android_shell.dart';

/// 新建流程（ui-interaction.md §5.1）：**先问什么时候，再填内容**。
///
/// 锁两条边界：『+』不再跳过日期直接落三无（那是它以前 的默认态）；
/// 『不排期』仍能建成长期任务——这条显式入口断了，桌面上就没有
/// 建三无的路（快记只在系统级悬浮把手）。
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
      settingsPort: _MemorySettingsPort(
        AppSettings.defaults.copyWith(guideSeen: true),
      ),
    );
    await tester.binding.setSurfaceSize(const Size(420, 860));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(controller.bootstrap);
    await tester.pumpWidget(
      MaterialApp(home: AndroidShell(controller: controller)),
    );
    await tester.pumpAndSettle();
    return controller;
  }

  /// 打开抽屉 → 点右下角「+」→ 落到日期页。
  ///
  /// 两个宿主各挂一份 [PanelDock]，这里限定抽屉里那一份。
  Future<void> openCreateFlow(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(Drawer),
        matching: find.byIcon(Icons.add),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('点「+」先问什么时候，标题框还没出现', (tester) async {
    await pumpShell(tester);
    await openCreateFlow(tester);

    expect(find.text('什么时候？'), findsOneWidget);
    expect(find.text('标题'), findsNothing, reason: '日期没定之前不问内容');
    expect(find.widgetWithText(ListTile, '今天'), findsOneWidget);
    expect(find.widgetWithText(ListTile, '不排期'), findsOneWidget);
  });

  testWidgets('选『今天』：日期落 18:00，填完标题即建', (tester) async {
    final controller = await pumpShell(tester);
    await openCreateFlow(tester);

    await tester.tap(find.widgetWithText(ListTile, '今天'));
    await tester.pumpAndSettle();

    expect(find.text('标题'), findsOneWidget);
    expect(find.textContaining('截止'), findsOneWidget);
    expect(find.textContaining('18:00'), findsWidgets);

    await tester.enterText(find.byType(TextField).first, '写周报');
    await tester.pumpAndSettle();
    await tester.tap(find.text('✱ 创建'));
    await tester.pumpAndSettle();

    final task = controller.tasks.single;
    expect(task.title, '写周报');
    expect(task.deadline!.hour, 18);
    expect(task.deadline!.day, DateTime.now().day);
    expect(task.isLongTerm, isFalse, reason: '有截止 → 按时长，缺省 30 分钟');
    expect(task.estimatedWork, 30);
  });

  testWidgets('『不排期』建成长期任务：无截止、不估工时', (tester) async {
    final controller = await pumpShell(tester);
    await openCreateFlow(tester);

    await tester.tap(find.widgetWithText(ListTile, '不排期'));
    await tester.pumpAndSettle();

    expect(find.text('不排期（散件）'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, '学一门外语');
    await tester.pumpAndSettle();
    await tester.tap(find.text('✱ 创建'));
    await tester.pumpAndSettle();

    final task = controller.tasks.single;
    expect(task.deadline, isNull);
    expect(task.estimatedWork, isNull);
    expect(task.isLongTerm, isTrue);
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

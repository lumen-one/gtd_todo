import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qixing/application/delivery.dart';
import 'package:qixing/application/settings.dart';
import 'package:qixing/application/shell_capabilities.dart';
import 'package:qixing/application/task_service.dart';
import 'package:qixing/domain/reminder.dart';
import 'package:qixing/domain/schedule.dart';
import 'package:qixing/domain/task.dart';
import 'package:qixing/domain/time_context.dart';
import 'package:qixing/repository/memory_task_repository.dart';
import 'package:qixing/scheduler/slack_scheduler.dart';
import 'package:qixing/ui/app_controller.dart';
import 'package:qixing/ui/panels/completed_panel.dart';
import 'package:qixing/ui/panels/notes_panel.dart';
import 'package:qixing/ui/panels/settings_panel.dart';
import 'package:qixing/ui/panels/side_panel.dart';
import 'package:qixing/ui/panels/today_panel.dart';
import 'package:qixing/ui/shells/desktop_shell.dart';

/// 桌面壳（ui-interaction.md §6.10 / architecture.md §5.1，v1.32）。
///
/// 守三件事：
/// 1. 桌面上摆的是**与安卓同一套**四页面板 + 设置页主体（不再退回单页清单）；
/// 2. 两栏与单栏（窄窗口）两种形态各自成立，窄窗口能从标题栏进设置页；
/// 3. 提醒回流**真的会弹**——旧桌面壳没挂 `ReminderListener`，到点什么都不发生。
void main() {
  const taskId = 'task-1';

  /// 装一次桌面壳。真实文件 IO 不参与（用内存仓库），所以不必包 runAsync，
  /// 但 bootstrap 里的 await 要走真实的微任务，仍用 runAsync 跑一次。
  Future<AppController> pumpShell(
    WidgetTester tester, {
    Size size = const Size(1200, 800),
    String defaultPage = 'today',
    StreamController<ShownNotification>? surface,
  }) async {
    final repo = MemoryTaskRepository();
    final svc = TaskService(
      repo: repo,
      scheduler: const SlackScheduler(),
      workRule: WorkTimeRule.standard,
      clock: () => DateTime(2026, 10, 7, 10, 0),
    );
    final controller = AppController(
      service: svc,
      taskDir: 'ignored',
      settingsPort: _MemorySettingsPort(AppSettings.defaults
          .copyWith(guideSeen: true, defaultPage: defaultPage)),
      // 桌面壳注入的能力表：设置页据此裁掉移动专属项（§9）。
      caps: ShellCapabilities.plainWindow,
      notificationSurface: surface?.stream,
    );

    // MediaQuery 的尺寸取自 FlutterView（3.10 起不再跟 binding.setSurfaceSize
    // 走），所以壳里读到的窗口宽必须用 view.physicalSize 摆——那条分支才有意义。
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.runAsync(() async {
      await repo.save(Task(
        id: taskId,
        title: '写周报',
        deadline: DateTime(2026, 10, 9, 18, 0),
        estimatedWork: 60,
        created: DateTime(2026, 10, 7, 9, 0),
      ));
      await svc.refreshSchedule();
      await controller.bootstrap();
    });

    await tester.pumpWidget(
        MaterialApp(home: DesktopShell(controller: controller)));
    await tester.pumpAndSettle();
    return controller;
  }

  testWidgets('两栏：左侧是四页面板，右侧是设置页主体', (tester) async {
    await pumpShell(tester);

    expect(find.byType(SidePanel), findsOneWidget, reason: '与安卓同一份面板');
    expect(find.byType(SettingsPanel), findsOneWidget, reason: '右栏就是设置页');
    // 默认页是今日清单：任务在左栏里，页名在面板头。
    expect(find.byType(TodayPanel), findsOneWidget);
    expect(find.text('写周报'), findsOneWidget);
    // 桌面不做移动端的进出机制：没有把手、抽屉、遮罩。
    expect(find.byType(Drawer), findsNothing);
  });

  testWidgets('四页都到位（横滑翻页，页序由 PanelPage 定）', (tester) async {
    await pumpShell(tester);
    final pageView = find.byType(PageView).first;

    // 今日清单 → 任务池 → 已完成（灵感在更前面，往回滑一次也能到）。
    await tester.drag(pageView, const Offset(-600, 0));
    await tester.pumpAndSettle();
    await tester.drag(pageView, const Offset(-600, 0));
    await tester.pumpAndSettle();
    expect(find.byType(CompletedPanel), findsOneWidget);

    await tester.drag(pageView, const Offset(600, 0));
    await tester.pumpAndSettle();
    await tester.drag(pageView, const Offset(600, 0));
    await tester.pumpAndSettle();
    expect(find.byType(NotesPanel), findsOneWidget);
  });

  testWidgets('起始页跟设置项的默认页走', (tester) async {
    await pumpShell(tester, defaultPage: 'completed');
    expect(find.byType(CompletedPanel), findsOneWidget);
    expect(find.byType(TodayPanel), findsNothing);
  });

  testWidgets('窄窗口退回单栏，设置页从标题栏进', (tester) async {
    await pumpShell(tester, size: const Size(600, 800));

    expect(find.byType(SidePanel), findsOneWidget);
    expect(find.byType(SettingsPanel), findsNothing, reason: '单栏放不下第二栏');

    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();

    expect(find.byType(SettingsPanel), findsOneWidget);
  });

  testWidgets('提醒到点真的弹出来（旧桌面壳漏了 ReminderListener）', (tester) async {
    final surface = StreamController<ShownNotification>.broadcast();
    addTearDown(surface.close);
    await pumpShell(tester, surface: surface);

    expect(find.text('该做这件事了'), findsNothing);

    surface.add(ShownNotification(
      event: ReminderEvent(
        firedAt: DateTime(2026, 10, 7, 10, 0),
        taskId: taskId,
        schedule: ScheduleResult(
          computedAt: DateTime(2026, 10, 7, 10, 0),
          items: const [],
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('该做这件事了'), findsOneWidget);
    expect(find.text('写周报'), findsWidgets, reason: '弹窗里带着任务名');
  });

  // 编排条目的 id 不是任务，`taskById` 查不到——以前这里直接 return，桌面上那条
  // 提醒凭空消失。现在照草案（title/body）弹一句，没有可以按的动作。
  testWidgets('编排条目的提醒也弹得出来：一句话，没有完成/推迟', (tester) async {
    final surface = StreamController<ShownNotification>.broadcast();
    addTearDown(surface.close);
    await pumpShell(tester, surface: surface);

    const planId = 'plan|2026-10-07|870';
    surface.add(ShownNotification(
      event: ReminderEvent(
        firedAt: DateTime(2026, 10, 7, 14, 30),
        taskId: planId,
        kind: ReminderKind.point,
      ),
      channel: ReminderChannel.silent,
      draft: const ReminderDraft(
        taskId: planId,
        title: '项目评审',
        body: '编排 10-07 14:30',
        channel: ReminderChannel.silent,
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('到点了'), findsOneWidget);
    expect(find.text('项目评审'), findsOneWidget);
    expect(find.text('编排 10-07 14:30'), findsOneWidget);
    expect(find.text('完成'), findsNothing, reason: '能推迟的是任务，编排只排不做');
    expect(find.text('推迟 1 小时'), findsNothing);
  });
}

/// 内存版 SettingsPort：测试里不碰磁盘（bootstrap 只读一次）。
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

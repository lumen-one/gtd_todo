import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gtd_todo/application/task_service.dart';
import 'package:gtd_todo/domain/time_context.dart';
import 'package:gtd_todo/overlay_main.dart';
import 'package:gtd_todo/repository/memory_task_repository.dart';
import 'package:gtd_todo/scheduler/slack_scheduler.dart';
import 'package:gtd_todo/ui/app_controller.dart';

/// 系统级悬浮面板宿主（overlay_main.dart）的契约测试：
/// 展开时渲染同一套 panels；收起/进应用走 `gtd/overlay` 通道。
void main() {
  late List<MethodCall> calls;

  setUp(() {
    calls = [];
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(OverlayBridge.channel, (call) async {
      calls.add(call);
      return true;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(OverlayBridge.channel, null);
  });

  AppController makeController() {
    final svc = TaskService(
      repo: MemoryTaskRepository(),
      scheduler: const SlackScheduler(),
      workRule: WorkTimeRule.standard,
      clock: () => DateTime(2026, 10, 8, 9, 0),
    );
    return AppController(service: svc, taskDir: '/tmp/tasks');
  }

  testWidgets('展开：渲染今日清单面板（与应用内共用同一份 SidePanel）', (tester) async {
    final controller = makeController();
    await tester.pumpWidget(MaterialApp(
      home: OverlayPanelShell(controller: controller, bridge: OverlayBridge()),
    ));
    await tester.pumpAndSettle();

    expect(find.text('今日清单'), findsOneWidget);
    expect(find.text('今天没有会响的事'), findsOneWidget);
  });

  testWidgets('收起：面板消失（只剩原生把手）', (tester) async {
    final controller = makeController();
    await tester.pumpWidget(MaterialApp(
      home: OverlayPanelShell(controller: controller, bridge: OverlayBridge()),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    expect(find.text('今日清单'), findsNothing);
    expect(calls.map((c) => c.method), contains('collapse'));
  });

  testWidgets('顶部齿轮 = 进应用（打开设置页）', (tester) async {
    final controller = makeController();
    await tester.pumpWidget(MaterialApp(
      home: OverlayPanelShell(controller: controller, bridge: OverlayBridge()),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();

    final open = calls.firstWhere((c) => c.method == 'openApp');
    expect((open.arguments as Map)['target'], 'settings');
  });

  test('『编辑规则』在悬浮窗宿主里 = 打开应用并定位到该规则', () async {
    final controller = makeController();
    final bridge = OverlayBridge();
    wireOverlaySettingsNavigation(controller, bridge);

    controller.focusRoutineInSettings('routine-xyz');
    await Future<void>.delayed(Duration.zero);

    final open = calls.firstWhere((c) => c.method == 'openApp');
    expect((open.arguments as Map)['routineId'], 'routine-xyz');
    expect(calls.map((c) => c.method), contains('collapse'));
  });
}

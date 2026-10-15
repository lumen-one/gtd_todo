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

  test('state 广播：解析 expanded/dockedRight/handleCenterY，缺键向后兼容', () async {
    final bridge = OverlayBridge();
    final states = <OverlayWindowState>[];
    final sub = bridge.states.listen(states.add);
    await Future<void>.delayed(Duration.zero);

    void sendState(Map<String, Object?> args) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
        OverlayBridge.channel.name,
        StandardMethodCodec()
            .encodeMethodCall(MethodCall('state', args)),
        (_) {},
      );
    }

    sendState(const {
      'expanded': true,
      'dockedRight': false,
      'handle_center_y': 412.5,
    });
    await Future<void>.delayed(Duration.zero);
    final s = states.single;
    expect(s.expanded, isTrue);
    expect(s.dockedRight, isFalse);
    expect(s.handleCenterY, 412.5);

    // 老版本原生不带这个键 → null → 面板贴顶展开（不炸）
    sendState(const {'expanded': true, 'dockedRight': true});
    await Future<void>.delayed(Duration.zero);
    expect(states.last.handleCenterY, isNull);

    await sub.cancel();
  });

  testWidgets('state 带 handle_center_y：悬浮面板垂直居中于该锚点', (tester) async {
    final controller = makeController();
    // 显式 MediaQuery：几何才确定（默认测试环境带 padding，顶位会漂）
    await tester.pumpWidget(MediaQuery(
      data: const MediaQueryData(size: Size(800, 600)),
      child: MaterialApp(
        home:
            OverlayPanelShell(controller: controller, bridge: OverlayBridge()),
      ),
    ));
    await tester.pumpAndSettle();

    // 初始无锚点：贴顶。文本顶 = 面板顶 8 + 面板头 padding 6 + 12
    // （页名 Text 与 48dp 图标按钮同处 Row，被 crossAxisAlignment.center 居中）
    expect(tester.getTopLeft(find.text('今日清单')).dy, closeTo(26, 1));

    // 模拟原生广播：展开 + 把手中心 Y = 300（800×600 测试屏）
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      OverlayBridge.channel.name,
      const StandardMethodCodec().encodeMethodCall(const MethodCall('state', {
        'expanded': true,
        'dockedRight': true,
        'handle_center_y': 300.0,
      })),
      (_) {},
    );
    await tester.pumpAndSettle();

    // 默认高 ≈ 0.85×(600−16) = 496.4 → 面板顶 ≈ 300−248.2 = 51.8，
    // 文本顶 = 51.8 + 18 ≈ 69.8（比贴顶的 26 低出约 43.8 = 锚点−半高−8）
    expect(tester.getTopLeft(find.text('今日清单')).dy, closeTo(69.8, 4));
  });
}

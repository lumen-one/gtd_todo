import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gtd_todo/application/settings.dart';
import 'package:gtd_todo/application/task_service.dart';
import 'package:gtd_todo/domain/time_context.dart';
import 'package:gtd_todo/overlay_main.dart';
import 'package:gtd_todo/repository/memory_task_repository.dart';
import 'package:gtd_todo/scheduler/slack_scheduler.dart';
import 'package:gtd_todo/ui/app_controller.dart';
import 'package:gtd_todo/ui/panel_pages.dart';
import 'package:gtd_todo/ui/panels/side_panel.dart';

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

  AppController makeController({AppSettings? settings}) {
    final svc = TaskService(
      repo: MemoryTaskRepository(),
      scheduler: const SlackScheduler(),
      workRule: WorkTimeRule.standard,
      clock: () => DateTime(2026, 10, 8, 9, 0),
    );
    return AppController(
      service: svc,
      taskDir: '/tmp/tasks',
      settingsPort: settings == null ? null : _MemorySettingsPort(settings),
    );
  }

  /// 原生 → Dart 的通道消息（state / panelDrag / panelDragEnd 都走这条）。
  void sendOverlayCall(MethodCall call) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      OverlayBridge.channel.name,
      StandardMethodCodec().encodeMethodCall(call),
      (_) {},
    );
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

  testWidgets('收起：点遮罩收起（面板头不再有关闭键，v1.24）', (tester) async {
    final controller = makeController();
    await tester.pumpWidget(MaterialApp(
      home: OverlayPanelShell(controller: controller, bridge: OverlayBridge()),
    ));
    await tester.pumpAndSettle();

    // 面板停右、宽 360（测试屏 800）：左边那一大片是遮罩。
    await tester.tapAt(const Offset(60, 300));
    await tester.pumpAndSettle();

    expect(find.text('今日清单'), findsNothing);
    expect(calls.map((c) => c.method), contains('collapse'));
  });

  testWidgets('默认页面：设置里选了任务池，展开就落在任务池', (tester) async {
    final controller = makeController(
        settings: AppSettings.defaults.copyWith(defaultPage: 'pool'));
    await tester.runAsync(controller.bootstrap);
    await tester.pumpWidget(MaterialApp(
      home: OverlayPanelShell(controller: controller, bridge: OverlayBridge()),
    ));
    await tester.pumpAndSettle();

    expect(find.text('任务池'), findsOneWidget);
    expect(find.text('池干水清'), findsOneWidget);
    expect(find.text('今日清单'), findsNothing);
  });

  testWidgets('默认页面：翻到别的页再收起，重新展开仍回默认页', (tester) async {
    final controller = makeController(
        settings: AppSettings.defaults.copyWith(defaultPage: 'pool'));
    await tester.runAsync(controller.bootstrap);
    await tester.pumpWidget(MaterialApp(
      home: OverlayPanelShell(controller: controller, bridge: OverlayBridge()),
    ));
    await tester.pumpAndSettle();

    // 往右拖 = 上一页（任务池 → 今日清单），临时看一眼别的页。
    await tester.drag(find.byType(PageView), const Offset(400, 0));
    await tester.pumpAndSettle();
    expect(find.text('今日清单'), findsOneWidget);

    // 收起 → 再展开：落在设置里的默认页，而不是上次停的那一页。
    sendOverlayCall(const MethodCall('state', {
      'expanded': false,
      'dockedRight': true,
      'handle_center_y': 300,
    }));
    await tester.pumpAndSettle();
    sendOverlayCall(const MethodCall('state', {
      'expanded': true,
      'dockedRight': true,
      'handle_center_y': 300,
    }));
    await tester.pumpAndSettle();

    expect(find.text('任务池'), findsOneWidget);
  });

  testWidgets('默认页面：设置里改完默认页，跟手拖出的那一路立刻落在新默认页',
      (tester) async {
    // 真机顺序：悬浮窗引擎先按当时的设置建好起手页，用户再去设置里改默认页
    // （主引擎写盘 → 本引擎读到 → 通知）。起手页是 PageController.initialPage，
    // 建完就定死了——不对齐的话，跟手拖出来的那几帧仍是老默认页（今日清单），
    // 要等松手补满广播 expanded 才跳走（2026-10-21 报的就是这个）。
    final controller = makeController();
    await tester.runAsync(controller.bootstrap);
    await tester.pumpWidget(MediaQuery(
      data: const MediaQueryData(size: Size(800, 600)),
      child: MaterialApp(
        home:
            OverlayPanelShell(controller: controller, bridge: OverlayBridge()),
      ),
    ));
    await tester.pumpAndSettle();

    sendOverlayCall(const MethodCall('state', {
      'expanded': false,
      'dockedRight': true,
      'handle_center_y': 300,
    }));
    await tester.pumpAndSettle();

    await controller.setDefaultPage(PanelPage.pool);
    await tester.pumpAndSettle();

    // 只拖到一半、**还没松手**：这时显示的必须是新默认页。
    sendOverlayCall(const MethodCall('panelDrag', {'dx': 180.0}));
    await tester.pumpAndSettle();
    expect(find.text('任务池'), findsOneWidget);
    expect(find.text('今日清单'), findsNothing);

    // 松手补满后仍然是它（不会再跳一次）。
    sendOverlayCall(const MethodCall('panelDragEnd', {'open': true}));
    sendOverlayCall(const MethodCall('state', {
      'expanded': true,
      'dockedRight': true,
      'handle_center_y': 300,
    }));
    await tester.pumpAndSettle();
    expect(find.text('任务池'), findsOneWidget);
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

    // 初始无锚点：贴顶。文本顶 = 面板顶 8 + 面板头 padding 2 + 5
    // （页名 Text 高 24，与 34dp 图标按钮同处 Row，被 crossAxisAlignment.center 居中）
    expect(tester.getTopLeft(find.text('今日清单')).dy, closeTo(15, 1));

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
    // 文本顶 = 51.8 + 2 + 5 = 58.8（比贴顶的 15 低出约 43.8 = 锚点−半高−8）
    expect(tester.getTopLeft(find.text('今日清单')).dy, closeTo(58.8, 1));
  });

  testWidgets('panelDrag：侧边栏跟着手指滑出（露多少跟多少）', (tester) async {
    final controller = makeController();
    await tester.pumpWidget(MediaQuery(
      data: const MediaQueryData(size: Size(800, 600)),
      child: MaterialApp(
        home:
            OverlayPanelShell(controller: controller, bridge: OverlayBridge()),
      ),
    ));
    await tester.pumpAndSettle();

    // 800×600、默认宽 = min(0.8×800, 360) = 360；贴右停靠（6）：
    // 文本 left = 800 − 6 − 360 + 10（面板头左 padding）= 444。
    expect(tester.getTopLeft(find.text('今日清单')).dx, closeTo(444, 1));

    // 原生广播跟手进度：dx = 180 = 半个面板宽 → 右缘不动、左缘内收 180。
    sendOverlayCall(const MethodCall('panelDrag', {'dx': 180.0}));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('今日清单')).dx, closeTo(624, 1));

    // dx 超过面板宽 → 夹到全展开（拖不滑出头）。
    sendOverlayCall(const MethodCall('panelDrag', {'dx': 999.0}));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('今日清单')).dx, closeTo(444, 1));
  });

  testWidgets('panelDragEnd{open=false}：滑回屏外后才收起（调 collapse 摘窗口）',
      (tester) async {
    final controller = makeController();
    await tester.pumpWidget(MediaQuery(
      data: const MediaQueryData(size: Size(800, 600)),
      child: MaterialApp(
        home:
            OverlayPanelShell(controller: controller, bridge: OverlayBridge()),
      ),
    ));
    await tester.pumpAndSettle();

    sendOverlayCall(const MethodCall('panelDrag', {'dx': 180.0}));
    await tester.pumpAndSettle();
    sendOverlayCall(const MethodCall('panelDragEnd', {'open': false}));
    await tester.pumpAndSettle();

    // 滑回动画播完才让原生摘窗口（不是一松手就闪退）。
    expect(calls.map((c) => c.method), contains('collapse'));

    // 原生补广播收起 → 面板彻底消失（只剩原生把手）。
    sendOverlayCall(const MethodCall('state', {
      'expanded': false,
      'dockedRight': true,
    }));
    await tester.pumpAndSettle();
    expect(find.text('今日清单'), findsNothing);
  });

  testWidgets('panelDragEnd{open=true}：补满到全展开，不走收起', (tester) async {
    final controller = makeController();
    await tester.pumpWidget(MediaQuery(
      data: const MediaQueryData(size: Size(800, 600)),
      child: MaterialApp(
        home:
            OverlayPanelShell(controller: controller, bridge: OverlayBridge()),
      ),
    ));
    await tester.pumpAndSettle();

    sendOverlayCall(const MethodCall('panelDrag', {'dx': 180.0}));
    await tester.pumpAndSettle();
    sendOverlayCall(const MethodCall('panelDragEnd', {'open': true}));
    await tester.pumpAndSettle();

    // 补满后停在展开位，且没有顺手收起。
    expect(tester.getTopLeft(find.text('今日清单')).dx, closeTo(444, 1));
    expect(calls.map((c) => c.method), isNot(contains('collapse')));
  });

  testWidgets('尺寸固定后拖面板内把手：过半即缩回（走 collapse 摘窗口）',
      (tester) async {
    final controller = makeController(
        settings: AppSettings.defaults.copyWith(panelSizeLocked: true));
    await tester.runAsync(controller.bootstrap);
    await tester.pumpWidget(MediaQuery(
      data: const MediaQueryData(size: Size(800, 600)),
      child: MaterialApp(
        home:
            OverlayPanelShell(controller: controller, bridge: OverlayBridge()),
      ),
    ));
    await tester.pumpAndSettle();

    // 全展开位：贴右停靠（6）、面板宽 360 → 页名 left = 800 − 6 − 360 + 10。
    expect(tester.getTopLeft(find.text('今日清单')).dx, closeTo(444, 1));

    final grip = find.byWidgetPredicate(
        (w) => w is SizedBox && w.width == 12 && w.height == null);
    // 朝屏外（右）推 300dp：扣掉触摸 slop 也远过面板宽的一半（180dp）。
    await tester.drag(grip, const Offset(300, 0));
    await tester.pumpAndSettle();

    // 过半 → 走"滑回"那条路，动画播完才让原生摘窗口（与上面 panelDragEnd
    // 那条同一条路）。
    expect(calls.map((c) => c.method), contains('collapse'));
  });

  testWidgets('尺寸固定后拖面板内把手：没过半则补满回展开位', (tester) async {
    final controller = makeController(
        settings: AppSettings.defaults.copyWith(panelSizeLocked: true));
    await tester.runAsync(controller.bootstrap);
    await tester.pumpWidget(MediaQuery(
      data: const MediaQueryData(size: Size(800, 600)),
      child: MaterialApp(
        home:
            OverlayPanelShell(controller: controller, bridge: OverlayBridge()),
      ),
    ));
    await tester.pumpAndSettle();

    final grip = find.byWidgetPredicate(
        (w) => w is SizedBox && w.width == 12 && w.height == null);
    await tester.drag(grip, const Offset(40, 0));
    await tester.pumpAndSettle();

    expect(tester.getTopLeft(find.text('今日清单')).dx, closeTo(444, 1));
    expect(calls.map((c) => c.method), isNot(contains('collapse')));
  });

  testWidgets('窄面板（240dp 下限）：四个页名都不被省略号截断', (tester) async {
    final controller = makeController();
    final pageCtrl = PageController();
    // 用 SizedBox 卡宽而不是外层 MediaQuery：WidgetsApp 会按视图尺寸重建
    // MediaQuery，外层 size 会被覆盖（实测面板仍是默认测试屏 800×600）。
    await tester.pumpWidget(MaterialApp(
      home: Center(
        child: SizedBox(
          width: 240,
          height: 600,
          child: SidePanel(
            controller: controller,
            pageCtrl: pageCtrl,
            onOpenCalendar: () {},
            // 与悬浮窗宿主一致：面板头有且只有一颗图标（右端『设置』）。
            onOpenSettings: () {},
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // 面板头可用宽 = 240 − 14（左右 padding）− 34（1×34dp 图标）= 192dp。
    // 修复前（v1.24 之前有三颗图标，且 Flexible 与 Spacer 对半劈）页名只拿
    // 62dp——页名全被截成 "任…"（2026-10-16 真机截图复现）。v1.24 撤掉两颗
    // 图标之后，这里留着的意义是防回归：页名与右侧图标之间的空间只能由
    // Flexible 吃，不能再引入第二个 flex:1 的子元素。
    const names = ['灵感', '今日清单', '任务池', '已完成'];
    for (var i = 0; i < names.length; i++) {
      pageCtrl.jumpToPage(i);
      await tester.pumpAndSettle();
      // 不截断 ⟺ 渲染宽度 = 内容固有宽度；被省略号截断时会填满约束
      // （修复前对半的 62.0，与固有宽度 48.45–64.6 对不上）。
      final w = tester.getSize(find.text(names[i])).width;
      final style = Theme.of(tester.element(find.text(names[i])))
          .textTheme
          .titleMedium!;
      final tp = TextPainter(textDirection: TextDirection.ltr)
        ..text = TextSpan(text: names[i], style: style);
      tp.layout();
      expect(w, closeTo(tp.width, 0.5));
      tp.dispose();
    }
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

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gtd_todo/application/settings.dart';
import 'package:gtd_todo/application/task_service.dart';
import 'package:gtd_todo/domain/time_context.dart';
import 'package:gtd_todo/repository/memory_task_repository.dart';
import 'package:gtd_todo/scheduler/slack_scheduler.dart';
import 'package:gtd_todo/ui/app_controller.dart';
import 'package:gtd_todo/ui/panels/side_panel.dart';

/// ResizablePanel（ui/panels/side_panel.dart）契约测试：默认尺寸公式、
/// 垂直居中于把手锚点（触边夹紧）、拖底边把手改高并落盘；末了一组是
/// **尺寸固定**后的把手换岗（§6.0 / §9 第 11 条）。
///
/// 宿主姿势照应用内壳复刻：Stack + Positioned(top: 8, left: 6)——面板自己在
/// 可用区里 Padding 到锚点位，宿主的 top 就是可用区顶（`padding.top + 8`）。
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

/// 800×600、无安全区：可用区 = [8, 592]；默认宽 = min(0.8×800, 360) = 360，
/// 默认高 = 0.85 × (600 − 16) ≈ 496.4。
Widget host(
  AppController controller, {
  double? anchorCenterY,
  ValueChanged<double>? onCollapsePull,
  ValueChanged<bool>? onCollapseRelease,
}) {
  return MediaQuery(
    data: const MediaQueryData(size: Size(800, 600)),
    child: MaterialApp(
      home: Stack(
        children: [
          Positioned(
            top: 8,
            left: 6,
            child: ResizablePanel(
              controller: controller,
              dockLeft: false,
              anchorCenterY: anchorCenterY,
              onCollapsePull: onCollapsePull,
              onCollapseRelease: onCollapseRelease,
              child: const SizedBox.expand(key: Key('panel-content')),
            ),
          ),
        ],
      ),
    ),
  );
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

Offset contentTopLeft(WidgetTester tester) =>
    tester.getTopLeft(find.byKey(const Key('panel-content')));

Size contentSize(WidgetTester tester) =>
    tester.getSize(find.byKey(const Key('panel-content')));

void main() {
  testWidgets('无锚点（悬浮窗姿势）：贴可用区顶，默认宽高走公式', (tester) async {
    final controller = makeController();
    await tester.pumpWidget(host(controller));
    await tester.pumpAndSettle();

    expect(contentTopLeft(tester).dy, 8);
    expect(contentSize(tester).width, closeTo(360, 0.01));
    expect(contentSize(tester).height, closeTo(496.4, 0.01));
  });

  testWidgets('有锚点：面板垂直居中于锚点', (tester) async {
    final controller = makeController();
    await tester.pumpWidget(host(controller, anchorCenterY: 300));
    await tester.pumpAndSettle();

    // 300 − 496.4/2 ≈ 51.8，不触边
    expect(contentTopLeft(tester).dy, closeTo(51.8, 0.01));
  });

  testWidgets('锚点过高/过低：夹紧在可用区内', (tester) async {
    final high = makeController();
    await tester.pumpWidget(host(high, anchorCenterY: 10));
    await tester.pumpAndSettle();
    expect(contentTopLeft(tester).dy, 8); // 顶边夹紧

    final low = makeController();
    await tester.pumpWidget(host(low, anchorCenterY: 590));
    await tester.pumpAndSettle();
    expect(contentTopLeft(tester).dy, closeTo(95.6, 0.01)); // 底边夹紧
  });

  testWidgets('拖底边把手：高度实时变、围绕锚点重居中、松手落盘', (tester) async {
    final controller = makeController();
    await tester.pumpWidget(host(controller, anchorCenterY: 300));
    await tester.pumpAndSettle();

    // 底边横条把手 = 那条 12dp 高的手势区
    final edge = find.byWidgetPredicate((w) => w is SizedBox && w.height == 12);
    expect(edge, findsOneWidget);

    final before = contentSize(tester).height;
    await tester.drag(edge, const Offset(0, -100));
    await tester.pump();

    // 实时变高/变矮（容忍 slop 级差），且不低于下限
    final after = contentSize(tester).height;
    expect(after, closeTo(before - 100, 20));
    expect(after, greaterThanOrEqualTo(320));
    // 重居中：顶边 = 锚点 − 新高/2
    expect(contentTopLeft(tester).dy, closeTo(300 - after / 2, 0.01));

    await tester.pumpAndSettle();
    // 松手落盘的值 = 渲染值（不闪回、不写丢）
    expect(controller.settings.panelHeight, closeTo(after, 0.01));
  });

  group('尺寸固定（§6.0 / §9 第 11 条）', () {
    /// 竖把手（12dp 宽那条；固定后它改管收起）
    Finder verticalGrip() =>
        find.byWidgetPredicate((w) => w is SizedBox && w.width == 12);

    /// 底边横把手（12dp 高那条；固定后不渲染）
    Finder bottomGrip() =>
        find.byWidgetPredicate((w) => w is SizedBox && w.height == 12);

    test('缺省不锁；panel_size_locked 往返，缺键回默认', () {
      expect(AppSettings.defaults.panelSizeLocked, false);
      expect(decodeSettings('{}').panelSizeLocked, false,
          reason: '老设置文件没有这个键');

      final locked = AppSettings.defaults.copyWith(
          panelSizeLocked: true, panelWidth: 300, panelHeight: 420);
      final back = decodeSettings(encodeSettings(locked));
      expect(back.panelSizeLocked, true);
      // 冻结的宽高跟开关落在同一个文件里——固定 = 开关 + 数值一起
      expect(back.panelWidth, 300);
      expect(back.panelHeight, 420);
    });

    test('lockPanelSize 冻住当前宽高；unlockPanelSize 只清开关、数值留着',
        () async {
      final c = makeController();
      await c.lockPanelSize(width: 300, height: 420);
      expect(c.settings.panelSizeLocked, true);
      expect(c.settings.panelWidth, 300);
      expect(c.settings.panelHeight, 420);

      await c.unlockPanelSize();
      expect(c.settings.panelSizeLocked, false);
      expect(c.settings.panelWidth, 300, reason: '解锁后还能从冻住的尺寸接着拖');
    });

    testWidgets('固定后：底边把手撤掉，内侧竖条留在原位', (tester) async {
      final controller = makeController(
          settings: AppSettings.defaults.copyWith(panelSizeLocked: true));
      await tester.runAsync(controller.bootstrap);
      await tester.pumpWidget(host(controller));
      await tester.pumpAndSettle();

      // 改高那条（12dp 高的横条）随固定一起没了
      expect(bottomGrip(), findsNothing);
      // 改宽那条（12dp 宽的竖条）位置不动，只是换了职能
      expect(verticalGrip(), findsOneWidget);
    });

    testWidgets('固定后拖竖把手：过半判缩回，没过半判回弹', (tester) async {
      final pulls = <double>[];
      final releases = <bool>[];
      final controller = makeController(
          settings: AppSettings.defaults.copyWith(panelSizeLocked: true));
      await tester.runAsync(controller.bootstrap);
      await tester.pumpWidget(host(controller,
          onCollapsePull: pulls.add, onCollapseRelease: releases.add));
      await tester.pumpAndSettle();

      // 停右（dockLeft=false）→ 往右推 = 朝屏外。面板宽 360，过半 = 180dp。
      await tester.drag(verticalGrip(), const Offset(60, 0));
      await tester.pumpAndSettle();
      expect(pulls.isNotEmpty, true, reason: '拖动中实时上抛位移（跟手）');
      expect(releases, [false], reason: '60dp 远没到一半');

      await tester.drag(verticalGrip(), const Offset(340, 0));
      await tester.pumpAndSettle();
      expect(releases, [false, true], reason: '拖过面板宽的一半即缩回');
    });

    testWidgets('没固定：拖竖把手仍是改宽，不触发收起', (tester) async {
      final releases = <bool>[];
      final controller = makeController();
      await tester.runAsync(controller.bootstrap);
      await tester.pumpWidget(host(controller, onCollapseRelease: releases.add));
      await tester.pumpAndSettle();

      final before = contentSize(tester).width;
      // 停右时竖把手在左缘：往右拖 = 收窄（delta 在把手里按停靠侧翻了号）
      await tester.drag(verticalGrip(), const Offset(60, 0));
      await tester.pump();
      expect(contentSize(tester).width, closeTo(before - 60, 20));
      expect(releases, isEmpty, reason: '没固定就没有收起把手');
    });
  });
}

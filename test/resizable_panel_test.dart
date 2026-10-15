import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gtd_todo/application/task_service.dart';
import 'package:gtd_todo/domain/time_context.dart';
import 'package:gtd_todo/repository/memory_task_repository.dart';
import 'package:gtd_todo/scheduler/slack_scheduler.dart';
import 'package:gtd_todo/ui/app_controller.dart';
import 'package:gtd_todo/ui/panels/side_panel.dart';

/// ResizablePanel（ui/panels/side_panel.dart）契约测试：默认尺寸公式、
/// 垂直居中于把手锚点（触边夹紧）、拖底边把手改高并落盘。
///
/// 宿主姿势照应用内壳复刻：Stack + Positioned(top: 8, left: 6)——面板自己在
/// 可用区里 Padding 到锚点位，宿主的 top 就是可用区顶（`padding.top + 8`）。
AppController makeController() {
  final svc = TaskService(
    repo: MemoryTaskRepository(),
    scheduler: const SlackScheduler(),
    workRule: WorkTimeRule.standard,
    clock: () => DateTime(2026, 10, 8, 9, 0),
  );
  return AppController(service: svc, taskDir: '/tmp/tasks');
}

/// 800×600、无安全区：可用区 = [8, 592]；默认宽 = min(0.8×800, 360) = 360，
/// 默认高 = 0.85 × (600 − 16) ≈ 496.4。
Widget host(AppController controller, {double? anchorCenterY}) {
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
              child: const SizedBox.expand(key: Key('panel-content')),
            ),
          ),
        ],
      ),
    ),
  );
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
}

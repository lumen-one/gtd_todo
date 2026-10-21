import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gtd_todo/application/shell_capabilities.dart';
import 'package:gtd_todo/application/task_service.dart';
import 'package:gtd_todo/domain/time_context.dart';
import 'package:gtd_todo/repository/memory_task_repository.dart';
import 'package:gtd_todo/scheduler/slack_scheduler.dart';
import 'package:gtd_todo/ui/app_controller.dart';
import 'package:gtd_todo/ui/panels/settings_panel.dart';

/// 设置页按**壳能力表**裁剪（ui-interaction.md §9 开头，v1.33）。
///
/// 桌面壳接上四页之后，设置页里那组"只对贴屏悬浮壳有意义"的项就露馅了：在
/// Windows 上照常显示、点了什么也不发生。这里守住两条：桌面上它们**整行不在**，
/// 安卓上一条不少；判据是 `AppController.caps`，不是平台名。
void main() {
  /// 视口给得很高：ListView 惰性构建，只有进了视口才在树上——高视口让"找不到"
  /// 确实等于"没渲染"，而不是"还没滚到"。
  Future<void> pumpSettings(
    WidgetTester tester, {
    required ShellCapabilities caps,
  }) async {
    tester.view.physicalSize = const Size(900, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final svc = TaskService(
      repo: MemoryTaskRepository(),
      scheduler: const SlackScheduler(),
      workRule: WorkTimeRule.standard,
      clock: () => DateTime(2026, 10, 7, 10, 0),
    );
    final controller = AppController(
      service: svc,
      taskDir: 'ignored',
      caps: caps,
    );
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: SettingsPanel(controller: controller)),
    ));
    await tester.pumpAndSettle();
  }

  /// 只对悬浮壳有意义的那七行（§9 开头那张表）。
  const overlayOnly = [
    '权限引导',
    '系统级贴屏把手',
    '固定把手位置',
    '固定侧边栏大小',
    '把手热区宽度',
    '重看首次引导',
    '闹钟模式',
  ];

  testWidgets('桌面壳：这七行整行不渲染（不是灰掉）', (tester) async {
    await pumpSettings(tester, caps: ShellCapabilities.plainWindow);

    for (final label in overlayOnly) {
      expect(find.text(label), findsNothing, reason: '桌面上没有「$label」这个能力');
    }
    // 只剩默认页面一项，副标题改口（桌面上没有"展开"这一步）。
    expect(find.text('展开后默认页面'), findsOneWidget);
    expect(find.text('重新打开窗口时左栏落在这一页；点通知定位时按定位目标走'),
        findsOneWidget);
  });

  testWidgets('桌面壳：通用项一个不少', (tester) async {
    await pumpSettings(tester, caps: ShellCapabilities.plainWindow);

    for (final label in [
      '任务目录',
      '同步',
      '工作时间',
      '调度模式',
      '周期任务',
      '定期挑',
      '主题',
      '回收站',
    ]) {
      expect(find.text(label), findsWidgets, reason: '「$label」两种壳都要有');
    }
    // 灵感是分区标题，也与页名 chip 同名，所以只要求存在。
    expect(find.text('灵感'), findsWidgets);
  });

  testWidgets('悬浮壳：七行都在，副标题仍是"拖动把手展开"', (tester) async {
    await pumpSettings(tester, caps: ShellCapabilities.overlayShell);

    for (final label in overlayOnly) {
      expect(find.text(label), findsWidgets, reason: '「$label」是悬浮壳的能力');
    }
    expect(find.text('拖动把手展开时落在这一页；点通知定位时按定位目标走'),
        findsOneWidget);
  });
}

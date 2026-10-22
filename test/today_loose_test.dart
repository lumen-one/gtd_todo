import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gtd_todo/application/task_service.dart';
import 'package:gtd_todo/domain/schedule.dart';
import 'package:gtd_todo/domain/time_context.dart';
import 'package:gtd_todo/repository/markdown_task_repository.dart';
import 'package:gtd_todo/scheduler/slack_scheduler.dart';
import 'package:gtd_todo/ui/app_controller.dart';
import 'package:gtd_todo/ui/panels/pool_panel.dart';
import 'package:gtd_todo/ui/panels/today_panel.dart';
import 'package:gtd_todo/ui/widgets/task_selection.dart';

/// ⑥ 散件段（v1.27）：无排序档把三无散件铺到今日页最底，池子那边不再显示。
void main() {
  Future<AppController> build(WidgetTester tester, ScheduleMode mode) async {
    final tmp = Directory.systemTemp.createTempSync('gtd_today_loose');
    addTearDown(() {
      try {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      } catch (_) {}
    });
    final repo = MarkdownTaskRepository(tmp.path);
    // 时钟用真实时间：控制器视图按 `DateTime.now()` 取"今天"，
    // 挑件标记要落在同一天（散件没有截止，调度时钟在这组测试里无关紧要）。
    final svc = TaskService(
      repo: repo,
      scheduler: const SlackScheduler(),
      workRule: WorkTimeRule.standard,
      scheduleMode: mode,
    );
    await tester.runAsync(() async {
      final picked = await svc.createTask(title: '收拾房间');
      await svc.createTask(title: '写笔记');
      await svc.pickForToday(picked.id);
    });
    final controller = AppController(service: svc, taskDir: tmp.path);
    // 视图口径来自控制器设置（装配点会把两者同步）；测试里直接设。
    await controller.updateSettings(
      controller.settings.copyWith(scheduleMode: mode),
    );
    return controller;
  }

  Future<void> pump(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
    await tester.pumpAndSettle();
  }

  testWidgets('无排序档：⑤ 在上、⑥ 在最底，池子说"散件都在今日清单底部"',
      (tester) async {
    final controller = await build(tester, ScheduleMode.manual);
    final selection = TaskSelection();
    addTearDown(selection.dispose);

    await pump(tester, TodayPanel(controller: controller, selection: selection));
    expect(find.text('被挑散件'), findsOneWidget);
    expect(find.text('散件'), findsOneWidget);
    expect(find.text('收拾房间'), findsOneWidget);
    expect(find.text('写笔记'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('散件')).dy,
      greaterThan(tester.getTopLeft(find.text('被挑散件')).dy),
      reason: '散件段在页底、被挑散件之下',
    );

    await pump(tester, PoolPanel(controller: controller, selection: selection));
    expect(find.text('散件都在今日清单底部'), findsOneWidget);
    expect(find.text('收拾房间'), findsNothing);
    expect(find.text('写笔记'), findsNothing);
  });

  testWidgets('标准档：今日页没有散件段，两件散件都在池子里（一行不变）',
      (tester) async {
    final controller = await build(tester, ScheduleMode.standard);
    final selection = TaskSelection();
    addTearDown(selection.dispose);

    await pump(tester, TodayPanel(controller: controller, selection: selection));
    expect(find.text('散件'), findsNothing);

    await pump(tester, PoolPanel(controller: controller, selection: selection));
    expect(find.text('写笔记'), findsOneWidget);
    expect(find.text('散件都在今日清单底部'), findsNothing);
  });
}

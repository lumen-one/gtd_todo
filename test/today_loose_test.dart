import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qixing/application/task_service.dart';
import 'package:qixing/domain/schedule.dart';
import 'package:qixing/domain/time_context.dart';
import 'package:qixing/repository/markdown_task_repository.dart';
import 'package:qixing/scheduler/slack_scheduler.dart';
import 'package:qixing/ui/app_controller.dart';
import 'package:qixing/ui/panels/pool_panel.dart';
import 'package:qixing/ui/panels/today_panel.dart';
import 'package:qixing/ui/widgets/task_selection.dart';

/// ⑥ 散件段：无排序档把三无散件铺到今日页最底；单件可以长按搬回任务池
/// （metadata `loose_home`），池子那边再搬回来。这一档不跑定期挑，⑤ 不出现。
void main() {
  Future<AppController> build(WidgetTester tester, ScheduleMode mode,
      {bool pick = true}) async {
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
      if (pick) await svc.pickForToday(picked.id);
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

  testWidgets('无排序档：不跑定期挑，两件散件都在 ⑥', (tester) async {
    final controller = await build(tester, ScheduleMode.manual);
    final selection = TaskSelection();
    addTearDown(selection.dispose);

    await pump(tester, TodayPanel(controller: controller, selection: selection));
    expect(find.text('被挑散件'), findsNothing,
        reason: '这一档不跑定期挑，⑤ 段不存在');
    expect(find.text('散件'), findsOneWidget);
    expect(find.text('收拾房间'), findsOneWidget);
    expect(find.text('写笔记'), findsOneWidget);

    await pump(tester, PoolPanel(controller: controller, selection: selection));
    expect(find.text('散件都在今日清单底部'), findsOneWidget);
    expect(find.text('收拾房间'), findsNothing);
    expect(find.text('写笔记'), findsNothing);
  });

  testWidgets('『移到任务池』把散件搬回池子，搬回来又回 ⑥', (tester) async {
    final controller = await build(tester, ScheduleMode.manual);
    final selection = TaskSelection();
    addTearDown(selection.dispose);
    final moved = controller.todayView.loose
        .firstWhere((t) => t.title == '写笔记');

    await tester.runAsync(() => controller.setLooseHome(moved.id, pool: true));

    await pump(tester, TodayPanel(controller: controller, selection: selection));
    expect(find.text('写笔记'), findsNothing);
    expect(find.text('收拾房间'), findsOneWidget, reason: '另一件还在 ⑥');

    await pump(tester, PoolPanel(controller: controller, selection: selection));
    expect(find.text('写笔记'), findsOneWidget);
    expect(find.text('散件都在今日清单底部'), findsNothing,
        reason: '池子里已经有东西，不再是"空但都在今日页"');

    await tester.runAsync(() => controller.setLooseHome(moved.id, pool: false));

    await pump(tester, TodayPanel(controller: controller, selection: selection));
    expect(find.text('写笔记'), findsOneWidget);
  });

  testWidgets('无排序档不跑定期挑，也不记 last_pick_date', (tester) async {
    final controller = await build(tester, ScheduleMode.manual, pick: false);
    await controller.updateSettings(
      controller.settings.copyWith(pickEnabled: true),
    );

    await tester.runAsync(controller.maybePickForToday);

    expect(controller.settings.lastPickDate, isNull,
        reason: '不记账：切回标准档时按间隔照常挑');
    expect(
      controller.tasks.where((t) => t.pickedForDate != null),
      isEmpty,
    );
  });

  testWidgets('标准档：今日页没有散件段，散件在池子里（一行不变）',
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

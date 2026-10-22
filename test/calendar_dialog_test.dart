import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gtd_todo/application/task_service.dart';
import 'package:gtd_todo/domain/schedule.dart';
import 'package:gtd_todo/domain/time_context.dart';
import 'package:gtd_todo/repository/memory_task_repository.dart';
import 'package:gtd_todo/scheduler/slack_scheduler.dart';
import 'package:gtd_todo/ui/app_controller.dart';
import 'package:gtd_todo/ui/dialogs/calendar_dialog.dart';

/// 日历弹窗（ui-interaction.md §6.4）：左右横滑与两侧箭头是同一个动作的两种
/// 走法；**切月清空当天选中**（展开的当天列表收回去）。
void main() {
  Future<AppController> build(WidgetTester tester) async {
    final tmp = Directory.systemTemp.createTempSync('gtd_calendar');
    addTearDown(() {
      try {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      } catch (_) {}
    });
    final svc = TaskService(
      repo: MemoryTaskRepository(),
      scheduler: const SlackScheduler(),
      workRule: WorkTimeRule.standard,
    );
    final now = DateTime.now();
    await tester.runAsync(() async {
      await svc.createTask(
        title: '今天的事',
        deadline: DateTime(now.year, now.month, now.day, 18, 0),
        estimatedWorkMinutes: 30,
      );
    });
    return AppController(service: svc, taskDir: tmp.path);
  }

  Future<void> open(WidgetTester tester, AppController controller) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => showCalendarDialog(context, controller),
              child: const Text('开日历'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('开日历'));
    await tester.pumpAndSettle();
  }

  String label(DateTime m) => '${m.year} 年 ${m.month} 月';

  testWidgets('横滑切月，切月清空当天选中', (tester) async {
    final controller = await build(tester);
    await open(tester, controller);

    final now = DateTime.now();
    expect(find.text(label(now)), findsOneWidget);
    expect(find.text('点某一天看当天安排'), findsOneWidget);

    // 点今天 → 当天列表掀开（同一弹窗内联动）
    await tester.tap(find.descendant(
      of: find.byType(PageView),
      matching: find.text('${now.day}'),
    ));
    await tester.pumpAndSettle();
    expect(find.text('点某一天看当天安排'), findsNothing);
    expect(find.text('今天的事'), findsOneWidget);

    // 往左滑 = 下个月
    await tester.drag(find.byType(PageView), const Offset(-400, 0));
    await tester.pumpAndSettle();
    final next = DateTime(now.year, now.month + 1);
    expect(find.text(label(next)), findsOneWidget);
    expect(find.text('点某一天看当天安排'), findsOneWidget,
        reason: '切月清空当天选中，当天列表收回去');

    // 往右滑两次 = 上个月
    await tester.drag(find.byType(PageView), const Offset(400, 0));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(PageView), const Offset(400, 0));
    await tester.pumpAndSettle();
    final prev = DateTime(now.year, now.month - 1);
    expect(find.text(label(prev)), findsOneWidget);
  });

  testWidgets('两侧箭头与横滑同一条路：一次一格', (tester) async {
    final controller = await build(tester);
    await open(tester, controller);

    final now = DateTime.now();
    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pumpAndSettle();
    expect(find.text(label(DateTime(now.year, now.month + 1))), findsOneWidget);

    await tester.tap(find.byIcon(Icons.chevron_left));
    await tester.pumpAndSettle();
    expect(find.text(label(now)), findsOneWidget);
  });
}

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gtd_todo/application/task_service.dart';
import 'package:gtd_todo/domain/time_context.dart';
import 'package:gtd_todo/repository/memory_task_repository.dart';
import 'package:gtd_todo/scheduler/slack_scheduler.dart';
import 'package:gtd_todo/ui/app_controller.dart';
import 'package:gtd_todo/ui/dialogs/calendar_dialog.dart';
import 'package:gtd_todo/ui/theme.dart';

/// 日历弹窗（ui-interaction.md §6.4）：左右横滑与两侧箭头是同一个动作的两种
/// 走法；**切月清空当天选中**（展开的当天列表收回去）；长按某天直接加一件；
/// 已经干完的件打蓝点、排在当天列表末尾且不可改期。
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

  Finder dayCell(int day) => find.descendant(
        of: find.byType(PageView),
        matching: find.text('$day'),
      );

  testWidgets('横滑切月，切月清空当天选中', (tester) async {
    final controller = await build(tester);
    await open(tester, controller);

    final now = DateTime.now();
    expect(find.text(label(now)), findsOneWidget);
    expect(find.text('点某天看安排，长按某天加一件'), findsOneWidget);

    // 点今天 → 当天列表掀开（同一弹窗内联动）
    await tester.tap(dayCell(now.day));
    await tester.pumpAndSettle();
    expect(find.text('点某天看安排，长按某天加一件'), findsNothing);
    expect(find.text('今天的事'), findsOneWidget);

    // 往左滑 = 下个月
    await tester.drag(find.byType(PageView), const Offset(-400, 0));
    await tester.pumpAndSettle();
    final next = DateTime(now.year, now.month + 1);
    expect(find.text(label(next)), findsOneWidget);
    expect(find.text('点某天看安排，长按某天加一件'), findsOneWidget,
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

  testWidgets('长按某天直接加一件，落到那天 18:00', (tester) async {
    final controller = await build(tester);
    await open(tester, controller);

    final now = DateTime.now();
    await tester.longPress(dayCell(now.day));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget, reason: '长按升起输入行');

    await tester.enterText(find.byType(TextField), '买牛奶');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    final created =
        controller.tasks.where((t) => t.title == '买牛奶').toList();
    expect(created, hasLength(1));
    expect(created.single.deadline, DateTime(now.year, now.month, now.day, 18));
    expect(find.byType(TextField), findsNothing, reason: '加完输入行收起');
    expect(find.text('买牛奶'), findsOneWidget, reason: '当天列表立刻看得见');
  });

  testWidgets('提前干完的件：蓝点 + 进当天列表 + 不可改期', (tester) async {
    final controller = await build(tester);
    final now = DateTime.now();
    await tester.runAsync(() async {
      final t = await controller.createTask(
        title: '提前干完',
        deadline: DateTime(now.year, now.month, now.day, 20, 0),
        estimatedWorkMinutes: 30,
      );
      await controller.complete(t.id);
    });
    await open(tester, controller);

    // 蓝点：已完成色的小圆点（与橙点并列，橙在前）
    expect(
      find.byWidgetPredicate((w) =>
          w is Container &&
          w.decoration is BoxDecoration &&
          (w.decoration! as BoxDecoration).color ==
              AppColors.doneFor(Brightness.light)),
      findsWidgets,
      reason: '月历上打蓝点',
    );

    await tester.tap(dayCell(now.day));
    await tester.pumpAndSettle();
    expect(find.text('提前干完'), findsOneWidget);
    expect(find.text('已完成'), findsOneWidget);

    // 不可点：点它不弹改期
    await tester.tap(find.text('提前干完'));
    await tester.pumpAndSettle();
    expect(find.byType(DatePickerDialog), findsNothing);
  });

  testWidgets('过去的已完成件也留在那天（蓝点不抹掉）', (tester) async {
    final controller = await build(tester);
    final now = DateTime.now();
    final yesterday = now.subtract(const Duration(days: 1));
    await tester.runAsync(() async {
      final t = await controller.createTask(
        title: '早就干完',
        deadline: DateTime(yesterday.year, yesterday.month, yesterday.day, 9, 0),
        estimatedWorkMinutes: 30,
      );
      await controller.complete(t.id);
    });
    await open(tester, controller);

    if (yesterday.month != now.month) {
      await tester.tap(find.byIcon(Icons.chevron_left));
      await tester.pumpAndSettle();
    }
    await tester.tap(dayCell(yesterday.day));
    await tester.pumpAndSettle();
    expect(find.text('早就干完'), findsOneWidget);
    expect(find.text('已完成'), findsOneWidget);
  });
}

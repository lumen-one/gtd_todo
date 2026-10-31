import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qixing/application/settings.dart';
import 'package:qixing/application/task_service.dart';
import 'package:qixing/domain/schedule.dart';
import 'package:qixing/domain/time_context.dart';
import 'package:qixing/repository/memory_task_repository.dart';
import 'package:qixing/scheduler/slack_scheduler.dart';
import 'package:qixing/ui/app_controller.dart';
import 'package:qixing/ui/dialogs/create_task_sheet.dart';
import 'package:qixing/ui/shells/android_shell.dart';

/// 新建流程（ui-interaction.md §5.1）：**先问什么时候，再填内容**。
///
/// 锁三条边界：『+』不再跳过日期直接落三无（那是它以前的默认态）；第 1 页是
/// 月历，点某天即落定、没有『确定』；『不排期』仍能建成长期任务——这条显式
/// 入口断了，桌面上就没有建三无的路（快记只在系统级悬浮把手）。
void main() {
  Future<AppController> pumpShell(WidgetTester tester,
      {ScheduleMode mode = ScheduleMode.manual,
      bool askImportance = false}) async {
    final svc = TaskService(
      repo: MemoryTaskRepository(),
      scheduler: const SlackScheduler(),
      workRule: WorkTimeRule.standard,
      clock: () => DateTime(2026, 10, 7, 10, 0),
    );
    final controller = AppController(
      service: svc,
      taskDir: 'ignored',
      settingsPort: _MemorySettingsPort(
        AppSettings.defaults.copyWith(
            guideSeen: true,
            scheduleMode: mode,
            askImportance: askImportance),
      ),
    );
    await tester.binding.setSurfaceSize(const Size(420, 860));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(controller.bootstrap);
    await tester.pumpWidget(
      MaterialApp(home: AndroidShell(controller: controller)),
    );
    await tester.pumpAndSettle();
    return controller;
  }

  /// 打开抽屉 → 点右下角「+」→ 落到日期页。
  ///
  /// 两个宿主各挂一份 [PanelDock]，这里限定抽屉里那一份。
  Future<void> openCreateFlow(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(Drawer),
        matching: find.byIcon(Icons.add),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 月历上某天那一格（组件给每天的格子挂了 `day-y-m-d` 的 key）。
  Finder dayCell(DateTime d) =>
      find.byKey(ValueKey('day-${d.year}-${d.month}-${d.day}'));

  testWidgets('点「+」先问什么时候：月历在，标题框还没出现', (tester) async {
    await pumpShell(tester);
    await openCreateFlow(tester);

    expect(find.text('什么时候？'), findsOneWidget);
    expect(find.text('标题'), findsNothing, reason: '日期没定之前不问内容');
    expect(dayCell(DateTime.now()), findsOneWidget, reason: '第 1 页是月历');
    expect(find.widgetWithText(TextButton, '不排期'), findsOneWidget);
  });

  testWidgets('点今天那格：日期落 18:00，填完标题即建', (tester) async {
    final controller = await pumpShell(tester);
    await openCreateFlow(tester);

    await tester.tap(dayCell(DateTime.now()));
    await tester.pumpAndSettle();

    expect(find.text('标题'), findsOneWidget);
    // 只认日期行本身（「截止型」也是含"截止"的文本）
    expect(find.textContaining(RegExp(r'^截止 \d')), findsOneWidget);
    expect(find.textContaining('18:00'), findsWidgets);

    await tester.enterText(find.byType(TextField).first, '写周报');
    await tester.pumpAndSettle();
    await tester.tap(find.text('✱ 创建'));
    await tester.pumpAndSettle();

    final task = controller.tasks.single;
    expect(task.title, '写周报');
    expect(task.deadline!.hour, 18);
    expect(task.deadline!.day, DateTime.now().day);
    expect(task.isLongTerm, isFalse, reason: '有截止 → 按时长，缺省 30 分钟');
    expect(task.estimatedWork, 30);
    expect(task.ringEnabled, isTrue, reason: '新建的『响铃』默认打开（§7.0）');
  });

  testWidgets('切『开始型』：时刻跟着换成 12:00，日期不动', (tester) async {
    final controller = await pumpShell(tester);
    await openCreateFlow(tester);

    final today = DateTime.now();
    await tester.tap(dayCell(today));
    await tester.pumpAndSettle();
    expect(find.textContaining('18:00'), findsWidgets);

    await tester.tap(find.text('开始型'));
    await tester.pumpAndSettle();

    expect(find.textContaining(RegExp(r'^开始 \d')), findsOneWidget,
        reason: '日期行的文案跟着类型走');
    expect(find.text('12:00'), findsOneWidget);
    expect(find.textContaining('18:00'), findsNothing);

    await tester.enterText(find.byType(TextField).first, '开会');
    await tester.pumpAndSettle();
    await tester.tap(find.text('✱ 创建'));
    await tester.pumpAndSettle();

    final task = controller.tasks.single;
    expect(task.type.name, 'fixed');
    expect(task.deadline, DateTime(today.year, today.month, today.day, 12));
  });

  // 问多少由档位与开关决定（§5.1 / §7.0）：新建表单按档位裁行，重要度另看
  // 『问重要度』。『响铃』不在裁剪之列——它管声音，不管发不发，两档都摆。
  testWidgets('无排序档只问标题和日期：工时与重要度不出现，响铃照摆', (tester) async {
    await pumpShell(tester); // 新装默认 = 无排序
    await openCreateFlow(tester);
    await tester.tap(dayCell(DateTime.now()));
    await tester.pumpAndSettle();

    expect(find.text('工作强度'), findsNothing);
    expect(find.text('重要度'), findsNothing);
    expect(find.text('响铃'), findsOneWidget);
  });

  testWidgets('标准档多问工时；『问重要度』默认关，仍不问', (tester) async {
    await pumpShell(tester, mode: ScheduleMode.standard);
    await openCreateFlow(tester);
    await tester.tap(dayCell(DateTime.now()));
    await tester.pumpAndSettle();

    expect(find.text('工作强度'), findsOneWidget);
    expect(find.text('重要度'), findsNothing);
    expect(find.text('响铃'), findsOneWidget);
  });

  testWidgets('打开『问重要度』才问；响铃照摆', (tester) async {
    await pumpShell(tester, mode: ScheduleMode.standard, askImportance: true);
    await openCreateFlow(tester);
    await tester.tap(dayCell(DateTime.now()));
    await tester.pumpAndSettle();

    expect(find.text('工作强度'), findsOneWidget);
    expect(find.text('重要度'), findsOneWidget);
    expect(find.text('响铃'), findsOneWidget);
  });

  testWidgets('『改日期』退回月历，已选那天保持高亮', (tester) async {
    await pumpShell(tester);
    await openCreateFlow(tester);

    final today = DateTime.now();
    await tester.tap(dayCell(today));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '写周报');
    await tester.pumpAndSettle();

    await tester.tap(find.text('改日期'));
    await tester.pumpAndSettle();

    expect(find.text('什么时候？'), findsOneWidget);
    // 格子里的数字被强调圈选中时是白色（选中态），未选中取默认色。
    final cell = tester.widget<Text>(
      find.descendant(of: dayCell(today), matching: find.text('${today.day}')),
    );
    expect(cell.style?.color, Colors.white, reason: '回月历时那天仍是选中的');
  });

  testWidgets('『不排期』建成长期任务：无截止、不估工时', (tester) async {
    final controller = await pumpShell(tester);    await openCreateFlow(tester);

    await tester.tap(find.widgetWithText(TextButton, '不排期'));
    await tester.pumpAndSettle();

    expect(find.text('不排期（散件）'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, '学一门外语');
    await tester.pumpAndSettle();
    await tester.tap(find.text('✱ 创建'));
    await tester.pumpAndSettle();

    final task = controller.tasks.single;
    expect(task.deadline, isNull);
    expect(task.estimatedWork, isNull);
    expect(task.isLongTerm, isTrue);
  });
  testWidgets('面板最矮的 240×320：第 1 页不溢出', (tester) async {
    await tester.binding.setSurfaceSize(const Size(240, 320));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = AppController(
      service: TaskService(
        repo: MemoryTaskRepository(),
        scheduler: const SlackScheduler(),
        workRule: WorkTimeRule.standard,
      ),
      taskDir: 'ignored',
    );
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => showCreateFlow(context, controller),
              child: const Text('加'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('加'));
    await tester.pumpAndSettle();

    expect(find.text('什么时候？'), findsOneWidget);
    expect(tester.takeException(), isNull, reason: '可用高度不够时压格子，不溢出');
  });
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

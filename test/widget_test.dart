import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qixing/application/settings.dart';
import 'package:qixing/application/task_service.dart';
import 'package:qixing/domain/schedule.dart';
import 'package:qixing/domain/task.dart';
import 'package:qixing/domain/time_context.dart';
import 'package:qixing/main.dart';
import 'package:qixing/repository/markdown_task_repository.dart';
import 'package:qixing/scheduler/slack_scheduler.dart';
import 'package:qixing/ui/app_controller.dart';
import 'package:qixing/ui/panels/settings_panel.dart';
import 'package:qixing/ui/panels/side_panel.dart';

/// 冒烟：整个 App（`main.dart` 的装配 + 桌面壳 + 真实的 Markdown 仓库）能不能
/// 起来、任务摆不摆得出来。
///
/// v1.32 起桌面壳换成"常驻侧栏 + 设置页主体"（ui-interaction.md §6.10），旧单页
/// 清单（TaskListPanel）里那句"下次提醒 / 不提醒"的文案随之消失——调度模式现在
/// 由**设置页『提醒与排序』的说明文字**如实说出来，断言跟着挪过去。
void main() {
  /// 装一次桌面壳。注意 testWidgets 跑在 FakeAsync 区：真实文件 IO 必须包进
  /// `tester.runAsync`，否则挂死。
  Future<void> pumpApp(WidgetTester tester,
      {required ScheduleMode mode}) async {
    final tmp = Directory.systemTemp.createTempSync('gtd_widget_test');
    addTearDown(() {
      // Windows 下偶发 errno=32（索引器/杀毒瞬时占用），清理失败可忽略
      try {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    final repo = MarkdownTaskRepository(tmp.path);
    // 模式不直接塞给 TaskService：走设置 → bootstrap → onScheduleModeChanged
    // 这条真实路径，测的才是应用里发生的事。
    final svc = TaskService(
      repo: repo,
      scheduler: const SlackScheduler(),
      workRule: WorkTimeRule.standard,
      clock: () => DateTime(2026, 10, 7, 16, 0),
    );
    final controller = AppController(
      service: svc,
      taskDir: tmp.path,
      settingsPort:
          _MemorySettingsPort(AppSettings.defaults.copyWith(scheduleMode: mode)),
      onScheduleModeChanged: svc.updateScheduleMode,
    );
    await tester.runAsync(() async {
      await repo.save(Task(
        id: 'task-100',
        title: '写周报',
        deadline: DateTime(2026, 10, 9, 18, 0),
        estimatedWork: 60,
        created: DateTime(2026, 10, 7, 15, 0),
      ));
      await svc.refreshSchedule();
      await controller.bootstrap();
    });

    await tester.pumpWidget(GtdTodoApp(controller: controller));
    await tester.pumpAndSettle();
  }

  /// 设置页是一个很长的 ListView：目标行在首屏之外时得先滚下去（惰性构建，
  /// 不滚就根本不在树上）。
  Future<void> revealInSettings(WidgetTester tester, String text) async {
    final scrollable = find
        .descendant(
            of: find.byType(SettingsPanel), matching: find.byType(Scrollable))
        .first;
    await tester.scrollUntilVisible(find.text(text), 240,
        scrollable: scrollable);
    await tester.pumpAndSettle();
  }

  testWidgets('Markdown 里的任务摆进今日清单，设置页就在右栏', (tester) async {
    await pumpApp(tester, mode: ScheduleMode.standard);

    expect(find.text('启行'), findsOneWidget);
    expect(find.text('写周报'), findsOneWidget);
    // 桌面壳 = 侧栏 + 设置页（v1.32），两栏都在。
    expect(find.byType(SidePanel), findsOneWidget);
    expect(find.byType(SettingsPanel), findsOneWidget);
  });

  testWidgets('标准模式在设置页如实说"提醒按裕度节奏"', (tester) async {
    await pumpApp(tester, mode: ScheduleMode.standard);
    await revealInSettings(tester, '标准：排先后，提醒按裕度节奏');

    expect(find.text('标准：排先后，提醒按裕度节奏'), findsOneWidget);
  });

  testWidgets('标准档把『问重要度』摆出来，AI 编排留位但不可点', (tester) async {
    await pumpApp(tester, mode: ScheduleMode.standard);
    await revealInSettings(tester, '问重要度');

    expect(find.text('问重要度'), findsOneWidget);
    // AI 编排是入口位、不是第三档：这一行在界面上，但不接点击。
    final tile = tester.widget<ListTile>(
        find.ancestor(of: find.text('AI 编排'), matching: find.byType(ListTile)));
    expect(tile.enabled, isFalse);
  });
}

/// 内存版 SettingsPort：测试里不碰磁盘（bootstrap 只读一次，写回不关心）。
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

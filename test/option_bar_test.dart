import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qixing/application/shell_capabilities.dart';
import 'package:qixing/application/task_service.dart';
import 'package:qixing/domain/schedule.dart';
import 'package:qixing/domain/time_context.dart';
import 'package:qixing/repository/memory_task_repository.dart';
import 'package:qixing/scheduler/slack_scheduler.dart';
import 'package:qixing/ui/app_controller.dart';
import 'package:qixing/ui/panel_pages.dart';
import 'package:qixing/ui/panels/settings_panel.dart';
import 'package:qixing/ui/widgets/option_bar.dart';

/// 选项组怎么排（ui-interaction.md §9"选项组怎么排"）：等分格子、均衡折行。
///
/// 守两件事：**一行放得下就一行**（四个短标签不许折成 3+1）；放不下时**均衡**
/// 折（四个 → 2+2，不是 3+1），且每行格子一样宽。
void main() {
  Future<void> pumpBar(
    WidgetTester tester, {
    required double width,
    required List<(int, String)> options,
    int selected = 0,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: width,
            child: OptionBar<int>(
              options: options,
              selected: selected,
              onChanged: (_) {},
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  double top(WidgetTester tester, String label) =>
      tester.getRect(find.text(label)).top;

  /// 格子（按钮本体）的宽，不是文字的宽——比较的是"末行空槽补齐后每格等宽"。
  double cellWidth(WidgetTester tester, String label) => tester
      .getSize(
          find.ancestor(of: find.text(label), matching: find.byType(SizedBox)).first)
      .width;

  testWidgets('四个短标签一行放得下 → 就一行', (tester) async {
    await pumpBar(tester, width: 400, options: const [
      (15, '15 分'),
      (30, '30 分'),
      (60, '1 小时'),
      (120, '2 小时'),
    ]);
    final first = top(tester, '15 分');
    for (final label in ['30 分', '1 小时', '2 小时']) {
      expect(top(tester, label), first, reason: '$label 与第一格同一行');
    }
  });

  testWidgets('四个四字标签窄一点 → 2+2，不是 3+1', (tester) async {
    await pumpBar(tester, width: 300, options: const [
      (0, '灵感'),
      (1, '今日清单'),
      (2, '任务池'),
      (3, '已完成'),
    ]);
    expect(top(tester, '灵感'), top(tester, '今日清单'));
    expect(top(tester, '任务池'), top(tester, '已完成'));
    expect(top(tester, '任务池'), greaterThan(top(tester, '灵感')),
        reason: '第二行在下面');
    expect(top(tester, '已完成'), top(tester, '任务池'),
        reason: '末行两个而不是一个孤零零的');
  });

  testWidgets('末行不满也占同样的宽度（空槽补齐）', (tester) async {
    // 120 宽：三个短标签放不下（测试环境的字体每个字都是一个方块，比真实中文
    // 宽），折成 2+1——上一行两格等宽。
    await pumpBar(tester, width: 120, options: const [
      (0, '细'),
      (1, '标准'),
      (2, '宽'),
    ]);
    expect(top(tester, '细'), top(tester, '标准'));
    expect(top(tester, '宽'), greaterThan(top(tester, '细')));
    expect(cellWidth(tester, '细'), cellWidth(tester, '标准'));
  });

  testWidgets('360dp 宽的设置页：选项组不折成 3+1，整页不溢出', (tester) async {
    tester.view.physicalSize = const Size(360, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final svc = TaskService(
      repo: MemoryTaskRepository(),
      scheduler: const SlackScheduler(),
      workRule: WorkTimeRule.standard,
      scheduleMode: ScheduleMode.manual,
      clock: () => DateTime(2026, 10, 31, 10, 0),
    );
    final controller = AppController(
      service: svc,
      taskDir: 'ignored',
      caps: ShellCapabilities.overlayShell, // 悬浮壳：把手那几组都在
    );
    await controller.updateSettings(
      controller.settings.copyWith(scheduleMode: ScheduleMode.manual),
    );
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: SettingsPanel(controller: controller)),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: '窄屏不该有溢出');

    // 无排序档的提前量：四个短标签**要么一行，要么 2+2**——截图里那种 3+1
    // 是本条要防的退化（测试环境的字体每个字都是一个方块，比真实中文宽，
    // 所以这里排成 2+2；真机上是四个一行）。
    expect(top(tester, '15 分'), top(tester, '30 分'));
    expect(top(tester, '1 小时'), top(tester, '2 小时'));
    expect(top(tester, '1 小时'), greaterThan(top(tester, '15 分')),
        reason: '第三格不许跟着前两个挤在上一行（那就是 3+1）');

    // 默认页面四个四字标签在 360dp 上放不进一行，但必须 2+2。
    // 只在这组格子里找："灵感"也是下面那个分区的标题。
    double pageTop(String label) => tester
        .getRect(find.descendant(
          of: find.byType(OptionBar<PanelPage>),
          matching: find.text(label),
        ))
        .top;
    expect(pageTop('灵感'), pageTop('今日清单'));
    expect(pageTop('任务池'), pageTop('已完成'));
    expect(pageTop('任务池'), greaterThan(pageTop('灵感')));
  });
}

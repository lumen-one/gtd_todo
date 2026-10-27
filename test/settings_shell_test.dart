import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gtd_todo/application/delivery.dart';
import 'package:gtd_todo/application/shell_capabilities.dart';
import 'package:gtd_todo/application/task_service.dart';
import 'package:gtd_todo/domain/time_context.dart';
import 'package:gtd_todo/repository/memory_task_repository.dart';
import 'package:gtd_todo/scheduler/slack_scheduler.dart';
import 'package:gtd_todo/ui/app_controller.dart';
import 'package:gtd_todo/ui/panels/settings_panel.dart';

/// 设置页按**壳能力表**裁剪（ui-interaction.md §9 开头）。
///
/// 桌面壳接上四页之后，设置页里那组"只对贴屏悬浮壳有意义"的项就露馅了：在
/// Windows 上照常显示、点了什么也不发生。这里守住三条：桌面上它们**整行不在**，
/// 安卓上一条不少，判据是 `AppController.caps` 而不是平台名；而**把手恒开**，
/// 所以两种壳的设置页里都没有那颗开关。
void main() {
  /// 视口给得很高：ListView 惰性构建，只有进了视口才在树上——高视口让"找不到"
  /// 确实等于"没渲染"，而不是"还没滚到"。
  Future<void> pumpSettings(
    WidgetTester tester, {
    required ShellCapabilities caps,
    Size size = const Size(900, 4000),
    FolderPickerPort? picker,
    Future<({String version, String build})?> Function()? appVersionReader,
  }) async {
    tester.view.physicalSize = size;
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
      folderPicker: picker,
    )..appVersionReader = appVersionReader;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: SettingsPanel(controller: controller)),
    ));
    await tester.pumpAndSettle();
  }

  /// 只对悬浮壳有意义的那六行（§9 开头那张表）。
  const overlayOnly = [
    '权限引导',
    '固定把手位置',
    '固定侧边栏大小',
    '把手热区宽度',
    '重看首次引导',
    '闹钟模式',
  ];

  testWidgets('桌面壳：这六行整行不渲染（不是灰掉）', (tester) async {
    await pumpSettings(tester, caps: ShellCapabilities.plainWindow);

    for (final label in overlayOnly) {
      expect(find.text(label), findsNothing, reason: '桌面上没有「$label」这个能力');
    }
    // 把手恒开（§6.0）：它不是一个设置项，桌面上自然也没有这颗开关。
    expect(find.text('系统级贴屏把手'), findsNothing);
    // 只剩默认页面一项，副标题改口（桌面上没有"展开"这一步）。
    expect(find.text('展开后默认页面'), findsOneWidget);
    expect(find.text('重新打开窗口时左栏落在这一页；点通知定位时按定位目标走'),
        findsOneWidget);
    // 『关于』同理整块不出现：桌面那一栏待整块重做（docs/roadmap.md 2.4），
    // 不是"桌面没有版本号"。
    expect(find.text('关于'), findsNothing);
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

  testWidgets('悬浮壳：六行都在，副标题仍是"拖动把手展开"', (tester) async {
    await pumpSettings(tester, caps: ShellCapabilities.overlayShell);

    for (final label in overlayOnly) {
      expect(find.text(label), findsWidgets, reason: '「$label」是悬浮壳的能力');
    }
    // 把手恒开（§6.0）：能力表里仍有 systemHandle（默认页副标题要用），但
    // **没有开关**——连灰掉的都不摆。
    expect(find.text('系统级贴屏把手'), findsNothing);
    expect(find.text('拖动把手展开时落在这一页；点通知定位时按定位目标走'),
        findsOneWidget);
    // 关于：版本号（测试里没接版本号插座 → 占位）+ 反馈 QQ + GitHub。
    // 行尾不缀『点一下复制』：复制靠点行本身（§9 第 14 条）。
    expect(find.text('关于'), findsOneWidget);
    expect(find.text('版本'), findsOneWidget);
    expect(find.text('QQ 3110741060'), findsOneWidget);
    expect(find.text('https://github.com/lumen-one/gtd_todo'), findsOneWidget);
  });

  /// 版本号由装配点注入（安卓是原生 `PackageManager` 读回来的两截），
  /// 拼成 `主版本 (构建号)` 的规则在 `AppController.loadAppVersion` 里。
  testWidgets('关于：版本号按原生报的两截拼出来，只问一次', (tester) async {
    var calls = 0;
    await pumpSettings(
      tester,
      caps: ShellCapabilities.overlayShell,
      appVersionReader: () async {
        calls++;
        return (version: '1.2.0', build: '4');
      },
    );

    expect(find.text('1.2.0 (4)'), findsOneWidget);
    expect(find.text('读取中…'), findsNothing);
    // 幂等：读到就不再问平台（设置页每次进都调一次 loadAppVersion）
    expect(calls, 1);
  });

  testWidgets('关于：没接插座就留占位，不假装读到了', (tester) async {
    await pumpSettings(tester, caps: ShellCapabilities.overlayShell);

    expect(find.text('读取中…'), findsOneWidget);
  });

  /// 两个路径编辑弹窗都是底部弹窗：`showModalBottomSheet` 不会自己给输入法让位，
  /// 少了 `isScrollControlled` + `viewInsets` 那一层，输入框正好落在键盘底下
  /// （用户报的就是这个）。这里按下限守住：输入框和保存按钮都在键盘上方。
  const phone = Size(400, 1400);
  const keyboardHeight = 600.0;

  Future<void> expectSheetAboveKeyboard(
    WidgetTester tester, {
    required String rowLabel,
    required String fieldLabel,
  }) async {
    await pumpSettings(tester, caps: ShellCapabilities.overlayShell, size: phone);
    // 任务目录既是分区标题也是行标题，按整行找。
    final row = find.widgetWithText(ListTile, rowLabel);
    await tester.scrollUntilVisible(row, 240,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(row);
    await tester.pumpAndSettle();

    tester.view.viewInsets = const FakeViewPadding(bottom: keyboardHeight);
    await tester.pumpAndSettle();

    final topOfKeyboard = phone.height - keyboardHeight;
    expect(tester.getRect(find.text(fieldLabel)).bottom,
        lessThanOrEqualTo(topOfKeyboard),
        reason: '输入框「$fieldLabel」落到了键盘底下');
    expect(
        tester
            .getRect(find.widgetWithText(FilledButton, '保存'))
            .bottom,
        lessThanOrEqualTo(topOfKeyboard),
        reason: '保存按钮落到了键盘底下');
  }

  testWidgets('任务目录：键盘弹起时输入框跟着上浮', (tester) async {
    await expectSheetAboveKeyboard(tester,
        rowLabel: '任务目录', fieldLabel: '目录路径');
  });

  testWidgets('灵感文件路径：键盘弹起时输入框跟着上浮', (tester) async {
    await expectSheetAboveKeyboard(tester,
        rowLabel: '灵感文件路径', fieldLabel: '文件路径');
  });

  /// 灵感文件这条路只认**真实文件路径 + Markdown**：选择器回什么就落什么，回错了就
  /// 只提示不落（路径一旦落进缓存副本，写回的是副本，Obsidian 那份永远不动，见
  /// docs/decisions/2026-10-24-android-markdown-pick.md）。
  Future<void> pickNotes(WidgetTester tester, {required String? picked}) async {
    await pumpSettings(tester,
        caps: ShellCapabilities.overlayShell, size: phone, picker: _FakePicker(picked));
    final row = find.widgetWithText(ListTile, '灵感文件路径');
    await tester.scrollUntilVisible(row, 240,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(row);
    await tester.pumpAndSettle();
    await tester.tap(find.text('用系统选择器挑一个文件'));
    await tester.pumpAndSettle();
  }

  testWidgets('灵感文件路径：选到非 Markdown 只提示，路径不变', (tester) async {
    await pickNotes(tester, picked: '/storage/emulated/0/vault/灵感.txt');

    expect(find.text('只支持 Markdown 文件（.md）'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, '');
  });

  testWidgets('灵感文件路径：真实路径落进输入框，光标停在末尾', (tester) async {
    const path = '/storage/emulated/0/Documents/vault/灵感.md';
    await pickNotes(tester, picked: path);

    final ctrl = tester.widget<TextField>(find.byType(TextField)).controller!;
    expect(ctrl.text, path);
    expect(ctrl.selection.baseOffset, path.length,
        reason: '光标在末尾才不会只看见 /storage 那截前缀');
  });
}

/// 只回一个固定结果的目录/文件选择器。
class _FakePicker implements FolderPickerPort {
  _FakePicker(this.picked);

  final String? picked;

  @override
  Future<String?> pickDirectory() async => null;

  @override
  Future<String?> pickFile({
    required String dialogTitle,
    required List<String> allowedExtensions,
  }) async =>
      picked;
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gtd_todo/ui/panels/side_panel.dart';

/// 拖出头快记的输入条（ui-interaction.md §6.8）。
///
/// 这里只测 Dart 侧那一段：方块落到中央 → 挂输入框 → 提交 / 收起。
/// 原生的手势分岔（过 0.45 屏宽后判方向、窗口变方块）没有单测，靠真机验。
void main() {
  Future<void> pumpLayer(
    WidgetTester tester, {
    required Future<void> Function(String) onSubmit,
    required VoidCallback onClose,
  }) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: QuickNoteLayer(
          // 从右侧边缘的落点起飞（模拟停靠右边时的松手位置）。
          origin: const Offset(360, 400),
          onSubmit: onSubmit,
          onClose: onClose,
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  TextField field(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField));

  testWidgets('方块先滑到屏幕中央，动画放完才挂输入框', (tester) async {
    await pumpLayer(tester, onSubmit: (_) async {}, onClose: () {});

    // 动画结束后输入框落在屏幕正中（取组件自己看到的 MediaQuery——测试环境的
    // surface 尺寸与实际窗口尺寸不一致，不能拿 Scaffold 的尺寸当参照）。
    expect(find.byType(TextField), findsOneWidget);
    final mq = MediaQuery.of(tester.element(find.byType(QuickNoteLayer)));
    final bar = tester.getRect(find.byType(TextField));
    expect(bar.center.dx, closeTo(mq.size.width / 2, 24));
    expect(bar.center.dy, closeTo(mq.size.height / 2, 24));
  });

  testWidgets('回车提交：交给 onSubmit、清空输入、留在原位', (tester) async {
    final submitted = <String>[];
    await pumpLayer(
      tester,
      onSubmit: (t) async => submitted.add(t),
      onClose: () {},
    );

    await tester.enterText(find.byType(TextField), '  写论文  ');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(submitted, ['写论文'], reason: '提交前要去掉首尾空白');
    expect(field(tester).controller?.text, '', reason: '清空，接着记下一条');
    expect(find.byType(TextField), findsOneWidget, reason: '连记：输入框留着');
  });

  testWidgets('空文本不产生任务', (tester) async {
    final submitted = <String>[];
    await pumpLayer(
      tester,
      onSubmit: (t) async => submitted.add(t),
      onClose: () {},
    );

    await tester.enterText(find.byType(TextField), '   ');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(submitted, isEmpty);
  });

  testWidgets('点外部收起（丢弃草稿）', (tester) async {
    var closed = 0;
    await pumpLayer(tester, onSubmit: (_) async {}, onClose: () => closed++);

    await tester.enterText(find.byType(TextField), '半截草稿');
    // 屏幕左上角：在输入条外面。
    await tester.tapAt(const Offset(12, 12));
    await tester.pumpAndSettle();

    expect(closed, 1);
  });
}

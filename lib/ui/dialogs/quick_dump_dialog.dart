import 'package:flutter/material.dart';

import '../app_controller.dart';

/// 堆三无（§5.2，忙时专用）：跳过整个对话框，一句话即刻成为三无任务
/// 入池散件段。目标 = 两秒内把脑子里的东西甩出去。
Future<void> showQuickDump(BuildContext context, AppController controller,
    {String hint = '想到什么甩进来…'}) {
  final ctrl = TextEditingController();
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: Theme.of(ctx).cardTheme.color,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: const Text('堆三无'),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        maxLines: 1,
        textInputAction: TextInputAction.done,
        onSubmitted: (v) => Navigator.of(ctx).pop(v),
        decoration: InputDecoration(hintText: hint),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(ctrl.text),
          child: const Text('入池'),
        ),
      ],
    ),
  ).then((value) {
    final text = (value as String?)?.trim();
    if (text == null || text.isEmpty) return;
    if (!context.mounted) return;
    controller.createTask(title: text);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('已入池'),
        duration: Duration(seconds: 2),
      ),
    );
  });
}

import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../dialogs/snooze_sheet.dart';
import '../theme.dart';
import 'task_tile.dart';

/// 提醒回流监听（§7.2）：NotificationPort 的 shown 流 / 前台轮询产出
/// ReminderEvent → 渲染提醒弹窗（桌面 = "托盘"即应用窗口；安卓 = 前台兜底）。
/// 系统通知/全屏闹钟的安卓适配器在设备阶段接入同一个插座。
class ReminderListener extends StatefulWidget {
  final AppController controller;
  final Widget child;

  const ReminderListener({
    super.key,
    required this.controller,
    required this.child,
  });

  @override
  State<ReminderListener> createState() => _ReminderListenerState();
}

class _ReminderListenerState extends State<ReminderListener> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChange);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onChange());
  }

  @override
  void didUpdateWidget(covariant ReminderListener oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onChange);
      widget.controller.addListener(_onChange);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    final event = widget.controller.lastReminder;
    if (event == null || !mounted) return;
    widget.controller.clearReminder();
    final task = widget.controller.taskById(event.taskId);
    if (task == null) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(children: [
          Icon(Icons.alarm, color: AppColors.accent),
          const SizedBox(width: 8),
          const Text('该做这件事了'),
        ]),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(task.title, style: Theme.of(ctx).textTheme.titleMedium),
            const SizedBox(height: 6),
            if (task.deadline != null)
              Text('截止 ${fmtDateTime(task.deadline!)}'),
            if (task.remainingWork > 0) Text('剩余约 ${task.remainingWork} 分钟'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              showModalBottomSheet<void>(
                context: ctx,
                builder: (_) =>
                    SnoozeSheet(controller: widget.controller, task: task),
              );
            },
            child: const Text('推迟…'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              widget.controller.snooze(task.id, minutes: 60);
            },
            child: const Text('推迟 1 小时'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              widget.controller.complete(task.id);
            },
            child: const Text('完成'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

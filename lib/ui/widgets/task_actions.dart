import 'package:flutter/material.dart';

import '../../domain/task.dart';
import '../app_controller.dart';
import '../dialogs/edit_task_sheet.dart';
import '../dialogs/snooze_sheet.dart';
import '../theme.dart';

/// 长按菜单（决议 23/25：按组上下文相关）+ 软删除撤销 toast（决议 15）。
Future<void> showTaskMenu(
  BuildContext context,
  AppController controller,
  Task task, {
  required TaskMenuKind kind,
}) {
  // ④ 例行实例（决议 23）：完成 / 跳过今天 / 编辑规则 / 删除规则；无『推迟』
  // （实例默认不响，改节奏去编辑规则），也没有"编辑实例"。
  if (kind == TaskMenuKind.routine) {
    return _showRoutineInstanceMenu(context, controller, task);
  }

  final entries = <_MenuEntry>[
    ('完成', Icons.check_circle, () => controller.complete(task.id)),
    // ② 的『推迟』= snooze 本次提醒，事件时刻不变（决议 23）；
    // 被挑散件无『推迟』（决议 25）；固定时点照常给档位。
    if (kind != TaskMenuKind.picked)
      (
        '推迟…',
        Icons.schedule,
        () => showModalBottomSheet<void>(
              context: context,
              builder: (_) => SnoozeSheet(controller: controller, task: task),
            )
      ),
    if (kind == TaskMenuKind.flex) ('插队到最前', Icons.keyboard_double_arrow_up, () => controller.pinToTop(task.id)),
    if (kind == TaskMenuKind.picked)
      ('放回池子', Icons.undo, () => controller.returnToPool(task.id)),
    (
      '编辑',
      Icons.edit,
      () => showEditSheet(context, controller,
          task: task,
          title: kind == TaskMenuKind.picked ? '编辑（可顺手转正）' : '编辑任务')
    ),
    ('删除', Icons.delete_outline, () => deleteTaskWithUndo(context, controller, task)),
  ];

  return _showMenuSheet(
    context,
    title: task.title,
    tag: switch (kind) {
      TaskMenuKind.picked => '被挑散件',
      TaskMenuKind.fixed => '固定时点',
      TaskMenuKind.overdue => '逾期',
      _ => null,
    },
    entries: entries,
  );
}

/// 例行实例菜单（决议 23）。
Future<void> _showRoutineInstanceMenu(
    BuildContext context, AppController controller, Task instance) {
  final routineId = instance.routineId;
  return _showMenuSheet(
    context,
    title: instance.title,
    tag: '例行',
    entries: [
      ('完成', Icons.check_circle, () => controller.complete(instance.id)),
      ('跳过今天', Icons.skip_next, () => controller.skipRoutineToday(instance.id)),
      if (routineId != null)
        (
          '编辑规则',
          Icons.edit_calendar,
          () async => controller.focusRoutineInSettings(routineId)
        ),
      if (routineId != null)
        (
          '删除规则',
          Icons.delete_forever_outlined,
          () => _deleteRoutineWithConfirm(context, controller, routineId)
        ),
    ],
  );
}

/// 删除规则需确认（决议 23）；连带清掉未完成的今日实例。
Future<void> _deleteRoutineWithConfirm(BuildContext context,
    AppController controller, String routineId) async {
  final routine = controller.routineById(routineId);
  final name = routine?.title ?? '该规则';
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('删除规则「$name」？'),
      content: const Text('规则会从 routines.md 移除；今天未完成的实例一并移入回收站。'),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消')),
        FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除')),
      ],
    ),
  );
  if (ok == true) await controller.deleteRoutine(routineId);
}

Future<void> _showMenuSheet(
  BuildContext context, {
  required String title,
  required List<_MenuEntry> entries,
  String? tag,
}) {
  return showModalBottomSheet<void>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(ctx).textTheme.titleSmall,
                  ),
                ),
                if (tag != null) _MenuTag(tag),
              ],
            ),
          ),
          for (final (label, icon, action) in entries)
            ListTile(
              leading: Icon(icon, color: AppColors.accent),
              title: Text(label),
              onTap: () async {
                Navigator.of(ctx).pop();
                try {
                  await action();
                } catch (e) {
                  if (ctx.mounted) {
                    ScaffoldMessenger.of(ctx).showSnackBar(
                        SnackBar(content: Text('操作失败：$e')));
                  }
                }
              },
            ),
        ],
      ),
    ),
  );
}

enum TaskMenuKind { overdue, fixed, flex, picked, routine }

class _MenuTag extends StatelessWidget {
  final String label;
  const _MenuTag(this.label);

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: AppColors.accent.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(label,
            style: TextStyle(color: AppColors.accent, fontSize: 11.5)),
      );
}

typedef _MenuEntry = (String, IconData, Future<void> Function());

/// 任务池条目菜单（决议 13：散件段与计划段同款）：
/// 挑到今日（不转正，附今日尾部）/ 转正（补属性，进调度）/ 完成 / 编辑 / 删除。
Future<void> showPoolMenu(
    BuildContext context, AppController controller, Task task) {
  final entries = <_MenuEntry>[
    ('挑到今日', Icons.today, () => controller.pickForToday(task.id)),
    ('完成', Icons.check_circle, () => controller.complete(task.id)),
    (
      '编辑',
      Icons.edit,
      () => showEditSheet(context, controller, task: task)
    ),
    ('删除', Icons.delete_outline, () => deleteTaskWithUndo(context, controller, task)),
  ];

  return showModalBottomSheet<void>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    task.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(ctx).textTheme.titleSmall,
                  ),
                ),
                if (task.type == TaskType.flex && task.deadline == null)
                  const _MenuTag('三无')
                else if (task.type == TaskType.fixed)
                  const _MenuTag('固定时点'),
              ],
            ),
          ),
          for (final (label, icon, action) in entries)
            ListTile(
              leading: Icon(icon, color: AppColors.accent),
              title: Text(label),
              onTap: () async {
                Navigator.of(ctx).pop();
                try {
                  await action();
                } catch (e) {
                  if (ctx.mounted) {
                    ScaffoldMessenger.of(ctx).showSnackBar(
                        SnackBar(content: Text('操作失败：$e')));
                  }
                }
              },
            ),
        ],
      ),
    ),
  );
}

/// 删除 = 软删除（D11）：内核属性文件进 `.gtd/.trash/`、人类文档那一行注释掉
/// + 撤销 toast（约 10 秒），无二次确认。
Future<void> deleteTaskWithUndo(
    BuildContext context, AppController controller, Task task) async {
  await controller.deleteTask(task.id);
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text('已删除「${task.title}」（可在设置回收找回）'),
      // 新版 Flutter 里带 action 的 SnackBar 默认 persist（到点不消失，等用户点
      // action）——与决议 15 的"撤销 toast 约 10 秒"冲突，显式关掉。
      persist: false,
      duration: const Duration(seconds: 10),
      action: SnackBarAction(
        label: '撤销',
        onPressed: () => controller.restoreTask(task.id),
      ),
    ),
  );
}

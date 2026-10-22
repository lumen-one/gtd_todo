import 'package:flutter/material.dart';

import '../../domain/task.dart';
import '../app_controller.dart';
import '../theme.dart';
import '../widgets/task_actions.dart';
import '../widgets/task_tile.dart' show fmtDateTime;
import 'routine_edit_dialog.dart' show routineSubtitle;

/// 任务详情卡（ui-interaction.md §6.1 / §6.3，决议 44）：**点条目 = 只读详情**。
///
/// 与长按菜单的分工是"**点击看、长按做**"：详情卡给列表行塞不下的东西——备注
/// 全文、全部属性、调度派生量（裕度 / 下一次该看它 / 出不出声）；动作还是那几个，
/// 底部按钮直接复用 [taskMenuEntries]，与长按菜单同源，不另写一套。
///
/// 用 bottom sheet 而不是新页面：侧边栏（含系统级悬浮面板）没有路由，
/// 与『编辑』『推迟』两处同款呈现。
Future<void> showTaskDetailSheet(
  BuildContext context,
  AppController controller,
  Task task, {
  required TaskMenuKind kind,
}) {
  // 条目动作在这里就用**外层 context** 建好：点按钮时先收起本卡再执行，
  // 卡自己的 context 那时已经失效（见 [_actions]）。
  final entries = taskMenuEntries(context, controller, task, kind);

  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
            20, 14, 20, 16 + MediaQuery.of(ctx).viewInsets.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _head(ctx, task, kind),
            const SizedBox(height: 8),
            ..._facts(ctx, controller, task),
            if (task.description.trim().isNotEmpty) ...[
              const SizedBox(height: 12),
              _section(ctx, '备注'),
              const SizedBox(height: 4),
              Text(task.description,
                  style: Theme.of(ctx).textTheme.bodyMedium),
            ],
            const Divider(height: 26),
            _actions(context, ctx, entries),
          ],
        ),
      ),
    ),
  );
}

/// 标题 + 组徽标（与列表行的徽标同一套口径）。
Widget _head(BuildContext context, Task task, TaskMenuKind kind) {
  final theme = Theme.of(context);
  final tag = switch (kind) {
    TaskMenuKind.overdue => '逾期',
    TaskMenuKind.fixed => '固定时点',
    TaskMenuKind.picked => '被挑散件',
    TaskMenuKind.inProgress => '挂起中',
    TaskMenuKind.completed => '已完成',
    TaskMenuKind.routine => '例行',
    TaskMenuKind.pool => task.type == TaskType.fixed
        ? '固定时点'
        : (task.deadline == null ? '三无散件' : null),
    _ => null,
  };
  return Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(
        child: Text(
          task.title,
          style: theme.textTheme.titleLarge
              ?.copyWith(fontWeight: FontWeight.w700),
        ),
      ),
      if (tag != null) ...[
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: AppColors.accent.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(tag,
              style: TextStyle(color: AppColors.accent, fontSize: 11.5)),
        ),
      ],
    ],
  );
}

List<Widget> _facts(
    BuildContext context, AppController controller, Task task) {
  final theme = Theme.of(context);
  final metric = controller.schedule?.metricOf(task.id);
  final now = DateTime.now();
  final overdue =
      task.deadline != null && task.deadline!.isBefore(now) && !task.isCompleted;

  final rows = <(String, String)>[
    ('类型', _typeLabel(task)),
    (
      '状态',
      task.isCompleted
          ? '已完成'
          : (task.snoozedUntil != null
              ? '已推迟到 ${fmtDateTime(task.snoozedUntil!)}'
              : (overdue ? '已逾期' : '待办'))
    ),
    (
      task.type == TaskType.flex ? '截止' : '时间',
      task.deadline == null ? '无' : fmtDateTime(task.deadline!)
    ),
    (
      '工时',
      task.type == TaskType.fixed
          ? '不估工时（固定时点）'
          : (task.isLongTerm
              ? '长期（不估工时）'
              : '预计 ${task.estimatedWork} 分 · 剩 ${task.remainingWork} 分')
    ),
    // '长期'任务没有优先级（A3 豁免，D18）——这一行整个不显示。
    if (!task.isLongTerm)
      ('重要度', '${'★' * task.importance!}${'☆' * (5 - task.importance!)}'),
    ('创建', fmtDateTime(task.created)),
    if (task.completedAt != null) ('完成', fmtDateTime(task.completedAt!)),
    if (task.tags.isNotEmpty) ('标签', task.tags.map((t) => '#$t').join(' ')),
  ];

  // 例行实例（决议 23）：实例本身是临时的，详情里给的是它背后的规则。
  final routineId = task.routineId;
  if (routineId != null) {
    final r = controller.routineById(routineId);
    rows.add(('规则', r == null ? '（规则已删除）' : routineSubtitle(r)));
    if (task.routineDate != null) rows.add(('发生日', task.routineDate!));
  }

  // 调度派生量（不落盘，§7.1）：裕度这类"算出来的压力表"照旧可展示；
  // risk / priority 是排序键，界面不显示（顺序本身就是表达）。
  if (!task.isCompleted && metric != null) {
    rows.add(('时间裕度', _fmtMinutes(metric.slackMinutes)));
    rows.add(
      (
        '下次该看',
        metric.nextReminderAt == null
            ? '暂无'
            : fmtDateTime(metric.nextReminderAt!)
      ),
    );
    rows.add(
      (
        '会不会响',
        metric.reminds ? '会' : '不出声'
      ),
    );
    if (metric.intervalMinutes != null) {
      rows.add(('提醒间隔', '${metric.intervalMinutes} 分'));
    }
  }

  // 人的持久意图与标记（都是存在任务上的事实，算不出来的那一类）。
  if (task.pinnedAt != null) rows.add(('插队', '已插队，压在最前'));
  if (task.inProgressAt != null) rows.add(('挂起', '挂起中'));
  // 无排序档不跑定期挑：标记可能还留在任务上（切档不迁移），但不代表什么。
  if (task.pickedForDate != null && !controller.isManualSort) {
    rows.add(('今日', '被挑到今天'));
  }
  if (controller.isManualSort && task.looseHomeIsPool) {
    rows.add(('散件', '住在任务池'));
  }
  if (controller.isManualSort && task.manualOrder != null) {
    rows.add(('手动序', '第 ${task.manualOrder! + 1} 位'));
  }

  return [
    for (final (label, value) in rows)
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 66,
              child: Text(
                label,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(value, style: theme.textTheme.bodyMedium),
            ),
          ],
        ),
      ),
  ];
}

Widget _section(BuildContext context, String label) => Text(
      label,
      style: Theme.of(context).textTheme.labelMedium?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w700),
    );

/// 底部动作：与长按菜单同源（[taskMenuEntries]）。
///
/// 先收起本卡再执行——动作完成后这条任务往往已经从清单里消失（完成 / 删除 /
/// 放回池子），留着一张指向旧数据的卡没有意义。所以失败提示只能用外层
/// context 弹（卡自己的 context 弹出时已失效）。
Widget _actions(BuildContext context, BuildContext sheetContext,
    List<TaskMenuEntry> entries) {
  return Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      for (final (label, icon, action) in entries)
        OutlinedButton.icon(
          icon: Icon(icon, size: 18),
          label: Text(label),
          style: OutlinedButton.styleFrom(
            foregroundColor: label.startsWith('删除')
                ? AppColors.overdueFor(Theme.of(context).brightness)
                : null,
          ),
          onPressed: () async {
            Navigator.of(sheetContext).pop();
            try {
              await action();
            } catch (e) {
              if (context.mounted) {
                ScaffoldMessenger.of(context)
                    .showSnackBar(SnackBar(content: Text('操作失败：$e')));
              }
            }
          },
        ),
    ],
  );
}

String _typeLabel(Task task) => switch (task.type) {
      TaskType.fixed => '不可推（固定时点）',
      TaskType.routine => '例行（当天实例）',
      TaskType.flex => task.deadline == null ? '可推 · 无截止（三无散件）' : '可推（软任务）',
    };

String _fmtMinutes(int m) {
  final abs = m.abs();
  final h = abs ~/ 60;
  final mm = abs % 60;
  final text = h == 0
      ? '$mm 分'
      : (mm == 0 ? '$h 小时' : '$h 小时 $mm 分');
  return m < 0 ? '透支 $text' : '还剩 $text';
}

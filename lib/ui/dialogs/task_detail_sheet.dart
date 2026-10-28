import 'package:flutter/material.dart';

import '../../domain/task.dart';
import '../theme.dart';
import '../widgets/task_tile.dart' show fmtWhen, trailColor;

/// 任务详情卡（ui-interaction.md §6.1 / §6.3，决议 44）：**点条目 = 只读详情**。
///
/// 卡里只有三样：标题、一行时间、备注全文。**没有动作按钮**——"点击看、长按做"，
/// 改数据一律走长按菜单（`taskMenuEntries` 只服务那一处）。属性表与调度派生量
/// 一并移出，代价登记在 docs/architecture.md §11。
///
/// 用 bottom sheet 而不是新页面：侧边栏（含系统级悬浮面板）没有路由，
/// 与『编辑』『推迟』两处同款呈现。
Future<void> showTaskDetailSheet(BuildContext context, Task task) {
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
            Text(
              task.title,
              style: Theme.of(ctx)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            ..._when(ctx, task),
            if (task.description.trim().isNotEmpty) ...[
              const SizedBox(height: 14),
              Text(task.description, style: Theme.of(ctx).textTheme.bodyMedium),
            ],
          ],
        ),
      ),
    ),
  );
}

/// 时间这一块：一行"开始 / 截止 / 发生 <什么时候>"，已完成件再补一行完成时刻。
///
/// 色点与文字取 [trailColor]（日历点色板，逾期转橙红）——卡上的颜色要和列表行、
/// 日历格子对得上，同一个"截止"在三个地方必须是同一颗色。
List<Widget> _when(BuildContext context, Task task) {
  final theme = Theme.of(context);
  final deadline = task.deadline;
  final rows = <Widget>[];

  if (deadline == null) {
    rows.add(_row(
      theme,
      theme.colorScheme.outlineVariant,
      '不排期',
      color: theme.colorScheme.onSurfaceVariant,
    ));
  } else {
    final color = trailColor(context, task);
    final label = switch (task.type) {
      TaskType.flex => '截止',
      TaskType.routine => '发生',
      TaskType.fixed => '开始',
    };
    rows.add(_row(theme, color, '$label ${fmtWhen(deadline)}', color: color));
  }

  final doneAt = task.completedAt;
  if (doneAt != null) {
    if (rows.isNotEmpty) rows.add(const SizedBox(height: 6));
    rows.add(_row(
      theme,
      AppColors.preset.dotsFor(theme.brightness).done,
      '完成 ${fmtWhen(doneAt)}',
      color: theme.colorScheme.onSurfaceVariant,
    ));
  }
  return rows;
}

Widget _row(ThemeData theme, Color dot, String text, {Color? color}) {
  return Row(
    children: [
      Container(
        width: 7,
        height: 7,
        decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: Text(
          text,
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: color, fontWeight: FontWeight.w600),
        ),
      ),
    ],
  );
}

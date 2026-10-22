import 'package:flutter/material.dart';

import '../../domain/task.dart';
import '../app_controller.dart';
import '../dialogs/task_detail_sheet.dart';
import '../theme.dart';
import '../widgets/task_actions.dart';
import '../widgets/task_selection.dart';
import '../widgets/task_tile.dart';

/// 已完成页（ui-interaction.md §6.7；页序见 `ui/panel_pages.dart`）。
///
/// 按完成日期分三组（今天 / 昨天 / 更早），组内完成时刻降序。条目弱化呈现、
/// 无编号、不可拖（历史没有顺序意图）；点条目 = 与今日清单/任务池同一张只读
/// 详情卡，动作只有两个：恢复未完成 / 删除。空态："还没有完成的事"。
///
/// 分组查询在 application 层（`buildCompletedView`），这里只消费结果——UI 不含
/// 逻辑，与今日页/任务池同规则。与调度模式三档无关：存档不参与排序。
class CompletedPanel extends StatelessWidget {
  final AppController controller;
  final TaskSelection selection;

  const CompletedPanel({
    super.key,
    required this.controller,
    required this.selection,
  });

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: selection,
        builder: (context, _) => _build(context),
      );

  Widget _build(BuildContext context) {
    final view = controller.completedView;
    final theme = Theme.of(context);

    if (view.isEmpty) {
      return Center(
        child: FadeIn(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.task_alt_outlined,
                  size: 44, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(height: 8),
              const Text('还没有完成的事'),
            ],
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(0, 6, 0, 96),
      children: [
        if (view.today.isNotEmpty) ...[
          const _GroupHeader('今天'),
          for (final t in view.today) _tile(context, t),
        ],
        if (view.yesterday.isNotEmpty) ...[
          const _GroupHeader('昨天'),
          for (final t in view.yesterday) _tile(context, t),
        ],
        if (view.earlier.isNotEmpty) ...[
          const _GroupHeader('更早'),
          for (final t in view.earlier) _tile(context, t),
        ],
      ],
    );
  }

  Widget _tile(BuildContext context, Task task) => TaskTile(
        controller: controller,
        task: task,
        dimmed: true,
        highlight: task.id == controller.focusedTaskId,
        selecting: selection.selecting,
        selected: selection.contains(task.id),
        // 选择模式下点条目 = 勾选（批量动作只给删除，见 §10#23）。
        onTap: selection.selecting
            ? () => selection.toggle(task.id)
            : () => showTaskDetailSheet(context, controller, task,
                kind: TaskMenuKind.completed),
        onLongPress: selection.selecting
            ? null
            : () => showTaskMenu(context, controller, task,
                kind: TaskMenuKind.completed,
                onSelectMode: () => selection.begin(task.id)),
      );
}

/// 组头：中性色小圆点 + 标签（存档不是状态，不借逾期/强调那些语义色）。
class _GroupHeader extends StatelessWidget {
  final String label;

  const _GroupHeader(this.label);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 4),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
                color: theme.colorScheme.onSurfaceVariant, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(label,
              style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

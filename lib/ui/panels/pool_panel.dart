import 'package:flutter/material.dart';

import '../../application/today_view.dart';
import '../../domain/task.dart';
import '../app_controller.dart';
import '../dialogs/routine_edit_dialog.dart';
import '../dialogs/task_detail_sheet.dart';
import '../theme.dart';
import '../widgets/task_actions.dart';
import '../widgets/task_selection.dart';
import '../widgets/task_tile.dart';

/// 任务池页（ui-interaction.md §6.3；页序见 `ui/panel_pages.dart`）。
/// 一条横线分两段：横线前 = 计划段（未来任务 + 周期规则条目），横线后 =
/// 散件段（三无）。拖拽仅为整理位置（无调度含义），顺序持久化（记 metadata，
/// 重启保留）；新建任务进对应组末尾。空状态："池干水清"。
///
/// 周期条目（决议 27）：按下一次发生日期升序插入计划段对应位置，是否显示
/// 由设置『周期任务在任务池的显示』决定；条目本身只读，点它跳『编辑规则』。
///
/// 多选（§10#23）：[selection] 由面板持有（跨页保留），周期条目**不可勾选**
/// （它不是任务，动作只有"编辑规则"）。
class PoolPanel extends StatelessWidget {
  final AppController controller;
  final TaskSelection selection;

  const PoolPanel({
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
    final view = controller.poolView;
    final theme = Theme.of(context);

    if (view.isEmpty) {
      // 无排序档散件段搬去了今日页底部（v1.27）：池子空了不代表没东西，
      // 文案要说清它们在哪。
      final looseMoved = view.hiddenLooseCount > 0;
      return Center(
        child: FadeIn(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(looseMoved ? Icons.today_outlined : Icons.water_drop_outlined,
                  size: 44, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(height: 8),
              Text(looseMoved ? '散件都在今日清单底部' : '池干水清'),
            ],
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(0, 6, 0, 96),
      children: [
        if (view.rows.isNotEmpty) ...[
          const _SectionLabel('计划段'),
          ReorderableListView(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            onReorder: (o, n) => _persistRows(view.rows, o, n),
            children: [
              for (var i = 0; i < view.rows.length; i++)
                _row(context, theme, view.rows[i], i),
            ],
          ),
        ],
        if (view.rows.isNotEmpty && view.loose.isNotEmpty)
          const _PoolDivider(),
        if (view.loose.isNotEmpty)
          ReorderableListView(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            onReorder: (o, n) => _persistOrder(view.loose, o, n),
            children: [
              for (var i = 0; i < view.loose.length; i++)
                TaskTile(
                  key: ValueKey('loose-${view.loose[i].id}'),
                  controller: controller,
                  task: view.loose[i],
                  highlight: view.loose[i].id == controller.focusedTaskId,
                  selecting: selection.selecting,
                  selected: selection.contains(view.loose[i].id),
                  onTap: _tap(context, view.loose[i]),
                  onLongPress: _longPress(context, view.loose[i]),
                  trailing: _grip(i, theme),
                ),
            ],
          ),
      ],
    );
  }

  /// 计划段的一行：任务行可拖，周期条目只读（点它跳设置页『编辑规则』）。
  Widget _row(BuildContext context, ThemeData theme, PoolRow row, int index) {
    if (row is PoolRoutineRow) {
      final focused = controller.settingsFocusRoutineId == row.routine.id;
      return Card(
        key: ValueKey('routine-${row.routine.id}-${row.at.millisecondsSinceEpoch}'),
        margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        shape: focused
            ? RoundedRectangleBorder(
                side: BorderSide(color: AppColors.accent, width: 1.6),
                borderRadius: BorderRadius.circular(14),
              )
            : null,
        child: ListTile(
          dense: true,
          leading: Icon(Icons.repeat, size: 18, color: AppColors.accent),
          title: Text(row.routine.title, maxLines: 1,
              overflow: TextOverflow.ellipsis),
          subtitle: Text(
            '${routineSubtitle(row.routine)} · ${_fmtDay(row.at)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: const Text('例行', style: TextStyle(fontSize: 11.5)),
          onTap: () => controller.focusRoutineInSettings(row.routine.id),
        ),
      );
    }
    final task = (row as PoolTaskRow).task;
    return TaskTile(
      key: ValueKey('plan-${task.id}'),
      controller: controller,
      task: task,
      highlight: task.id == controller.focusedTaskId,
      selecting: selection.selecting,
      selected: selection.contains(task.id),
      onTap: _tap(context, task),
      onLongPress: _longPress(context, task),
      trailing: _grip(index, theme),
    );
  }

  /// 点条目：选择模式下是勾选，平时是详情卡（与今日页同款）。
  VoidCallback _tap(BuildContext context, Task task) => selection.selecting
      ? () => selection.toggle(task.id)
      : () => showTaskDetailSheet(context, controller, task,
          kind: TaskMenuKind.pool);

  VoidCallback? _longPress(BuildContext context, Task task) =>
      selection.selecting
          ? null
          : () => showPoolMenu(context, controller, task,
              onSelectMode: () => selection.begin(task.id));

  /// 拖把手：选择模式下不渲染 = 那两段不可拖。
  Widget? _grip(int i, ThemeData theme) => selection.selecting
      ? null
      : ReorderableDragStartListener(
          index: i,
          child: Icon(Icons.drag_handle,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6)),
        );

  /// 拖拽整理 = 仅显示序（决议 14）：整段重编 pool_order，重启保留。
  /// 周期条目不可拖：拖动后取"任务行的相对顺序"落盘。
  ///
  /// 无排序模式下改为写 `manual_order`（决议 43）——与今日清单共用同一个序号，
  /// 两处顺序一致；pool_order 是自动模式下的"整理序"，两套各管各的。
  Future<void> _persistRows(List<PoolRow> rows, int oldIndex, int newIndex) async {
    if (rows[oldIndex] is! PoolTaskRow) return;
    final insert = newIndex > oldIndex ? newIndex - 1 : newIndex;
    final list = [...rows]
      ..removeAt(oldIndex)
      ..insert(insert, rows[oldIndex]);
    final ids = [
      for (final r in list)
        if (r is PoolTaskRow) r.task.id,
    ];
    await controller.setPoolOrders(ids);
  }

  Future<void> _persistOrder(
      List<Task> section, int oldIndex, int newIndex) async {
    final insert = newIndex > oldIndex ? newIndex - 1 : newIndex;
    final ids = [for (final t in section) t.id]
      ..removeAt(oldIndex)
      ..insert(insert, section[oldIndex].id);
    await controller.setPoolOrders(ids);
  }

  static String _fmtDay(DateTime d) =>
      '${d.month}-${d.day.toString().padLeft(2, '0')}'
      '${d.hour == 0 && d.minute == 0 ? '' : ' ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}'}';
}

class _SectionLabel extends StatelessWidget {
  final String label;

  const _SectionLabel(this.label);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(18, 10, 18, 4),
        child: Text(label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w700)),
      );
}

class _PoolDivider extends StatelessWidget {
  const _PoolDivider();

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 18),
        child: Row(
          children: [
            const Expanded(child: Divider()),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Text('散件',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant)),
            ),
            const Expanded(child: Divider()),
          ],
        ),
      );
}

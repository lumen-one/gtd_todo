import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../dialogs/create_task_sheet.dart' show showCreateFlow;
import '../theme.dart';
import 'task_selection.dart';

/// 面板右下角那一块（§6.1 / §10#23）：平时是两个浮出钮（日历 + 添加待办），
/// **选择模式下整块换成批处理条**（同一位置，不另起一行）。
///
/// 两个宿主（[SidePanel] 与应用内抽屉）共用：[selection] 由宿主持有并往下传
/// （选中跨页保留），这里只按状态决定摆哪一条。Positioned 必须直接挂在
/// Stack 上，所以它包着 AnimatedBuilder 而不是反过来。
class PanelDock extends StatelessWidget {
  final AppController controller;
  final TaskSelection selection;
  final VoidCallback onOpenCalendar;
  final String heroTagPrefix;

  const PanelDock({
    super.key,
    required this.controller,
    required this.selection,
    required this.onOpenCalendar,
    this.heroTagPrefix = 'panel',
  });

  @override
  Widget build(BuildContext context) {
    return Positioned(
      right: 14,
      bottom: 14,
      child: FadeIn(
        offset: 14,
        child: AnimatedBuilder(
          animation: selection,
          builder: (context, _) => AnimatedSwitcher(
            duration: const Duration(milliseconds: 160),
            child: selection.selecting
                ? SelectionBar(
                    key: const ValueKey('panel-dock-selection'),
                    controller: controller,
                    selection: selection,
                  )
                : _ActionsRow(
                    key: const ValueKey('panel-dock-actions'),
                    controller: controller,
                    onOpenCalendar: onOpenCalendar,
                    heroTagPrefix: heroTagPrefix,
                  ),
          ),
        ),
      ),
    );
  }
}

/// 日历 + 添加待办。[heroTagPrefix] 区分面板/抽屉/悬浮窗几处实例，
/// 避免 Hero 标签冲突。
class _ActionsRow extends StatelessWidget {
  final AppController controller;
  final VoidCallback onOpenCalendar;
  final String heroTagPrefix;

  const _ActionsRow({
    super.key,
    required this.controller,
    required this.onOpenCalendar,
    this.heroTagPrefix = 'panel',
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        FloatingActionButton.small(
          heroTag: '$heroTagPrefix-calendar',
          tooltip: '日历',
          onPressed: () => onOpenCalendar(),
          child: const Icon(Icons.calendar_month_outlined),
        ),
        const SizedBox(width: 8),
        FloatingActionButton(
          heroTag: '$heroTagPrefix-create-task',
          tooltip: '添加待办',
          onPressed: () => showCreateFlow(context, controller),
          child: const Icon(Icons.add),
        ),
      ],
    );
  }
}

/// 选择模式的批处理条（§10#23）：动作固定两颗，**不随页换**——
/// 『完成』的计数只数未完成的（已完成页选中的东西不能再完成，计数 0 时不可用），
/// 『删除』数全部。选中跨页保留，所以这里不去看"当前是哪一页"。
class SelectionBar extends StatelessWidget {
  final AppController controller;
  final TaskSelection selection;

  const SelectionBar({
    super.key,
    required this.controller,
    required this.selection,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ids = selection.selectedIds;
    final completable = [
      for (final t in controller.tasks)
        if (selection.contains(t.id) && !t.isCompleted) t.id,
    ];

    return Material(
      color: theme.cardTheme.color ?? theme.colorScheme.surface,
      elevation: 6,
      shadowColor: Colors.black26,
      borderRadius: BorderRadius.circular(999),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              iconSize: 18,
              visualDensity: VisualDensity.compact,
              tooltip: '取消',
              icon: const Icon(Icons.close),
              onPressed: selection.cancel,
            ),
            Text('已选 ${ids.length}', style: theme.textTheme.labelMedium),
            const SizedBox(width: 8),
            _ActionPill(
              icon: Icons.check,
              label: '${completable.length}',
              color: AppColors.accent,
              onTap: completable.isEmpty
                  ? null
                  : () => _complete(context, completable),
            ),
            const SizedBox(width: 6),
            _ActionPill(
              icon: Icons.delete_outline,
              label: '${ids.length}',
              color: theme.colorScheme.error,
              onTap: ids.isEmpty ? null : () => _delete(context, ids),
            ),
          ],
        ),
      ),
    );
  }

  /// 批量完成（不进回收站）：先退出选择模式再发命令——条子上的计数跟着集合走，
  /// 留着它反而会在命令回程时显示一批已经不在选中的数字。
  Future<void> _complete(BuildContext context, List<String> ids) async {
    selection.cancel();
    await controller.completeTasks(ids);
    if (!context.mounted) return;
    _toast(context, '已完成 ${ids.length} 件');
  }

  /// 批量删除（软删除）+ 撤销：一次删多件时撤销恢复这一批。
  Future<void> _delete(BuildContext context, List<String> ids) async {
    selection.cancel();
    await controller.deleteTasks(ids);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已删除 ${ids.length} 件'),
        // 带 action 的 SnackBar 默认 persist（到点不消失），显式关掉（决议 15）。
        persist: false,
        duration: const Duration(seconds: 4),
        action: SnackBarAction(
          label: '撤销',
          onPressed: () => controller.restoreTasks(ids),
        ),
      ),
    );
  }

  void _toast(BuildContext context, String text) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 3)),
    );
  }
}

/// 条子上的动作按钮：图标 + 计数，计数为 0（或不可用）时压暗且不响应。
class _ActionPill extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback? onTap;

  const _ActionPill({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Opacity(
      opacity: enabled ? 1 : 0.35,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  color: color,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

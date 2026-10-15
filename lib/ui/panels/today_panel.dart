import 'dart:math';

import 'package:flutter/material.dart';

import '../../application/today_view.dart';
import '../../domain/task.dart';
import '../app_controller.dart';
import '../dialogs/task_detail_sheet.dart';
import '../theme.dart';
import '../widgets/task_actions.dart';
import '../widgets/task_tile.dart';

/// 第 1 页：今日清单（ui-interaction.md §6.1）。
/// 分组连续编号：⓿ 挂起进行（无编号、最顶，决议 47）→ ① 逾期（无编号）→
/// ② 固定时点 → ③ 可推（插队件栈式压顶 + 调度序）→ ④ 例行（未落地恒空）→
/// ⑤ 被挑散件（无编号、弱化）。
/// 编号跨 ②③④ 连续；插队拖拽仅对可推组生效，挂起组拖拽仅组内调序（决议 47）。
class TodayPanel extends StatelessWidget {
  final AppController controller;

  const TodayPanel({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    final view = controller.todayView;
    final theme = Theme.of(context);

    if (view.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.wb_sunny_outlined,
                size: 44, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 8),
            const Text('今天没有会响的事'),
            const SizedBox(height: 12),
            FilledButton.tonal(
              onPressed: () => _pickRandom(context),
              child: const Text('从池子随机挑一件'),
            ),
          ],
        ),
      );
    }

    var number = 0;
    final combined = [...view.pinned, ...view.flex];

    return ListView(
      padding: const EdgeInsets.fromLTRB(0, 6, 0, 96),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 6),
          child: Text(_dateLabel(view.day), style: theme.textTheme.titleMedium),
        ),
        // ⓿ 挂起组：长期任务"正在做"（v0.17，决议 47）：无编号、置于本页最顶
        // （逾期组之上），组内可上下拖动调序；三档调度模式下都在。
        if (view.inProgress.isNotEmpty) ...[
          _GroupHeader('挂起进行', color: AppColors.accent),
          ReorderableListView(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            // 新代码用 onReorderItem（newIndex 已按"移除旧位"调整好，直接插）；
            // 本文件另两处还是旧 onReorder（deprecation info 是既有基线，不混改）。
            onReorderItem: (o, n) => _onInProgressReorder(view.inProgress, o, n),
            children: [
              for (var i = 0; i < view.inProgress.length; i++)
                TaskTile(
                  key: ValueKey('inprogress-${view.inProgress[i].id}'),
                  controller: controller,
                  task: view.inProgress[i],
                  highlight: view.inProgress[i].id == controller.focusedTaskId,
                  onTap: () => showTaskDetailSheet(context, controller,
                      view.inProgress[i],
                      kind: TaskMenuKind.inProgress),
                  onLongPress: () => showTaskMenu(context, controller,
                      view.inProgress[i],
                      kind: TaskMenuKind.inProgress),
                  trailing: ReorderableDragStartListener(
                    index: i,
                    child: Icon(Icons.drag_handle,
                        size: 18,
                        color: theme.colorScheme.onSurfaceVariant
                            .withValues(alpha: 0.6)),
                  ),
                ),
            ],
          ),
        ],
        // ① 逾期组：无编号、橙红置顶，完成/改期前不消失（决议 2）
        if (view.overdue.isNotEmpty) ...[
          _GroupHeader('逾期', color: AppColors.overdueFor(theme.brightness)),
          for (final t in view.overdue)
            TaskTile(
              controller: controller,
              task: t,
              onTap: () => showTaskDetailSheet(context, controller, t,
                  kind: TaskMenuKind.overdue),
              onLongPress: () => showTaskMenu(context, controller, t,
                  kind: TaskMenuKind.overdue),
            ),
        ],
        // ② 固定时点组：时间升序、组内不可拖（时间就是序）
        if (view.fixed.isNotEmpty) ...[
          const _GroupHeader('固定时点', color: AppColors.timeBadge),
          for (final t in view.fixed)
            TaskTile(
              controller: controller,
              task: t,
              number: ++number,
              onTap: () => showTaskDetailSheet(context, controller, t,
                  kind: TaskMenuKind.fixed),
              onLongPress: () => showTaskMenu(context, controller, t,
                  kind: TaskMenuKind.fixed),
            ),
        ],
        // ③ 可推组：插队件（栈式压顶）+ 调度序；拖把手插队
        if (combined.isNotEmpty)
          _GroupHeader('可推', color: AppColors.accent),
        ReorderableListView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          onReorder: (oldIndex, newIndex) =>
              _onReorder(view, combined, oldIndex, newIndex),
          children: [
            for (var i = 0; i < combined.length; i++)
              TaskTile(
                key: ValueKey('today-${combined[i].id}'),
                controller: controller,
                task: combined[i],
                number: ++number,
                highlight: combined[i].id == controller.focusedTaskId,
                onTap: () => showTaskDetailSheet(context, controller,
                    combined[i],
                    kind: TaskMenuKind.flex),
                onLongPress: () => showTaskMenu(context, controller,
                    combined[i],
                    kind: TaskMenuKind.flex),
                trailing: ReorderableDragStartListener(
                  index: i,
                  child: Icon(Icons.drag_handle,
                      size: 18,
                      color: theme.colorScheme.onSurfaceVariant
                          .withValues(alpha: 0.6)),
                ),
              ),
          ],
        ),
        // ④ 例行组：周期任务当天实例（决议 12：不占工时、默认不响、
        // 参与连续编号；菜单见决议 23——无『推迟』）
        if (view.routines.isNotEmpty) ...[
          const _GroupHeader('例行', color: AppColors.timeBadge),
          for (final t in view.routines)
            TaskTile(
              controller: controller,
              task: t,
              number: ++number,
              highlight: t.id == controller.focusedTaskId,
              onTap: () => showTaskDetailSheet(context, controller, t,
                  kind: TaskMenuKind.routine),
              onLongPress: () => showTaskMenu(context, controller, t,
                  kind: TaskMenuKind.routine),
            ),
        ],
        // ⑤ 被挑散件：弱化呈现、无编号（决议 25）
        if (view.picked != null) ...[
          const _GroupHeader('被挑散件', color: Colors.blueGrey),
          TaskTile(
            controller: controller,
            task: view.picked!,
            dimmed: true,
            highlight: view.picked!.id == controller.focusedTaskId,
            onTap: () => showTaskDetailSheet(context, controller, view.picked!,
                kind: TaskMenuKind.picked),
            onLongPress: () => showTaskMenu(context, controller, view.picked!,
                kind: TaskMenuKind.picked),
          ),
        ],
      ],
    );
  }

  /// 挂起组拖拽落位（决议 47）：整段重写挂起时刻（越靠上时刻越新 = 后挂在上），
  /// 一次落盘 + 一个事件 + 一次重算（arch §3.5 通用约束，同插队栈）。
  ///
  /// 走 `onReorderItem`：[newIndex] 已按"移除旧位"调整过，直接就是落点。
  Future<void> _onInProgressReorder(
      List<Task> inProgress, int oldIndex, int newIndex) async {
    final order = [...inProgress]
      ..removeAt(oldIndex)
      ..insert(newIndex, inProgress[oldIndex]);
    await controller.setInProgressStack([for (final t in order) t.id]);
  }

  /// 拖拽落位，两种排序模式两套语义（决议 43）：
  ///
  /// - **无排序档** = 定序：整组按拖动结果重编 `manual_order`，重启保留；
  /// - **标准 / 完整档** = 插队（决议 9/11）：拖进插队区即插队，插队件按当前
  ///   视觉顺序重新栈式落位（后插在上，保持到完成）。
  Future<void> _onReorder(TodayView view, List<Task> combined, int oldIndex,
      int newIndex) async {
    final insert = newIndex > oldIndex ? newIndex - 1 : newIndex;

    if (controller.isManualSort) {
      final newOrder = [...combined]
        ..removeAt(oldIndex)
        ..insert(insert, combined[oldIndex]);
      await controller.setManualOrder([for (final t in newOrder) t.id]);
      return;
    }

    final item = combined[oldIndex];
    final oldPinnedCount = view.pinned.length;
    // 插队区 = 已有插队件那一段。**段为空时必须允许拖到最顶**：那时
    // `insert >= oldPinnedCount` 恒真，第一次插队根本进不来。落到插队区以外
    // = 这段的先后交给算法，拖动在这里是空操作。
    final intoPinned = insert < oldPinnedCount || insert == 0;
    if (!intoPinned) return;

    final targetPinnedCount =
        item.pinnedAt == null ? oldPinnedCount + 1 : oldPinnedCount;
    final newOrder = [...combined]
      ..removeAt(oldIndex)
      ..insert(insert, item);
    final stack = newOrder.take(targetPinnedCount).toList();
    // 整段一次落盘：越靠上插队时刻越新（栈式，后插在上，决议 9）。
    await controller.setPinnedStack([for (final t in stack) t.id]);
  }

  Future<void> _pickRandom(BuildContext context) async {
    final loose = controller.poolView.loose;
    if (loose.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('池子里没有散件可挑')));
      return;
    }
    await controller.pickForToday(loose[Random().nextInt(loose.length)].id);
  }
}

String _dateLabel(DateTime d) {
  const weeks = ['一', '二', '三', '四', '五', '六', '日'];
  return '${d.month} 月 ${d.day} 日 · 周${weeks[d.weekday - 1]}';
}

class _GroupHeader extends StatelessWidget {
  final String label;
  final Color color;

  const _GroupHeader(this.label, {required this.color});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 4),
        child: Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
            Text(label,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: color, fontWeight: FontWeight.w700)),
          ],
        ),
      );
}

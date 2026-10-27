import 'dart:math';

import 'package:flutter/material.dart';

import '../../application/today_view.dart';
import '../../domain/task.dart';
import '../app_controller.dart';
import '../dialogs/task_detail_sheet.dart';
import '../theme.dart';
import '../widgets/task_actions.dart';
import '../widgets/task_selection.dart';
import '../widgets/task_tile.dart';

/// 今日清单页（ui-interaction.md §6.1；页序见 `ui/panel_pages.dart`）。
/// 分组连续编号：⓿ 挂起进行（无编号、最顶，决议 47）→ ① 逾期（无编号）→
/// ② 开始型 → ③ 截止型（插队件栈式压顶 + 调度序）→ ④ 例行（未落地恒空）→
/// ⑤ 被挑散件（无编号、弱化）→ ⑥ 散件段（v1.27，仅无排序档、页底）。
/// 编号跨 ②③④ 连续；插队拖拽仅对截止型组生效，挂起组拖拽仅组内调序（决议 47）。
///
/// 多选（§10#23）：[selection] 由面板持有（跨页保留），这里只把它落到条目上——
/// 选择模式下点条目 = 勾选、拖把手不渲染、下拉进编排也不接。
class TodayPanel extends StatelessWidget {
  final AppController controller;
  final TaskSelection selection;

  const TodayPanel({
    super.key,
    required this.controller,
    required this.selection,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: selection,
      builder: (context, _) => _build(context),
    );
  }

  Widget _build(BuildContext context) {
    final view = controller.todayView;
    final theme = Theme.of(context);

    if (view.isEmpty) {
      // 空态也要能下拉进编排（§6.11）：所以是一张可滚的列表，不是居中一块——
      // "今天清单空着"恰恰是最想编排的时候。日期行照留——支线的入口在那儿
      // （§6.12），空态只把提示往下推。
      return _withPlanPull(
        ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.only(bottom: 96),
          children: [
            _dateRow(theme, view.day),
            Padding(
              padding: const EdgeInsets.only(top: 84),
              child: FadeIn(
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
              ),
            ),
          ],
        ),
      );
    }

    var number = 0;
    final combined = [...view.pinned, ...view.flex];

    final list = ListView(
      // 内容不满一屏时也要能拖（否则短清单没有 overscroll，编排进不去）。
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(0, 6, 0, 96),
      children: [
        _dateRow(theme, view.day),
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
                  selecting: selection.selecting,
                  selected: selection.contains(view.inProgress[i].id),
                  onTap:
                      _tap(context, view.inProgress[i], TaskMenuKind.inProgress),
                  onLongPress: _longPress(
                      context, view.inProgress[i], TaskMenuKind.inProgress),
                  trailing: _grip(i, theme),
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
              selecting: selection.selecting,
              selected: selection.contains(t.id),
              onTap: _tap(context, t, TaskMenuKind.overdue),
              onLongPress: _longPress(context, t, TaskMenuKind.overdue),
            ),
        ],
        // ② 开始型组：时间升序、组内不可拖（时间就是序）
        if (view.fixed.isNotEmpty) ...[
          const _GroupHeader('开始型', color: AppColors.timeBadge),
          for (final t in view.fixed)
            TaskTile(
              controller: controller,
              task: t,
              number: ++number,
              selecting: selection.selecting,
              selected: selection.contains(t.id),
              onTap: _tap(context, t, TaskMenuKind.fixed),
              onLongPress: _longPress(context, t, TaskMenuKind.fixed),
            ),
        ],
        // ③ 截止型组：插队件（栈式压顶）+ 调度序；拖把手插队
        if (combined.isNotEmpty)
          _GroupHeader('截止型', color: AppColors.accent),
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
                selecting: selection.selecting,
                selected: selection.contains(combined[i].id),
                onTap: _tap(context, combined[i], TaskMenuKind.flex),
                onLongPress:
                    _longPress(context, combined[i], TaskMenuKind.flex),
                trailing: _grip(i, theme),
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
              selecting: selection.selecting,
              selected: selection.contains(t.id),
              onTap: _tap(context, t, TaskMenuKind.routine),
              onLongPress: _longPress(context, t, TaskMenuKind.routine),
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
            selecting: selection.selecting,
            selected: selection.contains(view.picked!.id),
            onTap: _tap(context, view.picked!, TaskMenuKind.picked),
            onLongPress: _longPress(context, view.picked!, TaskMenuKind.picked),
          ),
        ],
        // ⑥ 散件段（v1.27，仅无排序档）：池子里的三无散件整段铺在本页最底，
        // 不编号、弱化；拖动只改整理序（`pool_order`），与 ③ 的手动序是两套序号。
        if (view.loose.isNotEmpty) ...[
          const _GroupHeader('散件', color: Colors.blueGrey),
          ReorderableListView(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            onReorderItem: (oldIndex, newIndex) =>
                _onLooseReorder(view.loose, oldIndex, newIndex),
            children: [
              for (var i = 0; i < view.loose.length; i++)
                TaskTile(
                  key: ValueKey('today-loose-${view.loose[i].id}'),
                  controller: controller,
                  task: view.loose[i],
                  dimmed: true,
                  highlight: view.loose[i].id == controller.focusedTaskId,
                  selecting: selection.selecting,
                  selected: selection.contains(view.loose[i].id),
                  onTap: _tap(context, view.loose[i], TaskMenuKind.loose),
                  onLongPress:
                      _longPress(context, view.loose[i], TaskMenuKind.loose),
                  trailing: _grip(i, theme),
                ),
            ],
          ),
        ],
      ],
    );
    return _withPlanPull(list);
  }

  /// 顶部日期行 + 右端的支线入口（§6.12）。
  ///
  /// 支线未装配时只剩日期——不为一个进不去的地方摆颗按钮。日期与按钮同一行：
  /// 窄面板 240dp 上也放得下 `10 月 25 日 · 周日` 加一颗 34dp 的图标钮。
  Widget _dateRow(ThemeData theme, DateTime day) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 6, 8, 2),
      child: Row(
        children: [
          Expanded(
            child: Text(_dateLabel(day), style: theme.textTheme.titleMedium),
          ),
          if (controller.hasBranches)
            IconButton(
              tooltip: '支线',
              iconSize: 20,
              color: theme.colorScheme.onSurfaceVariant,
              style: IconButton.styleFrom(
                minimumSize: const Size(34, 34),
                padding: EdgeInsets.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              icon: const Icon(Icons.call_split),
              onPressed: controller.openBranch,
            ),
        ],
      ),
    );
  }

  /// 点条目：选择模式下是勾选，平时是详情卡（"点击看、长按做"）。
  VoidCallback _tap(BuildContext context, Task t, TaskMenuKind kind) =>
      selection.selecting
          ? () => selection.toggle(t.id)
          : () => showTaskDetailSheet(context, controller, t, kind: kind);

  /// 长按：选择模式下不给菜单（`null` → InkWell 不响应长按）；平时弹菜单，
  /// 菜单最后一行『多选』把这条一并选上（§10#23）。
  VoidCallback? _longPress(BuildContext context, Task t, TaskMenuKind kind) =>
      selection.selecting
          ? null
          : () => showTaskMenu(context, controller, t,
              kind: kind, onSelectMode: () => selection.begin(t.id));

  /// 拖把手：选择模式下不渲染 = 那一段不可拖（勾选时没有"调顺序"的意图）。
  Widget? _grip(int index, ThemeData theme) => selection.selecting
      ? null
      : ReorderableDragStartListener(
          index: index,
          child: Icon(Icons.drag_handle,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6)),
        );

  /// 今日页是编排的入口（§6.11）：**已经滚到顶**还继续往下拉，就把行程喂给控制器。
  ///
  /// 只认手指拖（`dragDetails != null`）：鼠标滚轮与触控板"滚到头继续滚"是常态，
  /// 认了就是天天误触。`depth != 0` 的是内层 ReorderableListView 的通知，跳过。
  /// 选择模式下整条手势不接：手上正拿着"选中"的意图，下拉只会误触（§10#23）。
  Widget _withPlanPull(Widget child) {
    if (selection.selecting) return child;
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.depth != 0) return false;
        if (n is OverscrollNotification && n.dragDetails != null) {
          // 顶部继续下拉时 overscroll 是负的（像素已经不能再减）。
          controller.pullPlan(-n.overscroll);
        } else if (n is ScrollEndNotification) {
          // 向下甩（dy > 0）才算"补满"，与把手的快甩同档（§6.0）。
          controller
              .settlePlan(n.dragDetails?.velocity.pixelsPerSecond.dy ?? 0);
        }
        return false;
      },
      child: child,
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

  /// ⑥ 散件段拖拽落位（v1.27）：只改整理序（`pool_order`），与 ③ 的手动序无关。
  /// 被挑中的那件不在这一段里，序号原样留着——明天回池子还在原处。
  ///
  /// 走 `onReorderItem`：[newIndex] 已按"移除旧位"调整过，直接就是落点。
  Future<void> _onLooseReorder(
      List<Task> loose, int oldIndex, int newIndex) async {
    final ids = [for (final t in loose) t.id]
      ..removeAt(oldIndex)
      ..insert(newIndex, loose[oldIndex].id);
    await controller.setPoolOrders(ids);
  }

  Future<void> _pickRandom(BuildContext context) async {
    // 无排序档没有"挑"这一层（⑤ 不存在）：把池子里的那件搬回 ⑥ 就是
    // "今天做它"——搬过池子的散件此刻只在池子那一段里。
    if (controller.isManualSort) {
      final moved = controller.poolView.loose;
      if (moved.isEmpty) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('池子里没有散件可挑')));
        return;
      }
      await controller.setLooseHome(
          moved[Random().nextInt(moved.length)].id,
          pool: false);
      return;
    }
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

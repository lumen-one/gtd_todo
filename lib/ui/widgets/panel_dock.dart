import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;
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
///
/// [hidden] 是宿主给的"藏起来"开关（列表上滑时置位，见 [DockScrollListener]）；
/// null = 这个宿主不做上滑藏钮，永远显示。
class PanelDock extends StatelessWidget {
  final AppController controller;
  final TaskSelection selection;
  final VoidCallback onOpenCalendar;
  final String heroTagPrefix;
  final ValueListenable<bool>? hidden;

  const PanelDock({
    super.key,
    required this.controller,
    required this.selection,
    required this.onOpenCalendar,
    this.heroTagPrefix = 'panel',
    this.hidden,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned(
      right: 14,
      bottom: 14,
      child: _DockSlide(
        hidden: hidden,
        selection: selection,
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
      ),
    );
  }
}

/// 藏起来那一下：往下移出面板 + 淡出，180ms（时长登记在 docs/panels/README.md
/// 的过渡表里）。
///
/// **选择模式一律显示**：批处理条是刚长按出来的，藏在屏外就没法用了。
/// 藏时必须 `IgnorePointer`——透明但还能点到的钮比不藏更糟。
class _DockSlide extends StatelessWidget {
  final ValueListenable<bool>? hidden;
  final TaskSelection selection;
  final Widget child;

  const _DockSlide({
    required this.hidden,
    required this.selection,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final h = hidden;
    if (h == null) return child;
    return AnimatedBuilder(
      animation: Listenable.merge([h, selection]),
      builder: (context, c) {
        final hide = h.value && !selection.selecting;
        return IgnorePointer(
          ignoring: hide,
          child: AnimatedSlide(
            offset: hide ? const Offset(0, 1.2) : Offset.zero,
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            child: AnimatedOpacity(
              opacity: hide ? 0 : 1,
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              child: c,
            ),
          ),
        );
      },
      child: child,
    );
  }
}

/// 列表上滑就把双钮藏起来（§6.1）：宿主持有 [hidden]，滚动只往它里面写。
///
/// 只认**纵向**的滚动通知——面板里那层横向 PageView 也会冒通知上来，按
/// `metrics.axis` 筛；**不按 `depth` 筛**，页面列表冒到这一层时 `depth`
/// 已经是 1（与编排页的退出手势同一个坑，见 `plan_panel.dart`）。
///
/// 藏 = 手指往上推累计过 12dp；回来只认**下滑**或**滚回顶部**——停手不自动
/// 弹回（宿主换页时自己复位）。
class DockScrollListener extends StatefulWidget {
  final ValueNotifier<bool> hidden;
  final Widget child;

  const DockScrollListener({
    super.key,
    required this.hidden,
    required this.child,
  });

  @override
  State<DockScrollListener> createState() => _DockScrollListenerState();
}

class _DockScrollListenerState extends State<DockScrollListener> {
  /// 上推多少才算"真的在往前读"：一两个像素是点按带出来的抖动。
  static const double _hideAfter = 12;

  double _up = 0;

  bool _onScroll(ScrollNotification n) {
    if (n.metrics.axis != Axis.vertical) return false;
    if (n is ScrollStartNotification) {
      _up = 0;
    } else if (n is ScrollUpdateNotification) {
      final dy = n.scrollDelta ?? 0;
      if (dy > 0) {
        _up += dy;
        if (_up >= _hideAfter) _set(true);
      } else if (dy < 0) {
        _up = 0;
        _set(false);
      }
      // 已经在最顶：再往上没有内容可读，钮留着。
      if (n.metrics.extentBefore <= 0) _set(false);
    } else if (n is OverscrollNotification && n.overscroll < 0) {
      // 到顶之后继续下拉（今日编排的入口）。
      _set(false);
    }
    return false;
  }

  void _set(bool hidden) {
    if (widget.hidden.value == hidden) return;
    widget.hidden.value = hidden;
  }

  @override
  Widget build(BuildContext context) => NotificationListener<ScrollNotification>(
        onNotification: _onScroll,
        child: widget.child,
      );
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

import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../dialogs/create_task_dialog.dart';
import '../dialogs/quick_dump_dialog.dart';
import '../theme.dart';
import 'notes_panel.dart';
import 'pool_panel.dart';
import 'today_panel.dart';

/// 侧边栏面板本体（§5.1：panels 平台无关，只被 shell 摆放）。
///
/// **两个宿主共用这一份**（v1.5）：
/// - 应用内安卓壳（`AndroidShell`）：贴屏把手拖出 → 面板滑入；
/// - **系统级悬浮窗**（`overlay_main.dart`，跑在原生前台服务的第二个引擎里）：
///   在其他 App 上方就地展开同一个面板，日常操作不必离开当前 App。
///
/// 三页竖翻（今日清单 → 疑问笔记 → 任务池）、重手势翻页、右下角添加区都在这里；
/// 宿主只负责"摆哪儿、怎么进出"（滑入动画 / 悬浮窗口 / 抽屉）。
class SidePanel extends StatefulWidget {
  final AppController controller;
  final PageController pageCtrl;

  /// 上下重手势翻页回调（宿主提供高度/累积量判定）。
  final void Function(DragEndDetails d, double accum) onPageDragEnd;
  final VoidCallback onClose;
  final VoidCallback onPrivacy;
  final VoidCallback onOpenCalendar;

  /// 悬浮窗宿主的"进应用"入口（打开设置页）；null = 不显示该按钮。
  final VoidCallback? onOpenSettings;

  /// Hero 标签前缀：同一棵树里放两份面板时要区分（抽屉兜底 / 悬浮窗）。
  final String heroTagPrefix;

  const SidePanel({
    super.key,
    required this.controller,
    required this.pageCtrl,
    required this.onPageDragEnd,
    required this.onClose,
    required this.onPrivacy,
    required this.onOpenCalendar,
    this.onOpenSettings,
    this.heroTagPrefix = 'panel',
  });

  @override
  State<SidePanel> createState() => _SidePanelState();
}

class _SidePanelState extends State<SidePanel> {
  static const _pageNames = ['今日清单', '疑问笔记', '任务池'];
  double _pageDragAccum = 0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = widget.controller;

    return Material(
      borderRadius: BorderRadius.circular(20),
      color: theme.scaffoldBackgroundColor,
      elevation: 8,
      shadowColor: Colors.black38,
      child: SafeArea(
        bottom: false,
        child: Column(
          children: [
            // 面板头：页名 + 翻页点（重手势区）+ 日历 / 隐私 / 设置? / 关闭
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
              child: Row(
                children: [
                  AnimatedBuilder(
                    animation: widget.pageCtrl,
                    builder: (context, _) => Text(
                      _pageNames[(widget.pageCtrl.hasClients
                              ? (widget.pageCtrl.page ?? 0)
                              : 0)
                          .round()],
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: '日历',
                    icon: const Icon(Icons.calendar_month_outlined, size: 20),
                    onPressed: widget.onOpenCalendar,
                  ),
                  IconButton(
                    tooltip: '隐私过头（只留输入）',
                    icon: const Icon(Icons.visibility_off_outlined, size: 20),
                    onPressed: widget.onPrivacy,
                  ),
                  if (widget.onOpenSettings != null)
                    IconButton(
                      tooltip: '打开应用设置（周期任务 / 主题 / 权限）',
                      icon: const Icon(Icons.settings_outlined, size: 20),
                      onPressed: widget.onOpenSettings,
                    ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: widget.onClose,
                  ),
                ],
              ),
            ),
            // 翻页区：点击左右半区翻页 + 上下重手势（行程/速度阈值放大）
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (d) {
                final w = context.size?.width ?? 1;
                _pageFlip(context, d.localPosition.dx < w / 2 ? -1 : 1);
              },
              onVerticalDragStart: (_) => _pageDragAccum = 0,
              onVerticalDragUpdate: (d) => _pageDragAccum += d.delta.dy,
              onVerticalDragEnd: (d) =>
                  widget.onPageDragEnd(d, _pageDragAccum),
              child: AnimatedBuilder(
                animation: widget.pageCtrl,
                builder: (context, _) => SizedBox(
                  height: 34,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      for (var i = 0; i < 3; i++)
                        Container(
                          width: 22,
                          height: 22,
                          alignment: Alignment.center,
                          child: Container(
                            width: 7,
                            height: 7,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: i ==
                                      ((widget.pageCtrl.hasClients
                                              ? widget.pageCtrl.page ?? 0
                                              : 0)
                                          .round())
                                  ? AppColors.accent
                                  : theme.colorScheme.outlineVariant,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            const Divider(height: 8),
            Expanded(
              child: Stack(
                children: [
                  PageView(
                    controller: widget.pageCtrl,
                    physics: const NeverScrollableScrollPhysics(),
                    children: [
                      TodayPanel(controller: controller),
                      NotesPanel(controller: controller),
                      PoolPanel(controller: controller),
                    ],
                  ),
                  // 每页都可添加待办与堆三无（§6.1）：右下角双钮
                  PanelActions(
                    controller: controller,
                    heroTagPrefix: widget.heroTagPrefix,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _pageFlip(BuildContext context, int delta) {
    if (!widget.pageCtrl.hasClients) return;
    final page = (widget.pageCtrl.page ?? 0).round().clamp(0, 2);
    final target = page + delta;
    if (target < 0 || target > 2) return;
    widget.pageCtrl.animateToPage(target,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic);
  }
}

/// 面板右下角的添加区：添加待办 + 堆三无（§6.1 每页都可添加）。
/// [heroTagPrefix] 区分面板/抽屉/悬浮窗几处实例，避免 Hero 标签冲突。
class PanelActions extends StatelessWidget {
  final AppController controller;
  final String heroTagPrefix;

  const PanelActions({
    super.key,
    required this.controller,
    this.heroTagPrefix = 'panel',
  });

  @override
  Widget build(BuildContext context) {
    return Positioned(
      right: 14,
      bottom: 14,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          FloatingActionButton.small(
            heroTag: '$heroTagPrefix-quick-dump',
            tooltip: '堆三无（两秒入池）',
            onPressed: () => showQuickDump(context, controller),
            child: const Icon(Icons.waves),
          ),
          const SizedBox(width: 8),
          FloatingActionButton(
            heroTag: '$heroTagPrefix-create-task',
            tooltip: '添加待办',
            onPressed: () => showCreateFlow(context, controller),
            child: const Icon(Icons.add),
          ),
        ],
      ),
    );
  }
}

/// 隐私过头输入条（§6.5）：只留一条极简输入框，写完即走（等价堆三无）。
class PanelPrivacyBar extends StatefulWidget {
  final Future<void> Function(String) onSubmit;

  const PanelPrivacyBar({super.key, required this.onSubmit});

  @override
  State<PanelPrivacyBar> createState() => _PanelPrivacyBarState();
}

class _PanelPrivacyBarState extends State<PanelPrivacyBar> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final text = _ctrl.text;
    _ctrl.clear();
    await widget.onSubmit(text);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 16,
      right: 16,
      bottom: MediaQuery.of(context).padding.bottom + 24,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: Theme.of(context).cardTheme.color,
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.3),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _ctrl,
                autofocus: true,
                onSubmitted: (_) => _submit(),
                decoration: const InputDecoration(
                  hintText: '只留输入…（写完即走，已静默入池）',
                  border: InputBorder.none,
                ),
              ),
            ),
            IconButton(
              icon: Icon(Icons.send, color: AppColors.accent),
              onPressed: _submit,
            ),
          ],
        ),
      ),
    );
  }
}

/// 首次拖出引导（决议 21）：一次性三步气泡——展开 / 翻页 / 添加。
class PanelOnboardDialog extends StatelessWidget {
  const PanelOnboardDialog({super.key});

  @override
  Widget build(BuildContext context) {
    const steps = [
      (Icons.swipe_left_alt, '拖出展开', '点一下屏幕边缘那道白色细条，或从它上面朝屏幕里横拖，展开侧边栏；长按细条可换边停靠。'),
      (Icons.swap_vert, '重手势翻页', '三页竖翻：今日 → 疑问 → 池子。翻页故意做了"重"手势，浏览清单时不会误翻。'),
      (Icons.add_circle_outline, '右下角添加',
          '「+」进完整创建（类型与日期都是按钮，默认三无、点确认直接入池），「～」两秒堆三无。'),
    ];
    return AlertDialog(
      title: const Text('三步上手'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < steps.length; i++)
            ListTile(
              leading: CircleAvatar(
                backgroundColor: AppColors.accent.withValues(alpha: 0.15),
                child: Text('${i + 1}',
                    style: TextStyle(
                        color: AppColors.accent, fontWeight: FontWeight.w800)),
              ),
              title: Text(steps[i].$2),
              subtitle: Text(steps[i].$3),
            ),
        ],
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('开始用'),
        ),
      ],
    );
  }
}

/// 悬浮窗宿主的组装件：面板 + 半透明遮罩 + 隐私输入条。
///
/// 与安卓壳共用同一份 [SidePanel]；差别只在宿主容器：
/// 这里的面板浮在其他 App 之上（窗口背景透明），点遮罩即收起。
class FloatingPanel extends StatelessWidget {
  final AppController controller;
  final PageController pageCtrl;
  final void Function(DragEndDetails d, double accum) onPageDragEnd;
  final VoidCallback onCollapse;
  final VoidCallback onPrivacy;
  final bool privacy;
  final Future<void> Function(String) onPrivacySubmit;
  final VoidCallback onOpenCalendar;
  final VoidCallback onOpenSettings;

  /// true = 贴左侧展开（把手停靠在左边时的自然姿势）。
  final bool dockLeft;

  const FloatingPanel({
    super.key,
    required this.controller,
    required this.pageCtrl,
    required this.onPageDragEnd,
    required this.onCollapse,
    required this.onPrivacy,
    required this.privacy,
    required this.onPrivacySubmit,
    required this.onOpenCalendar,
    required this.onOpenSettings,
    this.dockLeft = false,
  });

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final panelWidth = size.width * 0.88 > 420 ? 420.0 : size.width * 0.88;

    if (privacy) {
      // 隐私过头：不渲染任何任务数据，只留一条输入框（§11）
      return Stack(children: [
        Positioned.fill(
          child: GestureDetector(
            onTap: onCollapse,
            child: Container(color: Colors.black.withValues(alpha: 0.25)),
          ),
        ),
        PanelPrivacyBar(onSubmit: onPrivacySubmit),
      ]);
    }

    return Stack(
      children: [
        // 遮罩：点空白处收起（下面是别的 App，只压一层浅色）
        Positioned.fill(
          child: GestureDetector(
            onTap: onCollapse,
            child: Container(color: Colors.black.withValues(alpha: 0.25)),
          ),
        ),
        Positioned(
          top: MediaQuery.of(context).padding.top + 8,
          bottom: MediaQuery.of(context).padding.bottom + 8,
          left: dockLeft ? 6 : null,
          right: dockLeft ? null : 6,
          width: panelWidth,
          child: SidePanel(
            controller: controller,
            pageCtrl: pageCtrl,
            onPageDragEnd: onPageDragEnd,
            onClose: onCollapse,
            onPrivacy: onPrivacy,
            onOpenCalendar: onOpenCalendar,
            onOpenSettings: onOpenSettings,
            heroTagPrefix: 'floating',
          ),
        ),
      ],
    );
  }
}

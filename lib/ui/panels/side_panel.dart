import 'package:flutter/material.dart';

import '../../application/settings.dart';
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
/// 三页左右横翻（今日清单 → 疑问笔记 → 任务池）、右下角添加区都在这里；
/// 翻页走 PageView 自己的横滑物理（v0.15），宿主只负责"摆哪儿、怎么进出"（滑入动画 / 悬浮窗口 / 抽屉）。
class SidePanel extends StatefulWidget {
  final AppController controller;
  final PageController pageCtrl;

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
            // 面板头：页名 + 翻页点 + 日历 / 隐私 / 设置? / 关闭。
            // 翻页 = **左右横滑**（PageView 自己的物理，v0.15）：横方向与列表的
            // 纵向滚动正交，两边互不抢手，所以不再需要任何"重手势"。
            // 圆点是页序指示，同时是可点的跳转靶。
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
              child: Row(
                children: [
                  AnimatedBuilder(
                    animation: widget.pageCtrl,
                    builder: (context, _) => Text(
                      _pageNames[_currentPage],
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
            AnimatedBuilder(
              animation: widget.pageCtrl,
              builder: (context, _) => SizedBox(
                height: 30,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0; i < 3; i++)
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => _pageTo(i),
                        child: SizedBox(
                          width: 36,
                          height: 30,
                          child: Center(
                            child: Container(
                              width: 7,
                              height: 7,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: i == _currentPage
                                    ? AppColors.accent
                                    : theme.colorScheme.outlineVariant,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const Divider(height: 8),
            Expanded(
              child: Stack(
                children: [
                  PageView(
                    controller: widget.pageCtrl,
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

  /// 当前页序号（PageView 还没挂上时按第 1 页算）。
  int get _currentPage =>
      (widget.pageCtrl.hasClients ? (widget.pageCtrl.page ?? 0) : 0).round();

  /// 点圆点直接跳页（页序指示本身就是跳转靶）。
  void _pageTo(int page) {
    if (!widget.pageCtrl.hasClients) return;
    widget.pageCtrl.animateToPage(page.clamp(0, 2),
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
      (Icons.swap_horiz, '左右横滑翻页',
          '三页：今日 → 疑问 → 池子。在页面区左右横拖就翻页（上下拖是滚动清单，两回事）；'
          '也可以直接点顶部那三个圆点跳到某一页。'),
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

/// 侧边栏宽度下限（逻辑像素）：三页内容（清单、输入框、右下角双钮）要能看。
const double _kMinPanelWidth = 280;

/// 拖把手的手势区宽度：骑在面板内侧边缘上，左右各探出 6dp。
const double _kEdgeGrab = 12;

/// 当前侧边栏宽度：拖宽持久化在 `settings.panelWidth`；没拖过 = 默认公式。
/// 结果必过 [clampPanelWidth]——换屏（旋转 / 分屏 / 悬浮窗尺寸变化）时
/// 旧宽度按当时屏幕重新夹，不会溢出屏幕。
double panelWidthFor(AppSettings settings, double screenWidth) =>
    clampPanelWidth(
        settings.panelWidth ??
            (screenWidth * 0.88 > 420 ? 420.0 : screenWidth * 0.88),
        screenWidth);

/// 宽度夹紧：[_kMinPanelWidth, 屏宽 − 48]。屏宽窄于下限时给"能多宽多宽"
/// （默认公式本身也随屏宽缩，不会把面板顶出屏外）。
double clampPanelWidth(double width, double screenWidth) {
  final max = screenWidth - 48;
  if (max <= _kMinPanelWidth) return max;
  if (width < _kMinPanelWidth) return _kMinPanelWidth;
  if (width > max) return max;
  return width;
}

/// 可拖宽的侧边栏容器（ui-interaction.md §6.0）：面板内侧边缘一条竖条把手，
/// 横拖**实时**改宽（只 setState），松手把宽度写进 `settings.panelWidth`
/// 一笔落盘。
///
/// **宽度只有一个来源**：拖拽中 = 本地 `_dragWidth`，其余时候 = settings
/// （或默认公式）。两个宿主（应用内壳 / 系统级悬浮窗）共用这一个组件，
/// 拖拽语义与持久化行为完全一致；宿主只负责"摆哪儿"（Positioned / 滑入
/// 动画），不再自己算宽度——这也包括收起时滑出屏外所需的宽度。
class ResizablePanel extends StatefulWidget {
  final AppController controller;

  /// true = 面板停左（把手在面板右缘）；false = 停右（把手在左缘）。
  final bool dockLeft;

  /// 面板本体（[SidePanel]），由宿主装配。
  final Widget child;

  const ResizablePanel({
    super.key,
    required this.controller,
    required this.dockLeft,
    required this.child,
  });

  @override
  State<ResizablePanel> createState() => _ResizablePanelState();
}

class _ResizablePanelState extends State<ResizablePanel> {
  /// 拖拽中的实时宽度；null = 不在拖，用 settings 里的宽度（或默认公式）。
  double? _dragWidth;

  double get _width {
    final screenWidth = MediaQuery.of(context).size.width;
    return _dragWidth ??
        panelWidthFor(widget.controller.settings, screenWidth);
  }

  /// [delta] 已由把手按停靠侧换算成"变宽为正"（停左向右拖、停右向左拖）。
  void _onResize(double delta) {
    final screenWidth = MediaQuery.of(context).size.width;
    setState(() {
      _dragWidth = clampPanelWidth(_width + delta, screenWidth);
    });
  }

  /// 松手才落盘：拖拽过程不写 settings.json——否则每帧一次文件写，还会
  /// 触发另一个引擎重载（两个引擎 watch 同一任务目录）。
  Future<void> _onResizeEnd() async {
    final width = _dragWidth;
    if (width == null) return;
    // updateSettings 先同步改内存并 notify、再异步写盘：拖拽值立即生效，
    // 文件落地前面板不会闪回旧宽度。
    await widget.controller.updateSettings(
        widget.controller.settings.copyWith(panelWidth: width));
    if (mounted) setState(() => _dragWidth = null);
  }

  @override
  Widget build(BuildContext context) {
    final width = _width;
    return SizedBox(
      width: width,
      // 把手骑在边缘上、探出面板 6dp：Stack 默认 hardEdge 会裁掉探出部分。
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          widget.child,
          Positioned(
            top: 0,
            bottom: 0,
            left: widget.dockLeft ? width - _kEdgeGrab / 2 : null,
            right: widget.dockLeft ? null : width - _kEdgeGrab / 2,
            child: _PanelResizeEdge(
              onResize: (dx) => _onResize(widget.dockLeft ? dx : -dx),
              onResizeEnd: _onResizeEnd,
            ),
          ),
        ],
      ),
    );
  }
}

/// 面板内侧边缘的宽度把手：[_kEdgeGrab] 宽的通栏手势区 + 居中握持 pill。
/// 手势区贴在面板内容区外缘，不与 PageView 的翻页横滑抢手势。
class _PanelResizeEdge extends StatelessWidget {
  final ValueChanged<double> onResize;
  final Future<void> Function() onResizeEnd;

  const _PanelResizeEdge({required this.onResize, required this.onResizeEnd});

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (d) => onResize(d.delta.dx),
        onHorizontalDragEnd: (_) => onResizeEnd(),
        child: SizedBox(
          width: _kEdgeGrab,
          child: Center(
            child: Container(
              width: 4,
              height: 36,
              decoration: BoxDecoration(
                color: AppColors.accent.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
      ),
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

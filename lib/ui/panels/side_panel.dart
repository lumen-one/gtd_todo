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
            // 页名与翻页圆点合成一行（面板只有 240–360 dp 宽，圆点单独占
            // 一行等于白扔 30 dp 的内容高度）；圆点仍是跳转靶。
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 2, 4, 0),
              child: Row(
                children: [
                  Flexible(
                    child: AnimatedBuilder(
                      animation: widget.pageCtrl,
                      builder: (context, _) => AnimatedSwitcher(
                        duration: const Duration(milliseconds: 180),
                        child: Text(
                          _pageNames[_currentPage],
                          key: ValueKey(_pageNames[_currentPage]),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  AnimatedBuilder(
                    animation: widget.pageCtrl,
                    builder: (context, _) => Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (var i = 0; i < 3; i++) _pageDot(i, theme),
                      ],
                    ),
                  ),
                  const Spacer(),
                  _headButton(Icons.calendar_month_outlined, '日历',
                      widget.onOpenCalendar),
                  _headButton(Icons.visibility_off_outlined, '隐私模式',
                      widget.onPrivacy),
                  if (widget.onOpenSettings != null)
                    _headButton(Icons.settings_outlined, '设置',
                        widget.onOpenSettings!),
                  _headButton(Icons.close, '关闭', widget.onClose),
                ],
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

  /// 页序圆点：当前页拉成一条短横（形变过渡），点它直接跳页。
  Widget _pageDot(int index, ThemeData theme) {
    final active = index == _currentPage;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _pageTo(index),
      child: SizedBox(
        width: 16,
        height: 28,
        child: Center(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            width: active ? 14 : 6,
            height: 6,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              color: active
                  ? AppColors.accent
                  : theme.colorScheme.outlineVariant.withValues(alpha: 0.7),
            ),
          ),
        ),
      ),
    );
  }

  /// 面板头的图标按钮：34 dp 见方。默认 40 的按钮在 240 dp 宽的面板上
  /// 会把页名和圆点挤没。
  Widget _headButton(IconData icon, String tooltip, VoidCallback onPressed) =>
      IconButton(
        constraints: const BoxConstraints.tightFor(width: 34, height: 34),
        padding: EdgeInsets.zero,
        iconSize: 20,
        tooltip: tooltip,
        icon: Icon(icon),
        onPressed: onPressed,
      );

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
      child: FadeIn(
        offset: 14,
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
    // 每条一句：首次引导只教"手往哪放"，细枝末节留给实际用一次。
    const steps = [
      (Icons.swipe_left_alt, '拖出展开', '点边缘细条即开，或朝屏内拖；长按换边'),
      (Icons.swap_horiz, '横滑翻页', '今日 / 疑问 / 池子，左右横拖切换'),
      (Icons.add_circle_outline, '右下角添加', '「+」完整创建，「～」两秒堆三无'),
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

/// 侧边栏尺寸下限（逻辑像素）：三页内容（清单、输入框、右下角双钮）要能看。
const double _kMinPanelWidth = 240;
const double _kMinPanelHeight = 320;

/// 拖把手的手势区厚度：贴在面板内沿一整条（宽把手贴内侧竖缘、高把手贴底缘）。
const double _kEdgeGrab = 12;

/// 展开时面板与屏缘的贴靠 inset（上下同用；可用高度 = 屏高 − 安全区 − 2×它）。
const double _kPanelInset = 8;

/// 默认尺寸（没拖过时）：宽 = min(0.80 × 屏宽, 360)，高 = 0.85 × 可用高度。
/// 都是手感参数，口径见 ui-interaction.md §6.0——改数只动这一处。
const double _kDefaultWidthFraction = 0.80;
const double _kDefaultWidthCap = 360;
const double _kDefaultHeightFraction = 0.85;

/// 面板可用高度（屏高减上下安全区、减上下贴靠 inset）。
double panelAvailableHeight(BuildContext context) {
  final mq = MediaQuery.of(context);
  return mq.size.height - mq.padding.top - mq.padding.bottom - 2 * _kPanelInset;
}

/// 当前侧边栏宽度：拖宽持久化在 `settings.panelWidth`；没拖过 = 默认公式。
/// 结果必过 [clampPanelWidth]——换屏（旋转 / 分屏 / 悬浮窗尺寸变化）时
/// 旧宽度按当时屏幕重新夹，不会溢出屏幕。
double panelWidthFor(AppSettings settings, double screenWidth) =>
    clampPanelWidth(
        settings.panelWidth ??
            (screenWidth * _kDefaultWidthFraction > _kDefaultWidthCap
                ? _kDefaultWidthCap
                : screenWidth * _kDefaultWidthFraction),
        screenWidth);

/// 当前侧边栏高度：拖高持久化在 `settings.panelHeight`；没拖过 = 默认公式。
double panelHeightFor(AppSettings settings, double availableHeight) =>
    clampPanelHeight(
        settings.panelHeight ?? availableHeight * _kDefaultHeightFraction,
        availableHeight);

/// 宽度夹紧：[_kMinPanelWidth, 屏宽 − 24]。屏宽窄于下限时给"能多宽多宽"
/// （默认公式本身也随屏宽缩，不会把面板顶出屏外）。
double clampPanelWidth(double width, double screenWidth) {
  final max = screenWidth - 24;
  if (max <= _kMinPanelWidth) return max;
  if (width < _kMinPanelWidth) return _kMinPanelWidth;
  if (width > max) return max;
  return width;
}

/// 高度夹紧：[_kMinPanelHeight, 可用高度]；可用高度不足时同理让位。
double clampPanelHeight(double height, double availableHeight) {
  if (availableHeight <= _kMinPanelHeight) return availableHeight;
  if (height < _kMinPanelHeight) return _kMinPanelHeight;
  if (height > availableHeight) return availableHeight;
  return height;
}

/// 把面板期望的顶边夹紧在可用区 [min, max] 里（max < min 只可能是极端
/// 窄屏——面板比可用区还高，此时贴顶）。
double clampPanelTop(double top, double min, double max) {
  if (max < min) return min;
  if (top < min) return min;
  if (top > max) return max;
  return top;
}

/// 可拖拽尺寸的侧边栏容器（ui-interaction.md §6.0）：内侧边缘竖条把手横拖
/// 改宽、底边横条把手竖拖改高，拖动中**实时**改（只 setState），松手把尺寸
/// 写进 `settings.panelWidth` / `panelHeight` 一笔落盘。
///
/// **尺寸只有一个来源**：拖拽中 = 本地 `_dragWidth` / `_dragHeight`，其余
/// 时候 = settings（或默认公式）。两个宿主（应用内壳 / 系统级悬浮窗）共用
/// 这一个组件，拖拽语义与持久化行为完全一致；宿主只负责"摆哪儿"
/// （Positioned / 滑入动画 + 停靠侧 + 顶部 inset），不再自己算尺寸。
class ResizablePanel extends StatefulWidget {
  final AppController controller;

  /// true = 面板停左（宽把手在面板右缘）；false = 停右（宽把手在左缘）。
  final bool dockLeft;

  /// 面板本体（[SidePanel]），由宿主装配。
  final Widget child;

  /// 垂直锚点（屏幕坐标 Y，通常是把手的中心）：面板垂直居中于它。
  /// null = 不居中，贴可用区顶（系统级悬浮窗：原生把手位置未暴露给 Dart）。
  ///
  /// 宿主把面板摆在可用区顶部（`padding.top + _kPanelInset`），面板自己在
  /// 区内 Padding 到居中位——宽高状态不离开本组件，宿主不必知道尺寸。
  final double? anchorCenterY;

  const ResizablePanel({
    super.key,
    required this.controller,
    required this.dockLeft,
    required this.child,
    this.anchorCenterY,
  });

  @override
  State<ResizablePanel> createState() => _ResizablePanelState();
}

class _ResizablePanelState extends State<ResizablePanel> {
  /// 拖拽中的实时宽/高；null = 不在拖，用 settings 里的值（或默认公式）。
  double? _dragWidth;
  double? _dragHeight;

  double get _width => _dragWidth ??
      panelWidthFor(
          widget.controller.settings, MediaQuery.of(context).size.width);

  double get _height => _dragHeight ??
      panelHeightFor(
          widget.controller.settings, panelAvailableHeight(context));

  /// [delta] 已由把手按停靠侧换算成"变宽为正"（停左向右拖、停右向左拖）。
  void _onResizeWidth(double delta) {
    final screenWidth = MediaQuery.of(context).size.width;
    setState(() {
      _dragWidth = clampPanelWidth(_width + delta, screenWidth);
    });
  }

  /// 面板顶边固定：竖拖改的是底边位置，向下为高。
  void _onResizeHeight(double delta) {
    setState(() {
      _dragHeight =
          clampPanelHeight(_height + delta, panelAvailableHeight(context));
    });
  }

  /// 松手才落盘：拖拽过程不写 settings.json——否则每帧一次文件写，还会
  /// 触发另一个引擎重载（两个引擎 watch 同一任务目录）。
  Future<void> _onResizeEnd() async {
    final width = _dragWidth;
    final height = _dragHeight;
    if (width == null && height == null) return;
    // updateSettings 先同步改内存并 notify、再异步写盘：拖拽值立即生效，
    // 文件落地前面板不会闪回旧尺寸。
    await widget.controller.updateSettings(widget.controller.settings.copyWith(
      panelWidth: width,
      panelHeight: height,
    ));
    if (mounted) {
      setState(() {
        _dragWidth = null;
        _dragHeight = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final width = _width;
    final height = _height;
    final slotTop = mq.padding.top + _kPanelInset;
    final slotBottom = mq.size.height - mq.padding.bottom - _kPanelInset;
    // 有锚点 = 垂直居中于它（触边夹紧）；无锚点（悬浮窗）= 贴可用区顶。
    final top = widget.anchorCenterY == null
        ? slotTop
        : clampPanelTop(widget.anchorCenterY! - height / 2, slotTop,
            slotBottom - height);
    return Padding(
      // 宿主把面板放在可用区顶，这里在区内落到锚点居中位。
      padding: EdgeInsets.only(top: top - slotTop),
      child: SizedBox(
        width: width,
        height: height,
        // 两个把手都贴在面板内沿（不探出边界——探出部分落在 Stack 的命中
        // 测试区之外，边界点按不碎；贴内沿整条都在可命中范围内）。
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            widget.child,
            // 宽把手：内侧边缘竖条（停左贴右缘内沿、停右贴左缘内沿）。
            Positioned(
              top: 0,
              bottom: 0,
              left: widget.dockLeft ? width - _kEdgeGrab : null,
              right: widget.dockLeft ? null : width - _kEdgeGrab,
              child: _PanelResizeEdge(
                axis: Axis.horizontal,
                onResize: (dx) => _onResizeWidth(widget.dockLeft ? dx : -dx),
                onResizeEnd: _onResizeEnd,
              ),
            ),
            // 高把手：底边横条（贴底边内沿）。
            Positioned(
              left: 0,
              right: 0,
              top: height - _kEdgeGrab,
              child: _PanelResizeEdge(
                axis: Axis.vertical,
                onResize: _onResizeHeight,
                onResizeEnd: _onResizeEnd,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 面板边缘的拖拽把手：[Axis.horizontal] = 内侧边缘竖条改宽；
/// [Axis.vertical] = 底边横条改高。整条贴在面板内沿——探出边界的话，
/// 探出部分在 Stack 的命中测试区之外（边界点按不碎）。不与面板内容区的
/// 手势（翻页横滑 / 清单纵滚）抢：那 12dp 是边缘背景区。
class _PanelResizeEdge extends StatelessWidget {
  final Axis axis;
  final ValueChanged<double> onResize;
  final Future<void> Function() onResizeEnd;

  const _PanelResizeEdge({
    required this.axis,
    required this.onResize,
    required this.onResizeEnd,
  });

  @override
  Widget build(BuildContext context) {
    final horizontal = axis == Axis.horizontal;
    return MouseRegion(
      cursor:
          horizontal ? SystemMouseCursors.resizeColumn : SystemMouseCursors.resizeRow,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: horizontal ? (d) => onResize(d.delta.dx) : null,
        onVerticalDragUpdate: horizontal ? null : (d) => onResize(d.delta.dy),
        onHorizontalDragEnd: horizontal ? (_) => onResizeEnd() : null,
        onVerticalDragEnd: horizontal ? null : (_) => onResizeEnd(),
        child: SizedBox(
          width: horizontal ? _kEdgeGrab : null,
          height: horizontal ? null : _kEdgeGrab,
          child: Center(
            child: Container(
              width: horizontal ? 4 : 36,
              height: horizontal ? 36 : 4,
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

  /// 原生把手的中心 Y（逻辑像素）：面板垂直居中于它；null = 贴顶
  /// （老版本原生没广播 `handle_center_y`）。
  final double? anchorCenterY;

  /// 展开进度（ui-interaction.md §6.0 跟手拉开）：1 = 全展开；<1 = 用户正拖着
  /// 把手走，面板按 (1−progress)×宽 横移出屏、遮罩随进度渐显。松手补满/滑回
  /// 由宿主（OverlayPanelShell）的动画驱动。
  final double progress;

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
    this.anchorCenterY,
    this.progress = 1,
  });

  @override
  Widget build(BuildContext context) {
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

    final p = progress.clamp(0.0, 1.0);
    // 跟手滑出量：与 ResizablePanel 自算宽度同一个公式——拖动中不会有尺寸
    // 拖拽，两边不会不一致。
    final slide =
        (1 - p) * panelWidthFor(controller.settings, MediaQuery.of(context).size.width);
    return Stack(
      children: [
        // 遮罩：点空白处收起（下面是别的 App，只压一层浅色）。
        // 跟手拖动中（p<1）不接手势——那一带归原生把手窗口。
        Positioned.fill(
          child: IgnorePointer(
            ignoring: p < 1,
            child: GestureDetector(
              onTap: onCollapse,
              child: Container(color: Colors.black.withValues(alpha: 0.25 * p)),
            ),
          ),
        ),
        Positioned(
          top: MediaQuery.of(context).padding.top + 8,
          left: dockLeft ? 6 - slide : null,
          right: dockLeft ? null : 6 - slide,
          // 宽高由 ResizablePanel 自算（设置值 / 默认公式 / 拖拽实时值），
          // 这里只给停靠侧与顶部 inset，不设 width/height/bottom。
          child: ResizablePanel(
            controller: controller,
            dockLeft: dockLeft,
            anchorCenterY: anchorCenterY,
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
        ),
      ],
    );
  }
}

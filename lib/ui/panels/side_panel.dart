import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';

import '../../application/settings.dart';
import '../app_controller.dart';
import '../panel_pages.dart';
import '../theme.dart';
import '../widgets/panel_dock.dart';
import '../widgets/task_selection.dart';
import 'notes_panel.dart';
import 'completed_panel.dart';
import 'mainline_panel.dart';
import 'plan_panel.dart';
import 'pool_panel.dart';
import 'today_panel.dart';

/// 侧边栏面板本体（§5.1：panels 平台无关，只被 shell 摆放）。
///
/// **两个宿主共用这一份**（v1.5）：
/// - 应用内安卓壳（`AndroidShell`）：贴屏把手拖出 → 面板滑入；
/// - **系统级悬浮窗**（`overlay_main.dart`，跑在原生前台服务的第二个引擎里）：
///   在其他 App 上方就地展开同一个面板，日常操作不必离开当前 App。
///
/// 四页左右横翻（页序见 [PanelPage]，**只有那一处定义**）、右下角添加区都在这里；
/// 展开后落在哪一页由设置项 `default_page` 决定（§9 第 12 条），宿主负责"摆哪儿、
/// 怎么进出"（滑入动画 / 悬浮窗口 / 抽屉）与"开面板时落到哪一页"。
class SidePanel extends StatefulWidget {
  final AppController controller;
  final PageController pageCtrl;

  final VoidCallback onOpenCalendar;

  /// 悬浮窗宿主的"进应用"入口（打开设置页）；null = 不显示该按钮。
  ///
  /// 面板头只有这一个图标按钮（右端）——关面板靠点遮罩 / 返回键 / 收起把手，
  /// 隐私那套已由快记取代（v1.24，§6.5 / §6.8）。
  final VoidCallback? onOpenSettings;

  /// Hero 标签前缀：同一棵树里放两份面板时要区分（抽屉兜底 / 悬浮窗）。
  final String heroTagPrefix;

  const SidePanel({
    super.key,
    required this.controller,
    required this.pageCtrl,
    required this.onOpenCalendar,
    this.onOpenSettings,
    this.heroTagPrefix = 'panel',
  });

  @override
  State<SidePanel> createState() => _SidePanelState();
}

class _SidePanelState extends State<SidePanel> {
  /// 页名表：与 [PanelPage] 同序，圆点与 PageView 也按它摆。
  static final List<String> _pageNames =
      [for (final page in PanelPage.values) page.label];

  /// 多选（§10#23）：整块面板一份、**跨页保留**——翻页不清空选中，
  /// 因为一次收拾"今日剩的 + 池子里堆的"是主要场景。纯 UI 临时态，
  /// 跟着这个 State 一起生灭。
  final TaskSelection _selection = TaskSelection();

  /// 右下角双钮的"藏"开关（§6.1）：列表上滑时由 [DockScrollListener] 置位，
  /// 换页时复位——新的一页起手不该是藏着的。
  final ValueNotifier<bool> _dockHidden = ValueNotifier<bool>(false);

  /// 当前页序号缓存：只有换页才 `setState`，滚动不必重建整块面板。
  late int _page;

  @override
  void initState() {
    super.initState();
    _page = _currentPage;
    widget.pageCtrl.addListener(_onPageChanged);
    widget.controller.addListener(_onControllerChanged);
  }

  @override
  void didUpdateWidget(covariant SidePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
    }
    if (oldWidget.pageCtrl != widget.pageCtrl) {
      oldWidget.pageCtrl.removeListener(_onPageChanged);
      widget.pageCtrl.addListener(_onPageChanged);
    }
  }

  @override
  void dispose() {
    widget.pageCtrl.removeListener(_onPageChanged);
    widget.controller.removeListener(_onControllerChanged);
    _dockHidden.dispose();
    _selection.dispose();
    super.dispose();
  }

  /// 换页（含跟手横滑过半个屏幕的那一下）：双钮复位成"看得见"。
  void _onPageChanged() {
    final page = _currentPage;
    if (page == _page) return;
    _dockHidden.value = false;
    setState(() => _page = page);
  }

  /// 面板头第二行的主线名与进度、覆盖页里的勾选都要跟着控制器变。
  /// 其他页各自监听（notes_panel / task_list_panel 同款），面板头原先不监听。
  void _onControllerChanged() {
    if (!mounted) return;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = widget.controller;

    return Material(
      borderRadius: BorderRadius.circular(20),
      color: theme.scaffoldBackgroundColor,
      elevation: 8,
      shadowColor: Colors.black38,
      child: Stack(
        children: [
          SafeArea(
            bottom: false,
            child: Column(
              children: [
                // 面板头：页名 + 翻页点 + 右端『设置』?（v1.24：隐私 / 关闭两颗
                // 图标撤掉，见 §6.0）。
                // 翻页 = **左右横滑**（PageView 自己的物理，v0.15）：横方向与列表的
                // 纵向滚动正交，两边互不抢手，所以不再需要任何"重手势"。
                // 圆点是页序指示，同时是可点的跳转靶。
                // 页名与图标按钮一行；页序圆点回到自己独立的一行（v1.20 改回——
                // 居中那排圆点是面板的"我在第几页"标识，用户觉得它好看，
                // 省高度不值得）。
                // 布局：`spaceBetween` 让页名贴左、设置贴右——**不用 Spacer**：
                // Spacer 也是 flex:1，会和 Flexible 对半劈掉页名那份空间，窄面板
                // （240dp 下限）上差 1dp 就被省略号截断（2026-10-16 实测，回归用例
                // 见 overlay_panel_test）。也不能图省事改 Expanded：标题外层的
                // AnimatedSwitcher 内部是默认居中的 Stack，紧约束下短页名会离左缘
                // 23dp。
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 2, 4, 0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
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
                              style: theme.textTheme.titleMedium,
                            ),
                          ),
                        ),
                      ),
                      if (widget.onOpenSettings != null)
                        _headButton(Icons.settings_outlined, '设置',
                            widget.onOpenSettings!),
                    ],
                  ),
                ),
                // 第二行：当前主线（v1.30，§6.9）。整行可点，没有主线时是新建入口。
                _mainlineRow(theme, controller),
                // 页序圆点：独立一行居中，点哪个跳哪页（§6.0）。
                AnimatedBuilder(
                  animation: widget.pageCtrl,
                  builder: (context, _) => SizedBox(
                    height: 28,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        for (var i = 0; i < PanelPage.values.length; i++)
                          _pageDot(i, theme),
                      ],
                    ),
                  ),
                ),
                const Divider(height: 8),
                Expanded(
                  child: Stack(
                    children: [
                      DockScrollListener(
                        hidden: _dockHidden,
                        child: PageView(
                          controller: widget.pageCtrl,
                          children: [
                            for (final page in PanelPage.values)
                              _pageBody(page, controller),
                          ],
                        ),
                      ),
                      // 右下角双钮（§6.1）：**灵感页不摆**——那一页是读正文的，
                      // 两颗钮压在字上，又没有可加的东西。其余页上滑时藏起来
                      // （[DockScrollListener]），下滑或滚回顶部才回来；选择模式
                      // 整块换成批处理条（§10#23）。
                      if (_page != PanelPage.notes.index)
                        PanelDock(
                          controller: controller,
                          selection: _selection,
                          onOpenCalendar: widget.onOpenCalendar,
                          heroTagPrefix: widget.heroTagPrefix,
                          hidden: _dockHidden,
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // 主线覆盖页：盖住整块面板（含面板头与圆点，§6.9）。开合状态在控制器里
          // （宿主的返回键也要问它，见 `AppController.mainlineOpen`），进出过渡
          // 在 [_MainlineReveal] 里。
          Positioned.fill(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: _MainlineReveal(
                open: controller.mainlineOpen,
                exit: controller.mainlineExit,
                exiting: controller.mainlineExiting,
                child: MainlineOverlay(
                  controller: controller,
                  onClose: controller.closeMainline,
                ),
              ),
            ),
          ),
          // 今日编排覆盖页（§6.11）：今日页滚到顶再下拉，整块从面板顶边滑下来。
          // 开合与跟手行程都在控制器里（`planOpen` / `planPull` / `planDragging`），
          // 但行程走单独的 notifier——拖动时每帧都在变，不该重建整棵面板。
          Positioned.fill(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: _PlanReveal(
                open: controller.planOpen,
                instantEnter: controller.planEnterInstant,
                pull: controller.planPull,
                dragging: controller.planDragging,
                exit: controller.planExit,
                exiting: controller.planExiting,
                child: PlanOverlay(
                  controller: controller,
                  onClose: controller.closePlan,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 面板头第二行：主线名 + 进度（§6.9）。未装配主线时整行不占高度。
  Widget _mainlineRow(ThemeData theme, AppController controller) {
    if (!controller.hasMainline) return const SizedBox.shrink();
    final m = controller.activeMainline;
    final hint = theme.colorScheme.onSurfaceVariant;
    return InkWell(
      onTap: controller.openMainline,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 1, 8, 2),
        child: Row(
          children: [
            Icon(
              Icons.route,
              size: 14,
              color: m == null ? hint.withValues(alpha: 0.7) : AppColors.accent,
            ),
            const SizedBox(width: 5),
            Expanded(
              child: Text(
                m?.title ?? '＋ 新建主线',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: m == null ? hint : theme.colorScheme.onSurface,
                  fontWeight: m == null ? null : FontWeight.w600,
                ),
              ),
            ),
            if (m != null)
              Text(
                m.isAllDone ? '可归档' : m.progressText,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: AppColors.accent,
                  fontWeight: FontWeight.w700,
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 页 → 页面本体：页序由 [PanelPage] 决定，这里只做"哪一页放哪个面板"。
  ///
  /// 今日页单独放开鼠标拖拽（§6.11）：桌面没有触屏，编排的入口得靠"按住鼠标
  /// 拖到顶再往下拖"复现同一条手势；只包这一页，别的列表不受影响。
  Widget _pageBody(PanelPage page, AppController controller) => switch (page) {
        PanelPage.notes => NotesPanel(controller: controller),
        PanelPage.today => ScrollConfiguration(
            behavior: ScrollConfiguration.of(context).copyWith(
              dragDevices: PointerDeviceKind.values.toSet(),
            ),
            child: TodayPanel(controller: controller, selection: _selection),
          ),
        PanelPage.pool =>
          PoolPanel(controller: controller, selection: _selection),
        PanelPage.completed =>
          CompletedPanel(controller: controller, selection: _selection),
      };

  /// 页序圆点（v1.20 改回原本的形）：7dp 圆点、当前页强调色，切换时颜色
  /// 渐变（v1.19 那版会把当前页拉成短横，用户想要回圆点）。每个圆点包
  /// 36dp 宽的点击区，点哪个跳哪页。
  Widget _pageDot(int index, ThemeData theme) {
    final active = index == _currentPage;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _pageTo(index),
      child: SizedBox(
        width: 36,
        height: 28,
        child: Center(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: active
                  ? AppColors.accent
                  : theme.colorScheme.outlineVariant.withValues(alpha: 0.7),
            ),
          ),
        ),
      ),
    );
  }

  /// 面板头的图标按钮：34 dp 见方。
  ///
  /// 用 SizedBox 包一层而不是传 `IconButton.constraints`——后者在当前
  /// Flutter 版本上被 ButtonStyle 的默认 minimumSize 压回 48dp（实测确认，
  /// 探测里 IconButton 的 RenderBox 仍是 48×48），包一层才作数。
  Widget _headButton(IconData icon, String tooltip, VoidCallback onPressed) =>
      SizedBox(
        width: 34,
        height: 34,
        child: IconButton(
          padding: EdgeInsets.zero,
          iconSize: 20,
          tooltip: tooltip,
          icon: Icon(icon),
          onPressed: onPressed,
        ),
      );

  /// 当前页序号。
  ///
  /// PageView 还没挂上时 `page` 是 null——此时按 `initialPage` 算，别按第一页：
  /// 起始页现在可以是任意一页（默认页设置 / 通知定位），报第一页会让标题先写成
  /// 灵感再被改掉，看着像闪了一下（v1.24 换页序后实测）。
  int get _currentPage {
    final ctrl = widget.pageCtrl;
    final page = ctrl.hasClients
        ? (ctrl.page ?? ctrl.initialPage.toDouble())
        : ctrl.initialPage.toDouble();
    return page.round().clamp(0, PanelPage.values.length - 1);
  }

  /// 点圆点直接跳页（页序指示本身就是跳转靶）。
  void _pageTo(int page) {
    if (!widget.pageCtrl.hasClients) return;
    widget.pageCtrl.animateToPage(page.clamp(0, PanelPage.values.length - 1),
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic);
  }
}

/// 主线覆盖页的进出过渡（§6.9）：整块从面板顶边上方滑下来，退场原路滑回。
///
/// 动画留在面板层：`AppController` 只翻 `mainlineOpen` 这个布尔值，覆盖页自己
/// 不知道它在滑——两处宿主（应用内壳 / 系统级悬浮窗）与桌面左栏共用同一个
/// [SidePanel]，所以不必各接一路。
///
/// 退场跑完才摘子树：滑动途中覆盖页仍然活着，它的 State 与编辑态都还在
/// （提前摘掉的话，滑出的那 200ms 里返回键会穿透到面板，守卫与对话框一起消失）。
class _MainlineReveal extends StatefulWidget {
  /// 覆盖页该不该在（= `AppController.mainlineOpen`）。
  final bool open;

  /// 上滑退出的跟手行程（逻辑像素，0 = 没推）。
  final ValueListenable<double> exit;

  /// 手指还按着（false = 松手，该补满或弹回）。
  final ValueListenable<bool> exiting;

  /// 覆盖页本体。
  final Widget child;

  const _MainlineReveal({
    required this.open,
    required this.exit,
    required this.exiting,
    required this.child,
  });

  @override
  State<_MainlineReveal> createState() => _MainlineRevealState();
}

class _MainlineRevealState extends State<_MainlineReveal>
    with SingleTickerProviderStateMixin {
  /// 进场比退场慢：推上来要有分量，收回去要利落。
  static const Duration _enter = Duration(milliseconds: 260);
  static const Duration _exit = Duration(milliseconds: 200);

  /// 覆盖页高度：上滑行程是像素，得换成 SlideTransition 要的比例。
  double _height = 0;

  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: _enter,
    reverseDuration: _exit,
  )..addStatusListener(_onStatus);

  /// 位移按自身高度的比例算：−1 = 整块躲在面板顶边之上，外面由宿主那层
  /// `ClipRRect` 裁掉，所以面板外面看不见"露出的半截"。
  ///
  /// 退场用 `easeInCubic`：它是 `easeOutCubic` 的时间镜像，退回路径就不会
  /// 先在原地磨蹭、最后一下窜走。
  late final Animation<Offset> _slide = Tween<Offset>(
    begin: const Offset(0, -1),
    end: Offset.zero,
  ).animate(CurvedAnimation(
    parent: _ctrl,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  ));

  @override
  void initState() {
    super.initState();
    // 一开始就是开的（面板重建时覆盖页正开着）：直接落位，不补放一次进场。
    if (widget.open) _ctrl.value = 1;
    widget.exit.addListener(_onExit);
    widget.exiting.addListener(_onExiting);
  }

  /// 跟手退出：推多少走多少（行程是像素，得换成自身的比例）。
  void _onExit() {
    if (!mounted || !widget.open || _height <= 0) return;
    // 松手之后由动画接手，不再逐帧设值——否则会和 animateTo 抢同一个 controller。
    if (!widget.exiting.value) return;
    _ctrl.stop();
    _ctrl.value = (1 - widget.exit.value / _height).clamp(0.0, 1.0);
  }

  /// 松手：关掉了交给 `didUpdateWidget` 播退场；没关成（编辑态守卫拦下）就弹回。
  void _onExiting() {
    if (!mounted || widget.exiting.value || !widget.open) return;
    _ctrl.animateTo(1, duration: _exit, curve: Curves.easeOutCubic);
  }

  void _onStatus(AnimationStatus status) {
    // 停在"退场跑完"这一刻：setState 让 build 摘掉子树，覆盖页随之 dispose。
    if (status == AnimationStatus.dismissed && !widget.open && mounted) {
      setState(() {});
    }
  }

  @override
  void didUpdateWidget(covariant _MainlineReveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.exit != widget.exit) {
      oldWidget.exit.removeListener(_onExit);
      widget.exit.addListener(_onExit);
    }
    if (oldWidget.exiting != widget.exiting) {
      oldWidget.exiting.removeListener(_onExiting);
      widget.exiting.addListener(_onExiting);
    }
    if (widget.open == oldWidget.open) return;
    if (widget.open) {
      _ctrl.forward();
    } else {
      _ctrl.reverse();
    }
  }

  @override
  void dispose() {
    widget.exit.removeListener(_onExit);
    widget.exiting.removeListener(_onExiting);
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.open && _ctrl.isDismissed) return const SizedBox.shrink();
    return AbsorbPointer(
      // 退场那 200ms 里不再接手势：这一页正在关，点到的不该是它。
      absorbing: !widget.open,
      child: LayoutBuilder(builder: (context, constraints) {
        _height = constraints.maxHeight;
        return SlideTransition(position: _slide, child: widget.child);
      }),
    );
  }
}

/// 今日编排覆盖页的进出过渡（§6.11）：**跟手**，不是定长动画。
///
/// 与 [_MainlineReveal] 的差别只在驱动源：主线是"点一下 → 播 260ms"，
/// 编排是"手指往下拉多少，它就露多少"，松手才补满或弹回。跟手行程由今日页
/// 从 `OverscrollNotification` 里喂给控制器（逻辑像素），这里除以自己的高度换成
/// 0–1；不足一指的高度差看不出来。
class _PlanReveal extends StatefulWidget {
  /// 覆盖页该不该在（= `AppController.planOpen`）。
  final bool open;

  /// 打开时直接落位、不播补满动画（= 面板自己正滑进来，覆盖页得第一帧就在）。
  /// 点日期行按钮打开支线时为 false：那时面板早已在屏幕上，凭空出现才是怪事。
  final bool instantEnter;

  /// 跟手行程（逻辑像素；0 = 完全藏起来）。
  final ValueListenable<double> pull;

  /// 手指还按着（false = 松手，该补满或弹回）。
  final ValueListenable<bool> dragging;

  /// 上滑退出的跟手行程（逻辑像素，0 = 没推）。
  final ValueListenable<double> exit;

  /// 手指还按着（false = 松手，该补满或弹回）。
  final ValueListenable<bool> exiting;

  final Widget child;

  const _PlanReveal({
    required this.open,
    required this.instantEnter,
    required this.pull,
    required this.dragging,
    required this.exit,
    required this.exiting,
    required this.child,
  });

  @override
  State<_PlanReveal> createState() => _PlanRevealState();
}

class _PlanRevealState extends State<_PlanReveal>
    with SingleTickerProviderStateMixin {
  /// 松手后的补满 / 弹回（与主线的退场同一档）。
  static const Duration _settle = Duration(milliseconds: 200);

  /// 在 initState 里建：写成 `late final … = AnimationController(...)` 的话，藏起来
  /// 的时候没人碰过它，第一次碰恰好是 dispose —— 那时元素已经 deactivate，
  /// `vsync: this` 查 TickerMode 会炸。
  late final AnimationController _ctrl;

  /// 覆盖页高度：跟手行程是像素，得换成 SlideTransition 要的比例。
  double _height = 0;

  /// 子树挂没挂上：藏干净之后摘掉，免得面板里同时躺着两块覆盖页
  /// （返回按钮、`返回` 提示都会重一份，无障碍与测试都会撞上）。
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: _settle)
      ..addStatusListener(_onStatus);
    // 一开始就是开的（面板重建时覆盖页正开着）：直接落位，不补放一次进场。
    if (widget.open) {
      _ctrl.value = 1;
      _visible = true;
    }
    widget.pull.addListener(_onPull);
    widget.dragging.addListener(_onDragging);
    widget.exit.addListener(_onExit);
    widget.exiting.addListener(_onExiting);
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.dismissed && !widget.open && mounted) {
      setState(() => _visible = false);
    }
  }

  @override
  void didUpdateWidget(covariant _PlanReveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pull != widget.pull) {
      oldWidget.pull.removeListener(_onPull);
      widget.pull.addListener(_onPull);
    }
    if (oldWidget.dragging != widget.dragging) {
      oldWidget.dragging.removeListener(_onDragging);
      widget.dragging.addListener(_onDragging);
    }
    if (oldWidget.exit != widget.exit) {
      oldWidget.exit.removeListener(_onExit);
      widget.exit.addListener(_onExit);
    }
    if (oldWidget.exiting != widget.exiting) {
      oldWidget.exiting.removeListener(_onExiting);
      widget.exiting.addListener(_onExiting);
    }
    if (widget.open != oldWidget.open) {
      if (widget.open && !_visible) setState(() => _visible = true);
      if (widget.open && _ctrl.value == 0 && widget.instantEnter) {
        // 从"整个藏着"直接打开 = 面板展开即落编排（§6.11）：这一下**不播进场
        // 动画**。播的话那 200ms 里露着的是它底下的今日清单，看着就是"先给清单、
        // 再切成编排"。跟手拉出来那一路此刻 `_ctrl.value` 已经大于 0，照旧补满。
        _ctrl.value = 1;
      } else {
        _ctrl.animateTo(widget.open ? 1 : 0,
            duration: _settle, curve: Curves.easeOutCubic);
      }
    }
  }

  /// 跟手：手指拉多少就露多少（比例直接由行程算，不再插值）。
  void _onPull() {
    if (!mounted || widget.open || !widget.dragging.value || _height <= 0) return;
    _ctrl.stop();
    if (!_visible) setState(() => _visible = true);
    _ctrl.value = (widget.pull.value / _height).clamp(0.0, 1.0);
  }

  /// 松手：控制器已经决定开还是不开（[AppController.settlePlan]），这里只补动画。
  void _onDragging() {
    if (!mounted || widget.dragging.value) return;
    _ctrl.animateTo(widget.open ? 1 : 0,
        duration: _settle, curve: Curves.easeOutCubic);
  }

  /// 跟手退出：时间轴推掉多少，覆盖页就往上藏多少。
  void _onExit() {
    if (!mounted || !widget.open || _height <= 0) return;
    // 松手之后交给动画，不再逐帧设值。
    if (!widget.exiting.value) return;
    _ctrl.stop();
    _ctrl.value = (1 - widget.exit.value / _height).clamp(0.0, 1.0);
  }

  /// 松手：关掉了交给 `didUpdateWidget` 播退场；没够阈值就弹回全开。
  void _onExiting() {
    if (!mounted || widget.exiting.value || !widget.open) return;
    _ctrl.animateTo(1, duration: _settle, curve: Curves.easeOutCubic);
  }

  @override
  void dispose() {
    widget.pull.removeListener(_onPull);
    widget.dragging.removeListener(_onDragging);
    widget.exit.removeListener(_onExit);
    widget.exiting.removeListener(_onExiting);
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_visible) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        _height = constraints.maxHeight;
        return IgnorePointer(
          // 还没开（含拖到一半）：这一页不接手势，底下的列表照常滚。
          // **只能是 IgnorePointer**：AbsorbPointer 在"忽略"时仍会吃掉命中
          // 测试，整块面板就点不动了。
          ignoring: !widget.open,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, -1),
              end: Offset.zero,
            ).animate(_ctrl),
            child: widget.child,
          ),
        );
      },
    );
  }
}

/// 拖出头快记（§6.8）：方块从松手处滑到屏幕正中，再展开成一条输入框。
///
/// 只在系统级悬浮面板里用（宿主 `OverlayPanelShell`）。**没有遮罩**——底下的 App
/// 照常可见，但整层吞掉触摸（点外部即收起），否则旁边一点就跑到别的 App 里去了。
/// 提交走 [onSubmit]，落地与隐私条同一条命令（三无入池）。
class QuickNoteLayer extends StatefulWidget {
  /// 松手落点（逻辑像素，屏幕坐标）——原生方块交出来的位置。
  final Offset origin;

  final Future<void> Function(String) onSubmit;
  final VoidCallback onClose;

  const QuickNoteLayer({
    super.key,
    required this.origin,
    required this.onSubmit,
    required this.onClose,
  });

  @override
  State<QuickNoteLayer> createState() => _QuickNoteLayerState();
}

class _QuickNoteLayerState extends State<QuickNoteLayer>
    with SingleTickerProviderStateMixin {
  /// 方块 52dp；展开后是这条胶囊输入框。
  static const double _box = 52;
  static const double _maxBarWidth = 360;

  late final AnimationController _ctrl;
  final TextEditingController _text = TextEditingController();
  final FocusNode _focus = FocusNode();

  /// 动画放完才把 TextField 挂上：宽度还在插值中间时挂上，焦点会落在
  /// 一个尺寸还在变的输入框上，IME 有时不弹。
  bool _expanded = false;
  bool _justSent = false;
  Timer? _checkTimer;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 360),
    )
      ..addStatusListener((status) {
        if (status != AnimationStatus.completed || !mounted) return;
        setState(() => _expanded = true);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _focus.requestFocus();
        });
      })
      ..forward();
  }

  @override
  void dispose() {
    _checkTimer?.cancel();
    _ctrl.dispose();
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final title = _text.text.trim();
    if (title.isEmpty) return;
    _text.clear();
    await widget.onSubmit(title);
    if (!mounted) return;
    setState(() => _justSent = true);
    _checkTimer?.cancel();
    _checkTimer = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _justSent = false);
    });
    // 连记：焦点留在输入框里，键盘不落。
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    // 键盘弹出时窗口被 ADJUST_RESIZE 缩小，这里的中心自然落到"键盘上方那块"的
    // 中间——小屏上也不会被键盘压住。
    final center = Offset(mq.size.width / 2, mq.size.height / 2);
    final barWidth =
        math.min(_maxBarWidth, math.max(_box, mq.size.width - 48));

    return Stack(
      children: [
        // 点外部 = 丢弃草稿收起。behavior.opaque 让它吞掉整层触摸。
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onClose,
            child: const SizedBox.expand(),
          ),
        ),
        AnimatedBuilder(
          animation: _ctrl,
          builder: (context, _) {
            final t = _ctrl.value;
            // 前 60% 走位，后 40% 展开——两段都缓出，接缝处速度接近 0。
            final moveT = Curves.easeOutCubic.transform((t / 0.6).clamp(0.0, 1.0));
            final growT =
                Curves.easeOutCubic.transform(((t - 0.6) / 0.4).clamp(0.0, 1.0));
            final pos = Offset.lerp(widget.origin, center, moveT)!;
            final width = _box + (barWidth - _box) * growT;
            return Positioned(
              left: pos.dx - width / 2,
              top: pos.dy - _box / 2,
              width: width,
              height: _box,
              child: GestureDetector(
                // 点在自己身上不该关（否则一碰就走了）。
                onTap: () {},
                child: Container(
                  decoration: BoxDecoration(
                    color: Theme.of(context).cardTheme.color,
                    borderRadius: BorderRadius.circular(_box / 2),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.28),
                        blurRadius: 18,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: _expanded ? _buildField() : _buildBlock(),
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  /// 方块阶段：一个加号。空心、无字——旁边人看不出这是在用清单。
  Widget _buildBlock() => const Center(
        child: Icon(Icons.add, size: 26, color: Color(0x8A000000)),
      );

  Widget _buildField() {
    return Row(
      children: [
        const SizedBox(width: 16),
        Expanded(
          child: TextField(
            controller: _text,
            focusNode: _focus,
            autofocus: true,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _submit(),
            decoration: const InputDecoration(
              hintText: '记一条，回车入池',
              border: InputBorder.none,
              isDense: true,
            ),
          ),
        ),
        _justSent
            ? IconButton(
                icon: Icon(Icons.check_circle_outline,
                    color: AppColors.accent),
                onPressed: null,
              )
            : IconButton(
                icon: Icon(Icons.arrow_upward, color: AppColors.accent),
                onPressed: _submit,
              ),
        const SizedBox(width: 4),
      ],
    );
  }
}

/// 首次拖出引导（决议 21）：一次性五步气泡——展开 / 翻页 / 添加 / 快记 / 编排。
///
/// 今日编排没有常驻入口行（§6.11），这条引导是它唯一的"这里有东西"的线索。
class PanelOnboardDialog extends StatelessWidget {
  const PanelOnboardDialog({super.key});

  @override
  Widget build(BuildContext context) {
    // 每条一句：首次引导只教"手往哪放"，细枝末节留给实际用一次。
    const steps = [
      (Icons.swipe_left_alt, '拖出展开', '朝屏内拖边缘那条细线即开；长按换边'),
      (Icons.swap_horiz, '横滑翻页', '疑问 / 今日 / 池子 / 已完成，左右横拖切换'),
      (Icons.add_circle_outline, '右下角两个钮', '「+」新建任务，「日历」看月历'),
      (Icons.edit_note, '拖到顶再拐个弯', '不开面板，直接记一条（悬浮把手上）'),
      (Icons.timeline, '今日页滚到顶再往下拉', '翻出今日编排：今天几点做什么，一条时间轴'),
    ];
    return AlertDialog(
      title: const Text('五步上手'),
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

/// 尺寸固定后收起把手的判定阈值：**面板宽的一半**（§6.0）。
///
/// 只看距离不看速度——与"拉开"侧（72dp 或快甩）刻意不对称：推回去是"看完了"
/// 的确认动作，宁可慢一点，不能甩一下就把面板关了；跟手走完半程本身已经是
/// 明确意图。用面板宽而不是固定 dp，是因为宽窄屏上面板差一倍，固定的 180dp
/// 在 240dp 宽的面板上等于"几乎拖到底"。
const double panelCollapseRatio = 0.5;

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
/// **尺寸固定后**（`settings.panelSizeLocked`）两条把手一起撤掉：底边那条不
/// 渲染，内侧竖条就地换成**收起把手**——朝停靠侧横拖即把面板跟手推出去
/// （[onCollapsePull] 实时上报累计位移），松手上报考判定（[onCollapseRelease]，
/// 过 [panelCollapseRatio] × 面板宽 = 缩回）。面板自己不动：跟手位移由宿主
/// 施加，因为它才知道面板该往哪个方向滑多远。
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

  /// 尺寸固定时的收起把手：拖动中实时上报朝停靠侧推的累计位移（dp，正 = 往
  /// 屏外）。宿主按它画跟手位移。null = 不接（逻辑上等于把手只是个装饰）。
  final ValueChanged<double>? onCollapsePull;

  /// 收起把手松手：`true` = 判定缩回（拖过 [panelCollapseRatio] × 面板宽），
  /// `false` = 回弹。宿主负责把面板送到底或送回原位。
  final ValueChanged<bool>? onCollapseRelease;

  const ResizablePanel({
    super.key,
    required this.controller,
    required this.dockLeft,
    required this.child,
    this.anchorCenterY,
    this.onCollapsePull,
    this.onCollapseRelease,
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
    final sizeLocked = widget.controller.settings.panelSizeLocked;
    return Padding(
      // 宿主把面板放在可用区顶，这里在区内落到锚点居中位。
      padding: EdgeInsets.only(top: top - slotTop),
      child: SizedBox(
        width: width,
        height: height,
        // 把手贴在面板内沿（不探出边界——探出部分落在 Stack 的命中
        // 测试区之外，边界点按不碎；贴内沿整条都在可命中范围内）。
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            widget.child,
            // 竖把手：内侧边缘整条（停左贴右缘内沿、停右贴左缘内沿）。
            // 尺寸固定后它不再改宽，改成把面板跟手推出去收起。
            Positioned(
              top: 0,
              bottom: 0,
              left: widget.dockLeft ? width - _kEdgeGrab : null,
              right: widget.dockLeft ? null : width - _kEdgeGrab,
              child: sizeLocked
                  ? _PanelCollapseEdge(
                      dockLeft: widget.dockLeft,
                      threshold: width * panelCollapseRatio,
                      onPull: widget.onCollapsePull ?? (_) {},
                      onRelease: widget.onCollapseRelease ?? (_) {},
                    )
                  : _PanelResizeEdge(
                      axis: Axis.horizontal,
                      onResize: (dx) => _onResizeWidth(widget.dockLeft ? dx : -dx),
                      onResizeEnd: _onResizeEnd,
                    ),
            ),
            // 高把手：底边横条（贴底边内沿）；尺寸固定后没有可改的，不渲染。
            if (!sizeLocked)
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

/// 面板内侧的**收起把手**（§6.0：尺寸固定后接管原本改宽那条竖条的位置）：
/// 朝停靠侧横拖即把面板跟手推出去——拖动中实时上抛累计位移，松手按
/// [threshold]（面板宽的一半）判定缩回还是回弹。
///
/// 判定只看累计距离、不看速度：推回去是"看完了"的确认动作，宁可慢一点。
/// 反向拖（往屏内）不减计数到负数——手指来回蹭不会攒出负位移。
class _PanelCollapseEdge extends StatefulWidget {
  /// true = 面板停左（往左推 = 推回屏外）；false = 停右（往右推）。
  final bool dockLeft;

  /// 判定缩回的距离（dp）。
  final double threshold;

  final ValueChanged<double> onPull;
  final ValueChanged<bool> onRelease;

  const _PanelCollapseEdge({
    required this.dockLeft,
    required this.threshold,
    required this.onPull,
    required this.onRelease,
  });

  @override
  State<_PanelCollapseEdge> createState() => _PanelCollapseEdgeState();
}

class _PanelCollapseEdgeState extends State<_PanelCollapseEdge> {
  /// 本次拖动朝停靠侧的累计位移（dp）。
  double _pull = 0;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.grab,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (_) => _pull = 0,
        onHorizontalDragUpdate: (d) {
          final delta = widget.dockLeft ? -d.delta.dx : d.delta.dx;
          final next = _pull + delta;
          _pull = next < 0 ? 0 : next;
          widget.onPull(_pull);
        },
        onHorizontalDragEnd: (_) {
          widget.onRelease(_pull >= widget.threshold);
          _pull = 0;
        },
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

/// 悬浮窗宿主的组装件：面板 + 半透明遮罩。
///
/// 与安卓壳共用同一份 [SidePanel]；差别只在宿主容器：
/// 这里的面板浮在其他 App 之上（窗口背景透明），点遮罩即收起。
class FloatingPanel extends StatelessWidget {
  final AppController controller;
  final PageController pageCtrl;
  final VoidCallback onCollapse;
  final VoidCallback onOpenCalendar;
  final VoidCallback onOpenSettings;

  /// 尺寸固定时收起把手的回调：透传给 [ResizablePanel] 的同名参数（§6.0）。
  /// 悬浮窗侧的跟手位移就是 [progress]，所以这两条由宿主换算后回填。
  final ValueChanged<double>? onCollapsePull;
  final ValueChanged<bool>? onCollapseRelease;

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
    required this.onOpenCalendar,
    required this.onOpenSettings,
    this.dockLeft = false,
    this.anchorCenterY,
    this.progress = 1,
    this.onCollapsePull,
    this.onCollapseRelease,
  });

  @override
  Widget build(BuildContext context) {
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
            onCollapsePull: onCollapsePull,
            onCollapseRelease: onCollapseRelease,
            child: SidePanel(
              controller: controller,
              pageCtrl: pageCtrl,
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

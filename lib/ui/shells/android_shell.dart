import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../dialogs/calendar_dialog.dart';
import '../panels/notes_panel.dart';
import '../panels/side_panel.dart';
import '../panels/pool_panel.dart';
import '../panels/settings_panel.dart';
import '../panels/today_panel.dart';
import '../theme.dart';
import '../widgets/reminder_listener.dart';

/// 安卓壳（§5.1 shells / ui-interaction.md §6）：
/// - App 主体 = 设置页（"App 主体几乎不开"）；
/// - 悬浮侧边栏 = 应用内实现的贴屏把手 + 拖出展开（系统级悬浮窗的
///   PermissionPort/原生服务在设备阶段接入，交互协议与本文档一致）；
/// - 三页**左右横滑**：今日清单 → 疑问笔记 → 任务池；横方向与列表的纵向滚动
///   正交，互不抢手（v0.15；原先的"竖翻 + 面板头重手势"已删）；
/// - 隐私过头：点面板头的『隐私』按钮 → 隐藏全部清单内容，只留一条极简输入框
///   （v0.15：原先"面板拖拽过头"那道横滑手势已删，它和翻页抢横方向）；
/// - 抽屉兜底（§11）：同一套 panels，App 内左侧滑呼出。
class AndroidShell extends StatefulWidget {
  final AppController controller;

  const AndroidShell({super.key, required this.controller});

  @override
  State<AndroidShell> createState() => _AndroidShellState();
}

class _AndroidShellState extends State<AndroidShell> {
  final PageController _pageCtrl = PageController();
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  bool _panelOpen = false;
  bool _privacy = false;
  bool _panelOnLeft = false; // 把手停靠侧
  double _handleDy = 180;

  // 装配点/原生把手的请求（AppController 计数器）：打开面板、关面板、定位翻页
  int _seenPanelRequest = 0;
  int _seenCloseRequest = 0;


  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChange);
    _seenPanelRequest = widget.controller.panelOpenRequest;
    _seenCloseRequest = widget.controller.panelCloseRequest;
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChange);
    _pageCtrl.dispose();
    super.dispose();
  }

  /// 控制器把它当"事件总线"用：原生把手拖出 → 开面板；点通知 → 开面板并定位；
  /// 『编辑规则』 → 关面板跳设置页；通知按钮 → toast 反馈。
  void _onChange() {
    if (!mounted) return;
    final c = widget.controller;
    setState(() {});
    if (c.panelCloseRequest != _seenCloseRequest) {
      _seenCloseRequest = c.panelCloseRequest;
      _closePanel();
    }
    if (c.panelOpenRequest != _seenPanelRequest) {
      _seenPanelRequest = c.panelOpenRequest;
      _openPanel();
      _jumpToPage(c.focusPage);
    }
    final notice = c.consumeNotice();
    if (notice != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(notice)));
      });
    }
  }

  void _jumpToPage(int page) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_pageCtrl.hasClients) return;
      _pageCtrl.animateToPage(page.clamp(0, 2),
          duration: const Duration(milliseconds: 260), curve: Curves.easeOutCubic);
    });
  }

  void _openPanel() {
    setState(() {
      _privacy = false;
      _panelOpen = true;
    });
    _maybeOnboard();
  }

  void _closePanel() => setState(() => _panelOpen = false);

  void _enterPrivacy() => setState(() {
        _privacy = true;
        _panelOpen = false;
      });

  void _maybeOnboard() {
    if (widget.controller.settings.guideSeen) return;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || widget.controller.settings.guideSeen) return;
      await showDialog<void>(context: context, builder: (_) => const PanelOnboardDialog());
      await widget.controller
          .updateSettings(widget.controller.settings.copyWith(guideSeen: true));
    });
  }

  // ---- 翻页（左右横滑由 PageView 自己接管，v0.15；这里只管点通知后的定位）----

  // ---- 隐私输入（等价堆三无，决议 22；入口是面板头的『隐私』按钮，v0.15）----

  Future<void> _privacySubmit(String text) async {
    final title = text.trim();
    if (title.isEmpty) return;
    await widget.controller.createTask(title: title);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('已静默入池'),
        duration: Duration(seconds: 2),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return ReminderListener(
      controller: controller,
      child: PopScope(
        canPop: !_panelOpen && !_privacy,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) return;
          if (_privacy) {
            setState(() => _privacy = false);
          } else {
            _closePanel();
          }
        },
        child: Stack(
          clipBehavior: Clip.hardEdge,
          children: [
            Scaffold(
              key: _scaffoldKey,
              appBar: AppBar(
                title: const Text('动态任务调度 Todo'),
                leading: IconButton(
                  tooltip: '抽屉兜底（同一套面板）',
                  icon: const Icon(Icons.menu),
                  onPressed: () => _scaffoldKey.currentState?.openDrawer(),
                ),
                actions: [
                  IconButton(
                    tooltip: '悬浮侧边栏',
                    icon: const Icon(Icons.swipe_left_alt),
                    onPressed: _openPanel,
                  ),
                ],
              ),
              drawer: _DrawerFallback(controller: controller),
              body: SettingsPanel(controller: controller),
              floatingActionButton: FloatingActionButton.extended(
                heroTag: 'open-sidebar',
                onPressed: _openPanel,
                icon: const Icon(Icons.view_sidebar),
                label: const Text('侧边栏'),
              ),
            ),
            ..._overlay(context),
          ],
        ),
      ),
    );
  }

  // ---- 悬浮层：遮罩 / 把手 / 面板 / 隐私输入条 ----

  List<Widget> _overlay(BuildContext context) {
    final size = MediaQuery.of(context).size;
    // 面板宽度由 ResizablePanel 自算（设置值 / 默认公式 / 拖拽实时值）；
    // 收起时滑出屏外的落点要按同一宽度算，这里取一次当前值——拖拽只发生
    // 在展开态，用不到它。
    final panelWidth = panelWidthFor(widget.controller.settings, size.width);
    final children = <Widget>[];

    // 把手：贴屏白条、上下拖动停靠；点按 / 横拖朝屏内 = 展开；长按 = 换边。
    // 与外层系统级把手分工（v1.5 修订）：应用在前台时系统把手自动隐藏（原生侧
    // 监听 Activity 前后台），所以应用内把手**始终显示**——每个场景恰好一个把手，
    // 不会出现"两个把手叠在一起"或"把手指着面板碍事"。
    children.add(_Handle(
      dy: _handleDy.clamp(24, size.height - _kHandleHeight - 32),
      onLeft: _panelOnLeft,
      onDrag: (dy) => setState(() => _handleDy = dy),
      onOpen: _openPanel,
      onDockSwitch: () => setState(() => _panelOnLeft = !_panelOnLeft),
    ));

    // 隐私过头：只留一条极简输入框（不渲染任何任务数据，§11）
    if (_privacy) {
      children.add(PanelPrivacyBar(onSubmit: _privacySubmit));
    }

    // 面板打开时的遮罩
    if (_panelOpen) {
      children.add(Positioned.fill(
        child: GestureDetector(
          onTap: _closePanel,
          child: Container(color: Colors.black26),
        ),
      ));
    }

    // 侧边栏面板：关 = 滑出屏外；开 = 滑入（宽高与拖拽语义都在
    // ResizablePanel 里，两个宿主共用）。
    children.add(AnimatedPositioned(
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
      // 只锚顶：高度由 ResizablePanel 自持，底边随拖拽走。
      top: MediaQuery.of(context).padding.top + 8,
      left: _panelOnLeft ? (_panelOpen ? 6 : -panelWidth - 12) : null,
      right: _panelOnLeft ? null : (_panelOpen ? 6 : -panelWidth - 12),
      child: IgnorePointer(
        ignoring: !_panelOpen,
        child: ResizablePanel(
          controller: widget.controller,
          dockLeft: _panelOnLeft,
          // 面板垂直居中于把手（ui-interaction.md §6.0）：把手的中心即锚点。
          anchorCenterY: _handleDy + _kHandleHeight / 2,
          child: SidePanel(
            controller: widget.controller,
            pageCtrl: _pageCtrl,
            onClose: _closePanel,
            onPrivacy: _enterPrivacy,
            onOpenCalendar: () =>
                showCalendarDialog(context, widget.controller),
          ),
        ),
      ),
    ));

    return children;
  }
}

// 把手（v1.10 / 决议 40）：贴在边缘的一段半透明白条，10×88dp、白色 55% 不透明，
// 与原生悬浮把手同一套参数——两个场景共用一个把手（决议 34），外观必须一致。
// 外观改了，**能做的事一条没少**：竖向拖动换位置、横向拖出展开、点按展开、长按换边。
// 点按是后补的：它同时是决议 41 的兜底入口（ROM 不认手势排除区时仍打得开）。

/// 把手高度（dp）：[_Handle] 的外观与"面板居中于把手"的锚点计算共用这一个数。
const double _kHandleHeight = 88;

class _Handle extends StatelessWidget {
  final double dy;
  final bool onLeft;
  final ValueChanged<double> onDrag;
  final VoidCallback onOpen;
  final VoidCallback onDockSwitch;

  const _Handle({
    required this.dy,
    required this.onLeft,
    required this.onDrag,
    required this.onOpen,
    required this.onDockSwitch,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: dy,
      left: onLeft ? 0 : null,
      right: onLeft ? null : 0,
      child: GestureDetector(
        onVerticalDragUpdate: (d) => onDrag(dy + d.delta.dy),
        onHorizontalDragEnd: (d) {
          final v = d.velocity.pixelsPerSecond.dx;
          final towardCenter = onLeft ? v > 500 : v < -500;
          if (towardCenter) onOpen();
        },
        onTap: onOpen,
        onLongPress: onDockSwitch, // 长按：停靠到另一侧
        child: Container(
          width: 10,
          height: _kHandleHeight,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.55),
            borderRadius: BorderRadius.horizontal(
              left: onLeft ? Radius.zero : const Radius.circular(5),
              right: onLeft ? const Radius.circular(5) : Radius.zero,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.12),
                blurRadius: 3,
                offset: Offset(onLeft ? 1 : -1, 1),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 抽屉兜底（§11）：悬浮窗被拒时，同一套 panels 在 App 内左侧滑呼出。
class _DrawerFallback extends StatelessWidget {
  final AppController controller;

  const _DrawerFallback({required this.controller});

  @override
  Widget build(BuildContext context) {
    return Drawer(
      // 与悬浮侧边栏同一个宽度设置（没拖过 = 默认公式）
      width: panelWidthFor(
          controller.settings, MediaQuery.of(context).size.width),
      child: DefaultTabController(
        length: 3,
        child: Scaffold(
          appBar: TabBar(
            tabs: const [
              Tab(text: '今日'),
              Tab(text: '笔记'),
              Tab(text: '池子'),
            ],
            labelColor: AppColors.accent,
          ),
          body: TabBarView(
            children: [
              Stack(children: [
                TodayPanel(controller: controller),
                PanelActions(controller: controller, heroTagPrefix: 'drawer'),
              ]),
              NotesPanel(controller: controller),
              Stack(children: [
                PoolPanel(controller: controller),
                PanelActions(controller: controller, heroTagPrefix: 'drawer'),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}

/// 面板右下角的添加区：添加待办 + 堆三无（§6.1 每页都可添加）。
/// [heroTagPrefix] 区分面板/抽屉两处实例，避免 Hero 标签冲突。

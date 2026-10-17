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

class _AndroidShellState extends State<AndroidShell>
    with SingleTickerProviderStateMixin {
  final PageController _pageCtrl = PageController();
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  bool _panelOpen = false;
  bool _privacy = false;
  bool _panelOnLeft = false; // 把手停靠侧
  double _handleDy = 180;

  // ---- 尺寸固定后的跟手推出收起（§6.0）----

  /// 面板被推出去的进度：0 = 展开位，1 = 完全滑出屏外。只在 [_panelSliding]
  /// 期间作数，其余时候位置由 [_panelOpen] 决定。
  double _panelSlide = 0;

  /// true = 面板位置由 [_panelSlide] 实时决定（拖动中 / 松手补间中），走无动画
  /// `Positioned` 才能跟手；false = 交回 `AnimatedPositioned` 归 [_panelOpen]。
  bool _panelSliding = false;

  /// 松手后的补间：把面板送到 1（缩回）或 0（回弹）。
  late final AnimationController _slideCtrl;
  bool _slideToClose = false;

  // 装配点/原生把手的请求（AppController 计数器）：打开面板、关面板、定位翻页
  int _seenPanelRequest = 0;
  int _seenCloseRequest = 0;


  @override
  void initState() {
    super.initState();
    _slideCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 180))
      ..addListener(_onSlideTick)
      ..addStatusListener(_onSlideStatus);
    widget.controller.addListener(_onChange);
    _seenPanelRequest = widget.controller.panelOpenRequest;
    _seenCloseRequest = widget.controller.panelCloseRequest;
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChange);
    _slideCtrl.dispose();
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
      _panelSliding = false;
      _panelSlide = 0;
    });
    _maybeOnboard();
  }

  void _closePanel() => setState(() {
        _panelOpen = false;
        _panelSliding = false;
        _panelSlide = 0;
      });

  // ---- 尺寸固定后的跟手推出收起（§6.0）----

  /// 面板跟手推出：横移量 = 手指位移，一路推到屏外。手指定的是"推出去多少
  /// dp"，这里换算成 0..1 的行程比例（行程 = 面板宽 + 18，与收起落点一致）。
  void _onPanelCollapsePull(double pull) {
    final width =
        panelWidthFor(widget.controller.settings, MediaQuery.of(context).size.width);
    setState(() {
      _panelSliding = true;
      _panelSlide = (pull / (width + 18)).clamp(0.0, 1.0);
    });
  }

  /// 松手：判定缩回就送到 1（走 [`_closePanel`] 那条收起路），否则回弹到 0。
  /// 剩余行程越多动得越久，与悬浮窗宿主同一档（60–220ms）。
  void _onPanelCollapseRelease(bool close) {
    _slideToClose = close;
    _slideCtrl.value = _panelSlide;
    final remain = close ? 1 - _panelSlide : _panelSlide;
    _slideCtrl.duration =
        Duration(milliseconds: (60 + 140 * remain).round().clamp(60, 220));
    _slideCtrl.animateTo(close ? 1.0 : 0.0, curve: Curves.easeOutCubic);
  }

  void _onSlideTick() {
    if (!mounted || !_slideCtrl.isAnimating) return;
    setState(() => _panelSlide = _slideCtrl.value);
  }

  void _onSlideStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    // 两个终点都交给 _panelOpen / AnimatedPositioned 接着——交接处位置与遮罩
    // 浓度都对齐（slide=1 与"屏外落点"是同一个位置，slide=0 就是展开位），
    // 所以不闪。
    if (_slideToClose) {
      _closePanel();
    } else {
      setState(() {
        _panelSliding = false;
        _panelSlide = 0;
      });
    }
  }

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
                title: const Text('GTD Todo'),
                leading: IconButton(
                  tooltip: '菜单',
                  icon: const Icon(Icons.menu),
                  onPressed: () => _scaffoldKey.currentState?.openDrawer(),
                ),
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
    // 跟手推出期间面板的横移量（dp）：0 = 展开位，行程走满 = 收起落点
    // （展开时离屏缘 6，落点在屏外 12，所以行程 = 面板宽 + 18）。
    final slideOut = _panelSlide * (panelWidth + 18);
    final children = <Widget>[];

    // 把手：贴屏白条、上下拖动停靠；点按 / 横拖朝屏内 = 展开；长按 = 换边。
    // 与外层系统级把手分工（v1.5 修订）：应用在前台时系统把手自动隐藏（原生侧
    // 监听 Activity 前后台），所以应用内把手**始终显示**——每个场景恰好一个把手，
    // 不会出现"两个把手叠在一起"或"把手指着面板碍事"。
    children.add(_Handle(
      dy: _handleDy.clamp(24, size.height - _kHotHeight - 32),
      onLeft: _panelOnLeft,
      locked: widget.controller.settings.handleLocked,
      hotWidth: widget.controller.settings.handleHotWidth.toDouble(),
      onDrag: (dy) => setState(() => _handleDy = dy),
      onOpen: _openPanel,
      onDockSwitch: () => setState(() => _panelOnLeft = !_panelOnLeft),
    ));

    // 隐私过头：只留一条极简输入框（不渲染任何任务数据，§11）
    if (_privacy) {
      children.add(PanelPrivacyBar(onSubmit: _privacySubmit));
    }

    // 遮罩：跟着面板一起渐显渐隐（原来是硬切一层黑）。关着时不吃点击。
    // 跟手推出期间面板走多少、遮罩就淡多少——所以那一档用无动画的 Container
    // （AnimatedContainer 会滞后 240ms，跟手时看着像没跟上）。两个分支在交接
    // 处的浓度一致（slide=1 → 0，slide=0 → 0.26），切过去不闪。
    children.add(Positioned.fill(
      child: IgnorePointer(
        ignoring: !_panelOpen,
        child: GestureDetector(
          onTap: _closePanel,
          child: _panelSliding
              ? Container(
                  color: Colors.black
                      .withValues(alpha: 0.26 * (1 - _panelSlide)))
              : AnimatedContainer(
                  duration: const Duration(milliseconds: 240),
                  curve: Curves.easeOutCubic,
                  color: Colors.black.withValues(alpha: _panelOpen ? 0.26 : 0),
                ),
        ),
      ),
    ));

    // 侧边栏面板：关 = 滑出屏外；开 = 滑入（宽高与拖拽语义都在
    // ResizablePanel 里，两个宿主共用）。跟手推出期间位置由 _panelSlide
    // 实时给（无动画），其余时候交给 AnimatedPositioned 做滑入滑出。
    final panelContent = IgnorePointer(
      ignoring: !_panelOpen,
      child: ResizablePanel(
        controller: widget.controller,
        dockLeft: _panelOnLeft,
        // 面板垂直居中于把手（ui-interaction.md §6.0）：把手的中心即锚点
        // （热区中心 = 白条中心，白条在热区里竖直居中）。
        anchorCenterY: _handleDy + _kHotHeight / 2,
        onCollapsePull: _onPanelCollapsePull,
        onCollapseRelease: _onPanelCollapseRelease,
        child: SidePanel(
          controller: widget.controller,
          pageCtrl: _pageCtrl,
          onClose: _closePanel,
          onPrivacy: _enterPrivacy,
          onOpenCalendar: () => showCalendarDialog(context, widget.controller),
        ),
      ),
    );

    children.add(_panelSliding
        ? Positioned(
            // 只锚顶：高度由 ResizablePanel 自持，底边随拖拽走。
            top: MediaQuery.of(context).padding.top + 8,
            left: _panelOnLeft ? 6 - slideOut : null,
            right: _panelOnLeft ? null : 6 - slideOut,
            child: panelContent,
          )
        : AnimatedPositioned(
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeOutCubic,
            top: MediaQuery.of(context).padding.top + 8,
            left: _panelOnLeft ? (_panelOpen ? 6 : -panelWidth - 12) : null,
            right: _panelOnLeft ? null : (_panelOpen ? 6 : -panelWidth - 12),
            child: panelContent,
          ));

    return children;
  }
}

// 把手（v1.10 / 决议 40，v1.11 再缩淡一档）：贴在边缘的一段半透明白条，
// **6×72dp、白色 35% 不透明**，与原生悬浮把手同一套参数——两个场景共用一个把手
// （决议 34），外观必须一致。
// 能做的事：竖向拖动换位置、横向拖着走拉开（拖过 72dp 或快甩）、长按换边
// （位置可上锁，锁上后竖向拖动不改高度）。
// **点按不做任何事**（v1.21 修订，§6.0）：那一下落回下层界面。它原先还是决议 41
// 的兜底入口（ROM 不认手势排除区时仍打得开），删掉的代价已登记在文档里——这类
// ROM 上的退路是 App 内的『侧边栏』按钮与抽屉。

/// 白条尺寸（dp）：与原生 `OverlayHandleService` 的 BAR_* 一致。
const double _kBarWidth = 6;
const double _kBarHeight = 72;

/// 可起手的热区**高度**（dp）：与原生一致（200dp）= 系统"每边最多兑现 200dp
/// 返回手势排除"的配额上限。**竖向不是设置项**（§6.0：调小只是自损竖拖起手的
/// 容错）。
const double _kHotHeight = 200;

/// 热区**宽度**（dp）不是这里的常量：走设置项 `handle_hot_width`
/// （细 8 / 标准 12 / 宽 20，两处把手共用同一个值，见 [_Handle.hotWidth]）。
/// 这里的取舍与系统级把手相反：热区压在**我们自己的**设置页之上，再宽就会吃掉
/// 卡片边缘的点击（设置页左右留白恰好 12dp），所以默认只给 12dp。
///
/// 热区高度见 [_kHotHeight]。

/// 横拖拉开判"展开"的最小位移（dp，§6.0）：与系统级把手同一套阈值。点按
/// （含"蹭一下"）不算——v1.21 起点按不触发任何事。
const double _kPullOpenDp = 72;

/// 快甩判"展开"的横向速度（逻辑像素/秒）：与原生把手同口径。
const double _kFlingVelocity = 500;

class _Handle extends StatefulWidget {
  final double dy;
  final bool onLeft;
  final bool locked;

  /// 热区宽度（dp）：设置项 `handle_hot_width`，与系统级把手同一个值。
  final double hotWidth;
  final ValueChanged<double> onDrag;
  final VoidCallback onOpen;
  final VoidCallback onDockSwitch;

  const _Handle({
    required this.dy,
    required this.onLeft,
    required this.locked,
    required this.hotWidth,
    required this.onDrag,
    required this.onOpen,
    required this.onDockSwitch,
  });

  @override
  State<_Handle> createState() => _HandleState();
}

class _HandleState extends State<_Handle> {
  /// 本次横拖**朝屏内**的净位移（dp）：松手时够 [_kPullOpenDp] 才展开（§6.0）。
  double _pullDx = 0;

  @override
  Widget build(BuildContext context) {
    final dy = widget.dy;
    final onLeft = widget.onLeft;
    final hotWidth = widget.hotWidth;
    return Positioned(
      top: dy,
      left: onLeft ? 0 : null,
      right: onLeft ? null : 0,
      child: GestureDetector(
        // 外层：整块热区只吃**拖动**（竖拖移位 / 横拖拉开），不挂 onTap——
        // 只有拖拽回调的探测器不会吞掉下层卡片的点击（实测确认）。
        // 上锁后竖向拖动不再改高度，横拖拉开照旧。
        onVerticalDragUpdate:
            widget.locked ? null : (d) => widget.onDrag(dy + d.delta.dy),
        onHorizontalDragStart: (_) => _pullDx = 0,
        onHorizontalDragUpdate: (d) => _pullDx += d.delta.dx,
        onHorizontalDragEnd: (d) {
          final v = d.velocity.pixelsPerSecond.dx;
          final flingToCenter = onLeft ? v > _kFlingVelocity : v < -_kFlingVelocity;
          // 朝屏内为正：左边停靠往右拖、右边停靠往左拖。
          final pulled = (onLeft ? _pullDx : -_pullDx) >= _kPullOpenDp;
          _pullDx = 0;
          if (pulled || flingToCenter) widget.onOpen();
        },
        child: SizedBox(
          width: hotWidth,
          height: _kHotHeight,
          child: Align(
            // 白条贴在**屏幕边缘**那一侧、竖直居中（与原生同口径）。
            alignment: onLeft ? Alignment.centerLeft : Alignment.centerRight,
            child: GestureDetector(
              // 内层：**长按**（换边）的靶是白条本身（上下各留 10dp 好摁），
              // 不是整块热区——热区是给"拖动起手"用的。点按没有靶：v1.21 起
              // 点按不展开（§6.0），那一下落回下层界面。
              onLongPress: widget.onDockSwitch, // 长按：停靠到另一侧
              child: SizedBox(
                width: hotWidth,
                height: _kBarHeight + 20,
                // 用 Align 而不是 Center：白条要**贴住屏幕边缘**那一侧，
                // 居中会让它离边 3dp，看起来就不像"贴边"了。
                child: Align(
                  alignment: onLeft ? Alignment.centerLeft : Alignment.centerRight,
                  child: Container(
                    width: _kBarWidth,
                    height: _kBarHeight,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.35),
                      borderRadius: BorderRadius.horizontal(
                        left: onLeft
                            ? Radius.zero
                            : Radius.circular(_kBarWidth / 2),
                        right: onLeft
                            ? Radius.circular(_kBarWidth / 2)
                            : Radius.zero,
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
              ),
            ),
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

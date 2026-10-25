import 'dart:async';

import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../dialogs/calendar_dialog.dart';
import '../panel_pages.dart';
import '../panels/side_panel.dart';
import 'overlay_bridge.dart';

/// 悬浮面板的宿主：展开 = 画遮罩 + 面板；收起 = 什么都不画（只剩原生把手）。
class OverlayPanelShell extends StatefulWidget {
  final AppController controller;
  final OverlayBridge bridge;

  const OverlayPanelShell({
    super.key,
    required this.controller,
    required this.bridge,
  });

  @override
  State<OverlayPanelShell> createState() => _OverlayPanelShellState();
}

class _OverlayPanelShellState extends State<OverlayPanelShell>
    with SingleTickerProviderStateMixin {
  /// 起手页 = 设置里的默认页（§9 第 12 条）。装配点在装配完核心（含设置）之后
  /// 才建这个宿主，所以构造时读到的就是真值，没有"先落今日再跳走"的闪。
  ///
  /// 但 `initialPage` 是建控制器那一刻定死的：设置里改过默认页之后它不会跟着
  /// 变，而收起时 PageView 会被拆掉、拖出来是重新挂上的——于是跟手拖出的那几帧
  /// 落在**老**默认页上，直到松手补满广播 expanded 才被 [_landOnDefaultPage]
  /// 纠正（现象：拖的时候是今日清单，一松手变任务池）。所以拖动起手时要
  /// [_syncLandingPage] 一次。
  late PageController _pageCtrl;
  StreamSubscription<OverlayWindowState>? _stateSub;
  StreamSubscription<OverlayDragEvent>? _dragSub;

  bool _expanded = true; // 原生 notifyReady 后会立刻纠正
  bool _dockedRight = true;

  /// 快记态（§6.8）：原生已把把手换成跟手方块，面板让位（淡出、不摘窗口）。
  bool _quickDrag = false;

  /// 快记松手后的落点：非 null = 输入条阶段（方块已交给 [QuickNoteLayer]）。
  Offset? _quickOrigin;

  /// 上一次上报给原生的面板宽（逻辑像素）：变了才上报，别每帧刷通道。
  double? _reportedPanelWidth;

  /// 原生把手的中心 Y（逻辑像素）：面板垂直居中于它（§6.0）；null = 贴顶。
  double? _handleCenterY;

  /// 跟手拉开进度：null = 没在拖；0 = 滑出屏外，1 = 全展开。
  /// 只活在本次展开里——补满后交回 [_expanded]，滑回后置 null。
  double? _dragProgress;

  /// 松手后的补满/滑回动画（剩余越多动得越久，都在 60–220ms 一档）。
  late final AnimationController _settleCtrl;
  bool _settleOpen = false;

  AppController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _pageCtrl = PageController(initialPage: defaultPanelPageIndex(_c.settings));
    _c.addListener(_onChange);
    _settleCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 180))
      ..addListener(_onSettleTick)
      ..addStatusListener(_onSettleStatus);
    _stateSub = widget.bridge.states.listen((s) {
      if (!mounted) return;
      final wasExpanded = _expanded;
      setState(() {
        _expanded = s.expanded;
        _dockedRight = s.dockedRight;
        _handleCenterY = s.handleCenterY;
        if (!s.expanded) {
          // 收起 = 跟手/快记都结束（原生已经摘窗口，别留着残影）。
          _quickDrag = false;
          _quickOrigin = null;
          _dragProgress = null;
        }
      });
      // 每次展开都落一遍默认页：跟手拖出那一路的起手页已由 [_syncLandingPage]
      // 摆对，但原生也可能不经拖动直接广播展开（降级打开 / 通知拉起），
      // 那一路上没有拖动起手——这里兜住。
      // 编排也在这一拍先立起来（§6.11）：等帧后再亮的话，面板的第一帧是今日
      // 清单，随后才被覆盖页盖住——那一下正是"滑出来先看见清单"。
      if (s.expanded && !wasExpanded) {
        _c.landOnPlanForToday();
        _landOnDefaultPage();
      }
      if (s.expanded) _maybeOnboard();
    });
    _dragSub = widget.bridge.drags.listen(_onDrag);
    // 原生"继续拖到面板宽"那条上限要用面板宽（§6.8）：首帧与设置变化时上报。
    WidgetsBinding.instance.addPostFrameCallback((_) => _reportPanelWidth());
  }

  @override
  void dispose() {
    _dragSub?.cancel();
    _stateSub?.cancel();
    _settleCtrl.dispose();
    _c.removeListener(_onChange);
    _pageCtrl.dispose();
    super.dispose();
  }

  void _onChange() {
    if (!mounted) return;
    setState(() {});
    // 放到帧后：设置变化可能来自 build 之外的回调，别在那儿读 MediaQuery。
    WidgetsBinding.instance.addPostFrameCallback((_) => _reportPanelWidth());
  }

  /// 面板宽报给原生（逻辑像素）：只在变化时发，拖宽度/换屏/锁尺寸都会触发。
  void _reportPanelWidth() {
    if (!mounted) return;
    final width =
        panelWidthFor(_c.settings, MediaQuery.of(context).size.width);
    if (width == _reportedPanelWidth) return;
    _reportedPanelWidth = width;
    widget.bridge.notifyPanelWidth(width);
  }

  /// 落到设置里选的默认页（§9 第 12 条）：用 `jumpToPage`——面板正在跟手/补满，
  /// 再来一道横扫就是两段动作。
  void _landOnDefaultPage() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_pageCtrl.hasClients) return;
      _pageCtrl.jumpToPage(defaultPanelPageIndex(_c.settings));
    });
  }

  /// 把控制器的起手页对齐到当前设置（§9 第 12 条）。
  ///
  /// 只在 PageView **没挂上**时换（收起态 / 拖动起手那一瞬）：起手页是
  /// `initialPage` 的一部分，换不了只能换控制器；正开着面板时不动——用户可能
  /// 正看着某一页，改设置不该当场把他甩走。
  void _syncLandingPage() {
    final target = defaultPanelPageIndex(_c.settings);
    if (_pageCtrl.hasClients || target == _pageCtrl.initialPage) return;
    final stale = _pageCtrl;
    _pageCtrl = PageController(initialPage: target);
    stale.dispose();
  }

  Future<void> _collapse() async {
    // 覆盖页开着就先收它（§6.9 / §6.11）；编辑态由 mainlineCloseGuard 拦一道
    await widget.controller.closeMainline();
    widget.controller.closePlan();
    if (!mounted) return;
    setState(() {
      _expanded = false;
      _quickDrag = false;
      _quickOrigin = null;
    });
    await widget.bridge.collapse();
  }

  // ------------------------------------------------------- 跟手拉开（§6.0）

  /// 原生把手的跟手事件：progress = 手指进度；end = 松手判定（原生说了算）。
  void _onDrag(OverlayDragEvent e) {
    if (!mounted) return;
    if (e is PanelDragProgress) {
      // 面板即将挂上（收起时 PageView 是拆掉的）：先把起手页摆对，跟手拖出来
      // 的第一帧就落在设置里的默认页，别等松手补满才纠（§9 第 12 条）。
      if (_dragProgress == null) {
        _syncLandingPage();
        // 编排同样要先立起来（§6.11）：跟手拖出来的每一帧都该是编排，
        // 不能先让人看见清单。
        _c.landOnPlanForToday();
      }
      setState(() => _dragProgress = _progressFor(e.dx));
    } else if (e is PanelDragEnd) {
      _settle(e.open);
    } else if (e is QuickNoteStart) {
      // 面板不摘窗口，只淡出：回拖取消时能原地恢复跟手（§6.8）。
      setState(() => _quickDrag = true);
    } else if (e is QuickNoteCancel) {
      setState(() => _quickDrag = false);
    } else if (e is QuickNoteOpen) {
      // 松手：方块交给 Dart，从落点飞向屏幕中央再展开成输入条。
      setState(() {
        _quickDrag = false;
        _quickOrigin = e.position;
      });
    }
  }

  /// 快记提交：三无入池，与隐私条（§6.5）同一条命令。
  Future<void> _quickSubmit(String title) => _c.createTask(title: title);

  /// 收输入条：摘面板窗口（原生顺手让把手回来）。
  Future<void> _closeQuickNote() async {
    if (_quickOrigin == null) return;
    setState(() => _quickOrigin = null);
    await widget.bridge.collapse();
  }

  /// 尺寸固定后面板内侧把手的**跟手收起**（§6.0）：与上面那条拉开共用同一条
  /// 进度轴——面板滑出量就是 [pull]，所以 progress = 1 − pull/面板宽。
  void _onPanelCollapsePull(double pull) {
    final width =
        panelWidthFor(_c.settings, MediaQuery.of(context).size.width);
    if (width <= 0) return;
    setState(() => _dragProgress = (1 - pull / width).clamp(0.0, 1.0));
  }

  /// 松手：判定缩回就走"滑回"那条路（动画到 0 → 原生摘窗口），否则补满。
  void _onPanelCollapseRelease(bool close) => _settle(!close);

  /// 手指进度 → 面板滑出比例：露多少 = dx / 面板宽（夹 0..1，拖不滑出头）。
  double _progressFor(double dxLogical) {
    final width =
        panelWidthFor(_c.settings, MediaQuery.of(context).size.width);
    if (width <= 0) return 0;
    return (dxLogical / width).clamp(0.0, 1.0);
  }

  /// 松手：从当前进度补满（开）或滑回（关）。
  void _settle(bool open) {
    final start = _dragProgress ?? (open ? 1.0 : 0.0);
    _settleOpen = open;
    _settleCtrl.value = start.clamp(0.0, 1.0);
    _settleCtrl.duration = Duration(
        milliseconds: (60 + 140 * (1 - start).abs()).round().clamp(60, 220));
    _settleCtrl.animateTo(open ? 1.0 : 0.0, curve: Curves.easeOutCubic);
  }

  void _onSettleTick() {
    if (!mounted || !_settleCtrl.isAnimating) return;
    setState(() => _dragProgress = _settleCtrl.value);
  }

  void _onSettleStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    if (_settleOpen) {
      // 补满：交回 _expanded 驱动（原生已在松手时广播 expanded=true）。
      if (mounted) setState(() => _dragProgress = null);
    } else {
      // 滑回：动画到 0 之后才让原生摘窗口（把手回来）；期间保持 progress=0，
      // 否则面板会闪回全展开。
      _collapseFromDrag();
    }
  }

  /// 滑回屏外后收起：与点遮罩收起同一条路（原生摘窗口 + 广播状态）。
  Future<void> _collapseFromDrag() async {
    widget.controller.closeMainline();
    // 拖出去又拖回来的那一路：拖着的时候已经把编排立起来了，这里收回，
    // 免得下一次拉出来还挂着一块上次没看成的东西。
    widget.controller.closePlan();
    await widget.bridge.collapse();
    if (mounted) setState(() => _dragProgress = null);
  }

  void _maybeOnboard() {
    if (_c.settings.guideSeen) return;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || _c.settings.guideSeen) return;
      await showDialog<void>(
          context: context, builder: (_) => const PanelOnboardDialog());
      await _c.updateSettings(_c.settings.copyWith(guideSeen: true));
    });
  }

  @override
  Widget build(BuildContext context) {
    // 快记输入条阶段（§6.8）：只剩方块 → 输入条，面板被它替代。
    final quickOrigin = _quickOrigin;
    if (quickOrigin != null) {
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _closeQuickNote();
        },
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: QuickNoteLayer(
            origin: quickOrigin,
            onSubmit: _quickSubmit,
            onClose: _closeQuickNote,
          ),
        ),
      );
    }
    // 跟手拖动中（_dragProgress != null）也要渲染面板——那是"露多少跟多少"
    // 的部分展开态（§6.0）；快记态下面板淡出但**不摘窗口**（§6.8）。
    if (!_expanded && _dragProgress == null && !_quickDrag) {
      return const SizedBox.shrink();
    }
    // 透明 Scaffold：SnackBar / 对话框有宿主，背景仍是"下面的 App"。
    // PopScope：面板是全屏窗口，系统返回键应该"收起面板"而不是穿透到下面的 App。
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        // 覆盖页开着：返回键只收它，面板留在原地（§6.9 / §6.11 两步收）
        if (widget.controller.planOpen) {
          widget.controller.closePlan();
          return;
        }
        if (widget.controller.mainlineOpen) {
          widget.controller.closeMainline();
          return;
        }
        _collapse();
      },
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: IgnorePointer(
          ignoring: _quickDrag,
          child: AnimatedOpacity(
            opacity: _quickDrag ? 0 : 1,
            duration: const Duration(milliseconds: 160),
            child: FloatingPanel(
              controller: _c,
              pageCtrl: _pageCtrl,
              onCollapse: _collapse,
              onOpenCalendar: () => showCalendarDialog(context, _c),
              onOpenSettings: () => widget.bridge.openApp(target: 'settings'),
              dockLeft: !_dockedRight,
              anchorCenterY: _handleCenterY,
              // 跟手拖动中 = 部分展开；其余 = 全展开。
              progress: _dragProgress ?? 1,
              onCollapsePull: _onPanelCollapsePull,
              onCollapseRelease: _onPanelCollapseRelease,
            ),
          ),
        ),
      ),
    );
  }
}

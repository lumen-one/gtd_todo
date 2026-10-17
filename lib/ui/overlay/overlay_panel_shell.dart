import 'dart:async';

import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../dialogs/calendar_dialog.dart';
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
  final PageController _pageCtrl = PageController();
  StreamSubscription<OverlayWindowState>? _stateSub;
  StreamSubscription<OverlayDragEvent>? _dragSub;

  bool _expanded = true; // 原生 notifyReady 后会立刻纠正
  bool _dockedRight = true;
  bool _privacy = false;

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
    _c.addListener(_onChange);
    _settleCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 180))
      ..addListener(_onSettleTick)
      ..addStatusListener(_onSettleStatus);
    _stateSub = widget.bridge.states.listen((s) {
      if (!mounted) return;
      setState(() {
        _expanded = s.expanded;
        _dockedRight = s.dockedRight;
        _handleCenterY = s.handleCenterY;
        if (!s.expanded) _privacy = false;
      });
      if (s.expanded) _maybeOnboard();
    });
    _dragSub = widget.bridge.drags.listen(_onDrag);
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
    if (mounted) setState(() {});
  }

  Future<void> _collapse() async {
    setState(() {
      _expanded = false;
      _privacy = false;
    });
    await widget.bridge.collapse();
  }

  // ------------------------------------------------------- 跟手拉开（§6.0）

  /// 原生把手的跟手事件：progress = 手指进度；end = 松手判定（原生说了算）。
  void _onDrag(OverlayDragEvent e) {
    if (!mounted) return;
    if (e is PanelDragProgress) {
      setState(() => _dragProgress = _progressFor(e.dx));
    } else if (e is PanelDragEnd) {
      _settle(e.open);
    }
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

  Future<void> _privacySubmit(String text) async {
    final title = text.trim();
    if (title.isEmpty) return;
    await _c.createTask(title: title);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('已静默入池'),
        duration: Duration(seconds: 2),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    // 跟手拖动中（_dragProgress != null）也要渲染面板——那是"露多少跟多少"
    // 的部分展开态（§6.0）。
    if (!_expanded && _dragProgress == null) return const SizedBox.shrink();
    // 透明 Scaffold：SnackBar / 对话框有宿主，背景仍是"下面的 App"。
    // PopScope：面板是全屏窗口，系统返回键应该"收起面板"而不是穿透到下面的 App。
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _collapse();
      },
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: FloatingPanel(
          controller: _c,
          pageCtrl: _pageCtrl,
          onCollapse: _collapse,
          onPrivacy: () => setState(() => _privacy = true),
          privacy: _privacy,
          onPrivacySubmit: _privacySubmit,
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
    );
  }
}

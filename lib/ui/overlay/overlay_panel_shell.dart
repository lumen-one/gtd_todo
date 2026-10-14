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

class _OverlayPanelShellState extends State<OverlayPanelShell> {
  final PageController _pageCtrl = PageController();
  StreamSubscription<OverlayWindowState>? _stateSub;

  bool _expanded = true; // 原生 notifyReady 后会立刻纠正
  bool _dockedRight = true;
  bool _privacy = false;

  AppController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _c.addListener(_onChange);
    _stateSub = widget.bridge.states.listen((s) {
      if (!mounted) return;
      setState(() {
        _expanded = s.expanded;
        _dockedRight = s.dockedRight;
        if (!s.expanded) _privacy = false;
      });
      if (s.expanded) _maybeOnboard();
    });
  }

  @override
  void dispose() {
    _stateSub?.cancel();
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
    if (!_expanded) return const SizedBox.shrink();
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
        ),
      ),
    );
  }
}

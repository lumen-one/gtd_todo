import 'dart:async';

import 'package:flutter/services.dart';

import '../app_controller.dart';

/// 原生 ↔ 悬浮面板的事件/命令通道（窗口显隐、收起、进应用）。
class OverlayBridge {
  static const MethodChannel channel = MethodChannel('gtd/overlay');

  final StreamController<OverlayWindowState> _states =
      StreamController<OverlayWindowState>.broadcast();

  /// 原生侧的面板状态（展开/收起 + 把手停靠侧）。
  Stream<OverlayWindowState> get states => _states.stream;

  OverlayBridge() {
    channel.setMethodCallHandler((call) async {
      if (call.method == 'state' && call.arguments is Map) {
        final m = Map<String, Object?>.from(call.arguments as Map);
        _states.add(OverlayWindowState(
          expanded: m['expanded'] == true,
          dockedRight: m['dockedRight'] != false,
        ));
      }
      return null;
    });
  }

  /// 告知原生"面板侧已就绪"（之后原生才会投递状态）。
  Future<void> notifyReady() async {
    await _invoke('notifyReady');
  }

  /// 收起悬浮面板（窗口隐藏，把手重新出现）。
  Future<void> collapse() async {
    await _invoke('collapse');
  }

  /// **进应用**：打开应用本体（设置页），可选定位到某条周期规则。
  Future<void> openApp({String target = 'settings', String? routineId}) async {
    await _invoke('openApp', {'target': target, 'routineId': routineId});
  }

  Future<void> _invoke(String method, [Map<String, Object?>? args]) async {
    try {
      await channel.invokeMethod<Object?>(method, args);
    } catch (_) {
      // 原生不可用（桌面/老版本）：面板退化为"进应用"，不崩。
    }
  }
}

class OverlayWindowState {
  final bool expanded;
  final bool dockedRight;

  const OverlayWindowState({required this.expanded, required this.dockedRight});
}

/// 悬浮面板里点『编辑规则』时：把用户带进应用的设置页并定位该规则
/// （悬浮窗没有设置页，装配点在悬浮入口装配完成后接上这条线）。
void wireOverlaySettingsNavigation(
    AppController controller, OverlayBridge bridge) {
  controller.onOpenSettingsRequested = (routineId) async {
    await bridge.openApp(target: 'settings', routineId: routineId);
    await bridge.collapse();
  };
}

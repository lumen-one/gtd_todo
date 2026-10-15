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

  /// 原生把手"拉开"手势的跟手事件（ui-interaction.md §6.0）。
  final StreamController<OverlayDragEvent> _drags =
      StreamController<OverlayDragEvent>.broadcast();

  Stream<OverlayDragEvent> get drags => _drags.stream;

  OverlayBridge() {
    channel.setMethodCallHandler((call) async {
      if (call.method == 'state' && call.arguments is Map) {
        final m = Map<String, Object?>.from(call.arguments as Map);
        _states.add(OverlayWindowState(
          expanded: m['expanded'] == true,
          dockedRight: m['dockedRight'] != false,
          // 原生把手中心 Y（逻辑像素）：面板垂直居中于它；缺失 = 贴顶。
          handleCenterY: (m['handle_center_y'] as num?)?.toDouble(),
        ));
      }
      // 跟手拉开：dx = 手指距贴边位置的逻辑像素（朝屏内为正）。
      if (call.method == 'panelDrag' && call.arguments is Map) {
        final m = Map<String, Object?>.from(call.arguments as Map);
        _drags.add(PanelDragProgress((m['dx'] as num?)?.toDouble() ?? 0));
      }
      // 松手：open = 原生判定补满全开（否则滑回屏外后调 collapse）。
      if (call.method == 'panelDragEnd' && call.arguments is Map) {
        final m = Map<String, Object?>.from(call.arguments as Map);
        _drags.add(PanelDragEnd(m['open'] == true));
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

  /// 原生把手的中心 Y（逻辑像素）；null = 原生没广播（老版本 / 桌面），
  /// 面板贴顶展开（向后兼容）。
  final double? handleCenterY;

  const OverlayWindowState({
    required this.expanded,
    required this.dockedRight,
    this.handleCenterY,
  });
}

/// 把手"拉开"手势的跟手事件（§6.0）：[PanelDragProgress] 带手指进度，
/// [PanelDragEnd] 是松手时原生的展开/收回判定。
sealed class OverlayDragEvent {
  const OverlayDragEvent();
}

/// 拖动进行中：dx = 手指相对贴边位置的逻辑像素（朝屏内为正）。
class PanelDragProgress extends OverlayDragEvent {
  final double dx;

  const PanelDragProgress(this.dx);
}

/// 松手：open = 补满全展开（否则滑回屏外、面板收起）。
class PanelDragEnd extends OverlayDragEvent {
  final bool open;

  const PanelDragEnd(this.open);
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

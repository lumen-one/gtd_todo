import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../application/delivery.dart';
import '../domain/reminder.dart';
import '../domain/task.dart';

/// 安卓交付类适配器（§4.2/§4.3）：系统精确闹钟 + 系统通知（含快捷按钮与
/// 全屏闹钟）+ 权限引导 + 任务目录选择。
///
/// 原生侧（android/app/src/main/kotlin/com/example/gtd_todo/）：
/// - MethodChannel `gtd/native`：Dart 调原生（挂闹钟/弹通知/权限/悬浮把手）；
/// - MethodChannel `gtd/native/events`：原生回传（到点、通知按钮、点通知定位、
///   把手拖出）。应用被杀时原生接收器自己按"内容草案"弹通知；
///   事件先入队，Dart 启动后 `drainEvents` 取走。
///
/// 本文件不受 §2 import 矩阵约束（组装点装配），但不得被核心 import。
class AndroidNativeBridge {
  static const MethodChannel channel = MethodChannel('gtd/native');
  static const MethodChannel eventChannel = MethodChannel('gtd/native/events');

  final StreamController<Map<String, Object?>> _events =
      StreamController<Map<String, Object?>>.broadcast();

  /// 原生事件：{type: alarmFired|action|notificationTap|overlayHandleOpened, ...}
  Stream<Map<String, Object?>> get events => _events.stream;

  AndroidNativeBridge() {
    eventChannel.setMethodCallHandler((call) async {
      if (call.method == 'event' && call.arguments is Map) {
        _events.add(Map<String, Object?>.from(call.arguments as Map));
      }
      return null;
    });
  }

  /// 告诉原生"事件通道已就绪"，并把应用被杀期间入队的事件取回来回放。
  Future<void> markReady() async {
    await _invoke('notifyReady');
    await drain();
  }

  /// 取走原生侧入队的事件（冷启动/被杀期间的通知按钮等）。
  Future<void> drain() async {
    try {
      final raw = await channel.invokeListMethod<Object?>('drainEvents');
      for (final e in raw ?? const <Object?>[]) {
        if (e is Map) _events.add(Map<String, Object?>.from(e));
      }
    } catch (_) {
      // 原生侧不可用（老版本/桌面误装）：静默降级
    }
  }

  Future<bool> scheduleAlarm({
    required DateTime at,
    required String taskId,
    ReminderDraft? draft,
  }) =>
      _invoke('scheduleAlarm', {
        'atMillis': at.millisecondsSinceEpoch,
        'taskId': taskId,
        'title': draft?.title ?? '该做这件事了',
        'body': draft?.body,
        'alarmChannel': draft?.channel == ReminderChannel.alarm,
        'fullScreen': draft?.fullScreen ?? false,
        'actions': _actionsArg(draft?.actions ?? const []),
      });

  Future<bool> cancelAlarm() => _invoke('cancelAlarm');

  Future<bool> showNotification({
    required String taskId,
    required String title,
    String? body,
    bool alarmChannel = false,
    bool fullScreen = false,
    List<NotificationAction> actions = const [],
  }) =>
      _invoke('showNotification', {
        'taskId': taskId,
        'title': title,
        'body': body,
        'alarmChannel': alarmChannel,
        'fullScreen': fullScreen,
        'actions': _actionsArg(actions),
      });

  Future<bool> cancelNotification(String taskId) =>
      _invoke('cancelNotification', {'taskId': taskId});

  Future<bool> canUseFullScreenIntent() => _invoke('canUseFullScreenIntent');

  Future<bool> requestFullScreenIntentPermission() =>
      _invoke('requestFullScreenIntentPermission');

  Future<bool> hasOverlayPermission() => _invoke('hasOverlayPermission');

  Future<bool> requestOverlayPermission() =>
      _invoke('requestOverlayPermission');

  Future<bool> setOverlayHandle(bool enabled) =>
      _invoke('setOverlayHandle', {'enabled': enabled});

  /// 把手开关的真实状态（设置页据此初始化，而不是靠本地假设）。
  Future<bool> isOverlayHandleEnabled() => _invoke('isOverlayHandleEnabled');

  Future<bool> isIgnoringBatteryOptimizations() =>
      _invoke('isIgnoringBatteryOptimizations');

  Future<bool> _invoke(String method, [Map<String, Object?>? args]) async {
    try {
      final r = await channel.invokeMethod<Object?>(method, args);
      return r == true;
    } catch (_) {
      return false; // 原生不可用：调用方按 §11 降级
    }
  }

  static List<Map<String, String>> _actionsArg(
          List<NotificationAction> actions) =>
      [
        for (final a in actions) {'id': a.id, 'label': a.label}
      ];
}

/// 系统精确闹钟（AlarmManager + 原生接收器）。
class AndroidAlarmPort implements AlarmPort {
  final AndroidNativeBridge bridge;

  AndroidAlarmPort(this.bridge);

  @override
  Future<void> scheduleNext(DateTime at, String taskId,
      {ReminderDraft? draft}) async {
    await bridge.scheduleAlarm(at: at, taskId: taskId, draft: draft);
  }

  @override
  Future<void> cancel() async {
    await bridge.cancelAlarm();
  }

  @override
  Stream<String> get fired => bridge.events
      .where((e) => e['type'] == 'alarmFired')
      .map((e) => e['taskId'] as String? ?? '')
      .where((id) => id.isNotEmpty);
}

/// 系统通知（动作按钮 / 全屏闹钟 / 点通知定位）。
///
/// `shown` 为空流：系统通知不回流给本应用 UI（桌面的"托盘=窗口"语义在安卓
/// 不成立）；按钮与点击走 [AndroidNativeBridge.events] 回传。
class AndroidNotificationPort implements NotificationPort {
  final AndroidNativeBridge bridge;

  /// 通知正文数据来源（taskId → 任务）；null 时用通用文案。
  final Task? Function(String taskId)? lookup;

  AndroidNotificationPort(this.bridge, {this.lookup});

  @override
  Future<void> show(
    ReminderEvent event, {
    List<NotificationAction> actions = const [],
    ReminderChannel channel = ReminderChannel.normal,
    bool fullScreen = false,
    ReminderDraft? draft,
  }) async {
    final task = lookup?.call(event.taskId);
    await bridge.showNotification(
      taskId: event.taskId,
      title: draft?.title ?? task?.title ?? '该做这件事了',
      body: draft?.body ?? _bodyOf(task),
      alarmChannel: channel == ReminderChannel.alarm,
      fullScreen: fullScreen,
      actions: actions,
    );
  }

  @override
  Stream<ShownNotification> get shown => const Stream.empty();

  static String? _bodyOf(Task? task) {
    if (task == null) return null;
    final d = task.deadline;
    // '长期'任务没有剩余工时（D18），也不会走到提醒链路；?? 0 只是空值安全。
    final remaining = task.remainingWork ?? 0;
    if (task.type == TaskType.flex && remaining > 0) {
      return '剩余约 $remaining 分钟';
    }
    if (d != null) {
      return '到点 ${d.hour.toString().padLeft(2, '0')}:'
          '${d.minute.toString().padLeft(2, '0')}';
    }
    return null;
  }
}

/// 权限引导（permission_handler + 原生全屏 intent / 悬浮窗查询）。
/// 被拒一律返回 false，调用方按 ui-interaction.md §11 优雅降级。
class AndroidPermissionPort implements PermissionPort {
  final AndroidNativeBridge bridge;

  AndroidPermissionPort(this.bridge);

  @override
  Future<bool> ensure(PermissionKind kind) async {
    switch (kind) {
      case PermissionKind.notifications:
        return (await Permission.notification.request()).isGranted;
      case PermissionKind.exactAlarm:
        return (await Permission.scheduleExactAlarm.request()).isGranted;
      case PermissionKind.batteryExemption:
        return (await Permission.ignoreBatteryOptimizations.request())
            .isGranted;
      case PermissionKind.overlayWindow:
        return (await Permission.systemAlertWindow.request()).isGranted;
      case PermissionKind.showOnLockScreen:
        return bridge.requestFullScreenIntentPermission();
      case PermissionKind.folderAccess:
        return (await Permission.manageExternalStorage.request()).isGranted;
    }
  }

  @override
  Future<bool> granted(PermissionKind kind) async {
    switch (kind) {
      case PermissionKind.notifications:
        return Permission.notification.isGranted;
      case PermissionKind.exactAlarm:
        return Permission.scheduleExactAlarm.isGranted;
      case PermissionKind.batteryExemption:
        return Permission.ignoreBatteryOptimizations.isGranted;
      case PermissionKind.overlayWindow:
        return Permission.systemAlertWindow.isGranted;
      case PermissionKind.showOnLockScreen:
        return bridge.canUseFullScreenIntent();
      case PermissionKind.folderAccess:
        return Permission.manageExternalStorage.isGranted;
    }
  }
}

/// 任务目录选择（决议：所有文件访问 + 系统目录选择器）。
/// 未授予"所有文件访问"时先申请；选择器取消 → null（UI 保持原目录）。
class AndroidFolderPickerPort implements FolderPickerPort {
  final AndroidPermissionPort permissions;

  AndroidFolderPickerPort(this.permissions);

  @override
  Future<String?> pickDirectory() async {
    if (!await permissions.granted(PermissionKind.folderAccess)) {
      final ok = await permissions.ensure(PermissionKind.folderAccess);
      if (!ok) return null;
    }
    try {
      return await FilePicker.platform.getDirectoryPath(
        dialogTitle: '选择任务目录（Obsidian 可直接打开）',
      );
    } catch (_) {
      return null;
    }
  }

  /// 疑问笔记文件（ui §6.2）：同样是"所有文件访问"打底——没它 SAF 只给一个
  /// 缓存副本的路径，改天 Obsidian 里更新了笔记，App 读的还是那份旧快照。
  @override
  Future<String?> pickFile({
    required String dialogTitle,
    required List<String> allowedExtensions,
  }) async {
    if (!await permissions.granted(PermissionKind.folderAccess)) {
      final ok = await permissions.ensure(PermissionKind.folderAccess);
      if (!ok) return null;
    }
    try {
      final result = await FilePicker.platform.pickFiles(
        dialogTitle: dialogTitle,
        type: allowedExtensions.isEmpty ? FileType.any : FileType.custom,
        allowedExtensions: allowedExtensions.isEmpty ? null : allowedExtensions,
        allowMultiple: false,
        withData: false,
      );
      final files = result?.files;
      if (files == null || files.isEmpty) return null;
      return files.first.path;
    } catch (_) {
      return null;
    }
  }
}

import 'dart:async';

import '../application/delivery.dart';
import '../domain/reminder.dart';

/// 桌面适配器（§4.2）：桌面应用前台运行，Timer 就是系统闹钟的等价物；
/// 移动端将换成系统精确闹钟 / flutter_local_notifications 适配器。
/// 本文件不受 architecture.md §2 矩阵约束（组装点装配），但不得被核心 import。

/// 前台 Timer 闹钟：预约全局唯一闹钟，到点往 [fired] 发 taskId。
/// 应用未运行时提醒不触发——桌面用"开机自启 + 常驻"弥补（规划），移动端无此问题。
class TimerAlarmPort implements AlarmPort {
  Timer? _timer;
  final _fired = StreamController<String>.broadcast();

  @override
  Future<void> scheduleNext(DateTime at, String taskId,
      {ReminderDraft? draft}) async {
    await cancel();
    final delay = at.difference(DateTime.now());
    _timer = Timer(
      delay.isNegative ? Duration.zero : delay,
      () => _fired.add(taskId),
    );
  }

  @override
  Future<void> cancel() async {
    _timer?.cancel();
    _timer = null;
  }

  @override
  Stream<String> get fired => _fired.stream;
}

/// 应用内通知回流：show 的内容进 [shown]，UI 监听并渲染弹窗。
class StreamNotificationPort implements NotificationPort {
  final _shown = StreamController<ShownNotification>.broadcast();

  @override
  Future<void> show(
    ReminderEvent event, {
    List<NotificationAction> actions = const [],
    ReminderChannel channel = ReminderChannel.normal,
    bool fullScreen = false,
    ReminderDraft? draft,
  }) async {
    _shown.add(ShownNotification(
      event: event,
      actions: actions,
      channel: channel,
      fullScreen: fullScreen,
    ));
  }

  @override
  Stream<ShownNotification> get shown => _shown.stream;
}

/// 桌面端权限默认视为已授予（通知/闹钟能力随应用本身存在）。
class GrantedPermissionPort implements PermissionPort {
  @override
  Future<bool> ensure(PermissionKind kind) async => true;

  @override
  Future<bool> granted(PermissionKind kind) async => true;
}

/// 桌面 v1 不做目录选择 UI（任务目录用环境变量 / 设置文件，规划）。
class UnavailableFolderPickerPort implements FolderPickerPort {
  @override
  Future<String?> pickDirectory() async => null;
}

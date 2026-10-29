import 'dart:async';

import 'package:file_picker/file_picker.dart';

import '../application/delivery.dart';
import '../domain/reminder.dart';

/// 桌面适配器（§4.2）：桌面应用前台运行，Timer 就是系统闹钟的等价物；
/// 移动端将换成系统精确闹钟 / flutter_local_notifications 适配器。
/// 本文件不受 architecture.md §2 矩阵约束（组装点装配），但不得被核心 import。

/// 前台 Timer 闹钟：预约全局唯一闹钟，到点往 [fired] 发 taskId。
/// 应用未运行时提醒不触发——桌面用"开机自启 + 常驻"弥补（规划），移动端无此问题。
///
/// 桌面没有"原生先自己弹一遍"这一层，投递只能由分发器做，所以事件一律
/// `delivered: false`。
class TimerAlarmPort implements AlarmPort {
  Timer? _timer;
  final _fired = StreamController<FiredAlarm>.broadcast();

  @override
  Future<void> scheduleNext(DateTime at, String taskId,
      {ReminderDraft? draft}) async {
    await cancel();
    final delay = at.difference(DateTime.now());
    _timer = Timer(
      delay.isNegative ? Duration.zero : delay,
      () => _fired.add(FiredAlarm(taskId)),
    );
  }

  @override
  Future<void> cancel() async {
    _timer?.cancel();
    _timer = null;
  }

  @override
  Stream<FiredAlarm> get fired => _fired.stream;
}

/// 应用内通知回流：show 的内容进 [shown]，UI 监听并渲染弹窗。
class StreamNotificationPort implements NotificationPort {
  final _shown = StreamController<ShownNotification>.broadcast();

  @override
  Future<void> show(
    ReminderEvent event, {
    List<NotificationAction> actions = const [],
    ReminderChannel channel = ReminderChannel.ring,
    bool fullScreen = false,
    ReminderDraft? draft,
  }) async {
    _shown.add(ShownNotification(
      event: event,
      actions: actions,
      channel: channel,
      fullScreen: fullScreen,
      draft: draft,
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

/// 桌面选择器（ui §6.2 / §9）：**文件可挑，目录仍不挑**——任务目录在桌面走
/// 环境变量 `GTD_TASKS_DIR` / 引导配置（v1 不做目录选择 UI，沿用原口径）。
/// 灵感要挑的是 vault 里的某一个 Markdown，手输路径太容易输错，给选择器。
class DesktopFolderPickerPort implements FolderPickerPort {
  @override
  Future<String?> pickDirectory() async => null;

  @override
  Future<String?> pickFile({
    required String dialogTitle,
    required List<String> allowedExtensions,
  }) async {
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

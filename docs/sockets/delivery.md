# 交付类插座

"到点把提醒送到用户眼前"这一侧的全部插座：通知、闹钟、权限、目录选择，以及桌面与
安卓两套适配器。末尾是系统级悬浮面板（第二个 Flutter 引擎）的层职责与引擎边界。

> 本节从 [架构文档](../architecture.md) §4.2 整节搬出，口径未改；那一节现在只留索引。

## 接口

```dart
enum ReminderChannel { normal, alarm }   // alarm = 闹钟渠道：全屏 + 持续响铃
enum PermissionKind {
  notifications, exactAlarm, batteryExemption,
  overlayWindow,        // 悬浮侧边栏（SYSTEM_ALERT_WINDOW）
  showOnLockScreen,     // 全屏提醒（锁屏/上层显示）
  folderAccess,         // 任务目录（所有文件访问 或 SAF）
}

class NotificationAction { final String id; final String label; }  // 如 done / snooze1h

/// 交付内容草案：挂闹钟时就把"到点交付什么"定下来。
/// 桌面不需要（到点由应用自己 show）；安卓需要——系统闹钟到点时应用可能已被杀，
/// 原生接收器只能照这份草案自己弹通知。
class ReminderDraft {
  final String taskId; final String title; final String? body;
  final ReminderChannel channel; final bool fullScreen;
  final List<NotificationAction> actions;
}

abstract class NotificationPort {
  Future<void> show(ReminderEvent event, {
    List<NotificationAction> actions = const [],
    ReminderChannel channel = ReminderChannel.normal,
    bool fullScreen = false,        // full-screen intent（闹钟模式）
    ReminderDraft? draft,           // 系统通知实现用它渲染文案
  });
  /// 桌面的"托盘"就是应用窗口：适配器把 show 回流给 UI 渲染弹窗；
  /// 系统通知实现返回空流（安卓的按钮/点击走原生事件回传，见 4.3）。
  Stream<ShownNotification> get shown;
}

abstract class AlarmPort {
  /// 全局唯一闹钟。[draft] 供"应用被杀时也能自己弹通知"的实现使用。
  Future<void> scheduleNext(DateTime at, String taskId, {ReminderDraft? draft});
  Future<void> cancel();
  Stream<String> get fired;    // 到点（安卓=系统闹钟回调；桌面=Timer）
}

abstract class FolderPickerPort {
  Future<String?> pickDirectory();
  Future<String?> pickFile({required String dialogTitle,
      required List<String> allowedExtensions});  // 灵感文件路径（[灵感页](../panels/notes.md)）
}  // SAF / 桌面选择器

abstract class PermissionPort {
  Future<bool> ensure(PermissionKind kind);   // 申请（必要时弹系统界面）
  Future<bool> granted(PermissionKind kind);  // 只查询（设置页展示，不弹界面）
}
```

桌面适配器（`lib/platform/desktop_adapters.dart`【现状】）：`TimerAlarmPort`（前台 Timer，
系统闹钟在桌面的等价物）、`StreamNotificationPort`（应用内弹窗回流）、
`GrantedPermissionPort`、`DesktopFolderPickerPort`（**文件可挑，目录仍不挑**——
桌面任务目录走环境变量 `GTD_TASKS_DIR` / 引导配置，不做目录选择 UI）。

安卓适配器（`lib/platform/android_adapters.dart` + `android/…/gtd/` 原生侧【现状】）：
`AndroidAlarmPort` / `AndroidNotificationPort`（系统精确闹钟 AlarmManager + 通知渠道
`gtd_normal`/`gtd_alarm`/`gtd_overlay` + 通知按钮 + full-screen intent）、
`AndroidPermissionPort`（permission_handler + 原生全屏 intent/悬浮窗查询）、
`AndroidFolderPickerPort`（所有文件访问 + 系统目录选择器 / 文件选择器）；
原生侧另有 `OverlayHandleService`（贴屏把手，前台服务 + WindowManager）。
`platform/` 不受 [architecture.md](../architecture.md) §2 矩阵约束（组装点装配），但不得被 domain/scheduler/application import。

**系统级悬浮面板（第二个 Flutter 引擎）**：[architecture.md](../architecture.md) §0 的产品定位是"日常操作发生在
悬浮侧边栏里，App 主体几乎不开"，所以把手拖出必须**在当前 App 上方就地展开面板**，
而不是跳进应用。实现：

| 层                | 位置                                                    | 职责                                                                                                     |
| ----------------- | ------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| 原生命令/事件通道 | `gtd/overlay`（MethodChannel）                          | 上行：`notifyReady` / `collapse` / `expand` / `openApp{target,routineId}` / `panelWidth{dp}`；下行：`state{expanded,dockedRight,handleCenterY}` / `panelDrag{dx}` / `panelDragEnd{open}` / `quickNoteStart` / `quickNoteCancel` / `quickNoteOpen{x,y}` |
| 第二个引擎入口    | `lib/overlay_main.dart`（DartEntrypoint `overlayMain`） | 只剩入口与装配：装配**同一套** domain/application（自己的实例）；通道桥与面板宿主壳 `OverlayBridge` / `OverlayPanelShell` 在 `lib/ui/overlay/`                        |
| 面板本体          | `lib/ui/panels/side_panel.dart`                         | `SidePanel` / `PanelActions` / `PanelPrivacyBar` / `QuickNoteLayer`（拖出头快记）/ `PanelOnboardDialog`：**应用内壳与悬浮窗共用同一份**（快记只在悬浮窗用） |
| 窗口              | 原生 `OverlayHandleService`                             | 全屏**透明** `TYPE_APPLICATION_OVERLAY` 窗口承载引擎的 FlutterView；展开时隐藏原生把手                   |

> `handleCenterY`（逻辑像素）= 原生把手的中心 Y：面板垂直居中于它（ui-interaction.md
> [把手与面板](../panels/handle.md)）；字段缺失（老版本原生 / 桌面）时 Dart 侧贴顶展开，向后兼容。

边界（写死，避免两个引擎打架）：

1. **交付类插座与观察类订阅者只在主引擎装配**：全局单闹钟归主引擎那一份，悬浮引擎
   不起 ReminderDispatcher（两个引擎各自挂闹钟会互相覆盖）；`EventLog`（操作流水）
   同理只在主引擎挂，否则同一件事会被记两遍；
2. **写路径仍然唯一**：悬浮面板的命令同样走它自己的 `TaskService`（C1 不变），
   两个引擎之间的状态同步走**文件**——两边都 `watch()` 任务目录（与"Obsidian 手改
   回流"同一条通路），并发写由字段归属合并兜底；
3. **进应用的唯一入口**是面板头部的『设置』与实例菜单的『编辑规则』
   （`openApp{target,routineId}`），其余交互全部就地完成。

**单闹钟职责归属（条款有主语）**：全局任一时刻只挂一个下一站闹钟。调用方 =
application 层的 **ReminderDispatcher**（见 [reminder.md](reminder.md)）。装配点负责把 AlarmPort 注入。
**适配器无自主权**：只执行"取消旧的、挂新的"，不得自行重排或补挂。

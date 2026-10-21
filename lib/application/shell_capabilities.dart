/// 壳能力表（ui-interaction.md §9 开头 / architecture.md §5.1）。
///
/// 设置页里有一组项**只对某种壳有意义**：贴屏悬浮壳才有把手、才有可拖尺寸的
/// 面板、才要申请权限、才有全屏闹钟渠道；桌面窗口常驻，这些"东西"根本不存在。
/// 判据是"这套壳有没有那个东西"，**不是"什么系统"**——所以它是一张由组装点
/// （`main.dart`）注入的能力表，UI 只读表、不问平台（§5.3 的口诀：
/// UI 里只出现接口名，不出现平台名）。
///
/// 桌面上被裁掉的是**整行**而不是灰掉：灰掉会让人以为"再找找就找到了"，
/// 而桌面上它根本没有对应物（§9）。
class ShellCapabilities {
  /// 系统级贴屏把手（`SYSTEM_ALERT_WINDOW` + 前台服务那套）。
  final bool systemHandle;

  /// 把手的参数：位置上锁、热区宽度。没有把手时这两项无从谈起。
  final bool handleTuning;

  /// 可拖尺寸的面板（宽/高把手、尺寸固定 + 跟手收起）。桌面两栏是窗口决定的。
  final bool resizablePanel;

  /// 首次拖出引导（跟着把手一起走：桌面没有"拖出"这个动作）。
  final bool panelGuide;

  /// 权限引导（悬浮窗 / 通知 / 精确闹钟 / 电池白名单 / 锁屏 / 文件访问）。
  final bool permissionPrompts;

  /// 全屏闹钟渠道（通知升级为全屏持续响铃）。
  final bool alarmChannel;

  const ShellCapabilities({
    required this.systemHandle,
    required this.handleTuning,
    required this.resizablePanel,
    required this.panelGuide,
    required this.permissionPrompts,
    required this.alarmChannel,
  });

  /// 贴屏悬浮壳（安卓应用内壳 / 系统级悬浮面板）：六样齐全。
  static const overlayShell = ShellCapabilities(
    systemHandle: true,
    handleTuning: true,
    resizablePanel: true,
    panelGuide: true,
    permissionPrompts: true,
    alarmChannel: true,
  );

  /// 普通窗口壳（Windows 桌面）：六样都没有——设置页只留通用项。
  static const plainWindow = ShellCapabilities(
    systemHandle: false,
    handleTuning: false,
    resizablePanel: false,
    panelGuide: false,
    permissionPrompts: false,
    alarmChannel: false,
  );
}

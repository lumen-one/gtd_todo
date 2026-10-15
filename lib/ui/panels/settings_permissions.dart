import 'package:flutter/material.dart';

import '../../application/delivery.dart';
import '../app_controller.dart';
import '../theme.dart';

/// 设置页「权限引导」区：逐项申请并解释用途；被拒时对应功能优雅降级（§11）。
/// 桌面端全部视为已授予。
class SettingsPermissionsSection extends StatefulWidget {
  final AppController controller;

  const SettingsPermissionsSection({super.key, required this.controller});

  @override
  State<SettingsPermissionsSection> createState() =>
      _SettingsPermissionsSectionState();
}

class _SettingsPermissionsSectionState
    extends State<SettingsPermissionsSection> with WidgetsBindingObserver {
  /// 每项只留一句「给谁用」；降级结果在申请失败时由 toast 说明，不预写在行里。
  static const List<(PermissionKind, IconData, String, String)> _permissions = [
    (
      PermissionKind.notifications,
      Icons.notifications_active_outlined,
      '通知',
      '到点提醒要能弹出来'
    ),
    (
      PermissionKind.exactAlarm,
      Icons.alarm,
      '精确闹钟',
      '安卓 12+ 准点响铃要单独授权'
    ),
    (
      PermissionKind.batteryExemption,
      Icons.battery_saver,
      '电池优化',
      '免得省电模式推迟或吞掉闹钟'
    ),
    (
      PermissionKind.overlayWindow,
      Icons.picture_in_picture_alt_outlined,
      '悬浮窗',
      '在其他 App 上方展开侧边栏'
    ),
    (
      PermissionKind.showOnLockScreen,
      Icons.screen_lock_portrait_outlined,
      '锁屏显示',
      '闹钟的全屏提醒需要它'
    ),
    (
      PermissionKind.folderAccess,
      Icons.folder_open,
      '任务目录',
      '与 Obsidian 共用同一个 vault'
    ),
  ];

  final Map<PermissionKind, bool> _permState = {};
  bool _permLoading = false;

  AppController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadPermissions();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 系统权限设置页是异步的（用户可能在设置页里改完再回来）：
  /// 回到前台重新查询一遍状态（原生侧 `request*Permission` 只返回"调用那一刻"）。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _loadPermissions();
  }

  Future<void> _loadPermissions() async {
    if (_permLoading) return;
    setState(() => _permLoading = true);
    final port = _c.permissions;
    if (port != null) {
      for (final entry in _permissions) {
        try {
          _permState[entry.$1] = await port.granted(entry.$1);
        } catch (_) {
          _permState[entry.$1] = false;
        }
      }
    }
    if (mounted) setState(() => _permLoading = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        for (final (kind, icon, title, why) in _permissions)
          ListTile(
            leading: Icon(icon),
            title: Text(title),
            subtitle: Text(why, style: theme.textTheme.bodySmall),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _permState[kind] == true
                      ? Icons.check_circle
                      : Icons.error_outline,
                  size: 18,
                  color: _permState[kind] == true
                      ? Colors.green
                      : AppColors.overdueFor(theme.brightness),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () async {
                    final ok = await _c.ensurePermission(kind);
                    await _loadPermissions();
                    if (context.mounted && !ok) {
                      ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('$title 未授予：功能已降级')));
                    }
                  },
                  child: Text(_permState[kind] == true ? '已授予' : '申请'),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

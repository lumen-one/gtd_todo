import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../panels/settings_panel.dart';
import '../panels/task_list_panel.dart';

/// 桌面壳（§5.1 shells）：窗口级 chrome（标题栏动作、FAB）。
/// 安卓壳（悬浮侧边栏 + 抽屉兜底）复用同一套 panels；设置页（周期任务/主题/
/// 权限）在桌面上以独立页面打开。
class DesktopShell extends StatefulWidget {
  final AppController controller;

  const DesktopShell({super.key, required this.controller});

  @override
  State<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends State<DesktopShell> {
  final GlobalKey<TaskListPanelState> _panelKey =
      GlobalKey<TaskListPanelState>();

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return Scaffold(
      appBar: AppBar(
        title: const Text('动态任务调度 Todo'),
        actions: [
          IconButton(
            tooltip: '设置（周期任务 / 主题 / 提醒）',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => Scaffold(
                appBar: AppBar(title: const Text('设置')),
                body: SettingsPanel(controller: controller),
              ),
            )),
          ),
          IconButton(
            tooltip: '工作时间规则',
            icon: const Icon(Icons.schedule),
            onPressed: () => _panelKey.currentState?.openWorkRuleDialog(),
          ),
          IconButton(
            tooltip: '重新调度',
            icon: const Icon(Icons.refresh),
            onPressed: () => controller.refresh(),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _panelKey.currentState?.openCreateDialog(),
        child: const Icon(Icons.add),
      ),
      body: TaskListPanel(key: _panelKey, controller: controller),
    );
  }
}

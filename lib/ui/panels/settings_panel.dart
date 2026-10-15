import 'package:flutter/material.dart';

import '../../application/settings.dart';
import '../../domain/schedule.dart';
import '../app_controller.dart';
import '../dialogs/settings_notes_path_dialog.dart';
import '../dialogs/settings_windows_dialog.dart';
import '../theme.dart';
import 'settings_permissions.dart';
import 'settings_routines.dart';

String _mm(int minuteOfDay) {
  final h = (minuteOfDay ~/ 60).toString().padLeft(2, '0');
  final m = (minuteOfDay % 60).toString().padLeft(2, '0');
  return '$h:$m';
}

/// 三档调度模式的说明（决议 43）：完整 → 标准 → 无排序，**逐级弱化**算法替人做主
/// 的程度，所以它们是一组三选一，不是两个互不相干的开关。
String _modeHint(ScheduleMode mode) => switch (mode) {
      ScheduleMode.full => '完整：算法排先后，凡算法判定该响的都响',
      ScheduleMode.standard =>
        '标准（默认）：算法排先后，但默认不出声——'
            '要响的那一件在编辑表单里开『提醒我』',
      ScheduleMode.manual =>
        '无排序：标准的再弱化版——今日清单不再按算法排先后，顺序全靠手动拖；'
            '今天该看哪几件仍由算法挑（锚点落在今天 / 今天到期），清单不会因此变长',
    };

/// 三选一按钮（选中=实心，其余=描边）：比 SegmentedButton 放得下三个字以上的标签，
/// 也不会在窄面板里被挤成省略号。
Widget _modeButton(AppController c, AppSettings s, ScheduleMode mode) {
  final label = switch (mode) {
    ScheduleMode.full => '完整',
    ScheduleMode.standard => '标准',
    ScheduleMode.manual => '无排序',
  };
  final selected = s.scheduleMode == mode;
  final onPressed = () => c.updateSettings(s.copyWith(scheduleMode: mode));
  return Padding(
    padding: const EdgeInsets.symmetric(horizontal: 4),
    child: selected
        ? FilledButton(onPressed: onPressed, child: Text(label))
        : OutlinedButton(onPressed: onPressed, child: Text(label)),
  );
}

/// 设置页（ui-interaction.md §9，暂定 App 唯一主体页面）：
/// 1. 权限引导 + 任务目录 + 悬浮把手；2. 周期任务管理（routines.md）；
/// 3. 提醒与排序（**调度模式三档：完整/标准/无排序** + 时间段多段式 + 闹钟模式）；
/// 4. 定期挑；5. 疑问笔记路径；6. 周期任务在任务池的显示开关；
/// 7. 主题（**明暗三选一：跟随系统/浅色/深黑** + 强调色预设）；8. 回收站。
class SettingsPanel extends StatefulWidget {
  final AppController controller;

  const SettingsPanel({super.key, required this.controller});

  @override
  State<SettingsPanel> createState() => _SettingsPanelState();
}

class _SettingsPanelState extends State<SettingsPanel> {
  AppController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _c.addListener(_onChange);
    _c.refreshTrash();
  }

  @override
  void dispose() {
    _c.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (!mounted) return;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = _c.settings;

    return ListView(
      padding: const EdgeInsets.fromLTRB(0, 4, 0, 40),
      children: [
        _Section('权限引导'),
        SettingsPermissionsSection(controller: _c),

        _Section('任务目录与入口'),
        ..._taskDirSection(s),

        _Section('提醒与排序'),
        ..._reminderSection(theme, s),

        _Section('周期任务（routines.md）'),
        SettingsRoutinesSection(controller: _c),
        SwitchListTile(
          secondary: const Icon(Icons.view_list_outlined),
          title: const Text('在任务池计划段显示'),
          subtitle: const Text('决议 27：周期任务按"下一次发生日期"升序插入计划段'),
          value: s.routineShowInPool,
          onChanged: (v) => _c.updateSettings(s.copyWith(routineShowInPool: v)),
        ),

        _Section('定期挑'),
        ..._pickSection(s),

        _Section('疑问笔记'),
        _notesSection(s),

        _Section('主题'),
        ..._themeSection(theme, s),

        _Section('回收站'),
        _trashSection(),
      ],
    );
  }

  // ---------- 分区构建 ----------

  List<Widget> _taskDirSection(AppSettings s) => [
        ListTile(
          leading: const Icon(Icons.folder),
          title: const Text('任务目录'),
          subtitle: Text(_c.taskDir),
          trailing: const Icon(Icons.edit_outlined),
          onTap: () => _editTaskDir(context),
        ),
        SwitchListTile(
          secondary: const Icon(Icons.view_sidebar_outlined),
          title: const Text('系统级贴屏把手'),
          subtitle: const Text('在其他 App 上方就地展开侧边栏面板（不跳进应用）；'
              '应用在前台时自动收起、改用应用内把手。需悬浮窗权限，'
              '被拒时退化为 App 内抽屉'),
          value: _c.overlayHandleEnabled,
          onChanged: (v) async {
            final ok = await _c.setOverlayHandle(v);
            if (!context.mounted) return;
            if (v && !ok) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                  content: Text('悬浮窗权限被拒：已退化为 App 内抽屉')));
            }
          },
        ),
        ListTile(
          leading: const Icon(Icons.info_outline),
          title: const Text('重看首次引导'),
          onTap: () => _c.updateSettings(s.copyWith(guideSeen: false)),
        ),
      ];

  List<Widget> _reminderSection(ThemeData theme, AppSettings s) => [
        ListTile(
          leading: const Icon(Icons.tune_outlined),
          title: const Text('调度模式'),
          subtitle: Text(_modeHint(s.scheduleMode)),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
          child: Row(
            children: [
              // 三档由强到弱：算法介入程度依次递减，一次只能选一个。
              for (final mode in ScheduleMode.values)
                Expanded(child: _modeButton(_c, s, mode)),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Text(
            '三档只改"谁排前面"与"出不出声"：今天该做哪几件、多久催一次、'
            '逾期与"做不到"的提示都一样。',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
        SwitchListTile(
          secondary: const Icon(Icons.alarm),
          title: const Text('闹钟模式'),
          subtitle: const Text('时点性提醒升级为全屏 + 持续响铃（决议 18：'
              '不可推到点 + 设了响的周期任务；Slack 软提醒永远普通通知）'),
          value: s.alarmMode,
          onChanged: (v) => _c.updateSettings(s.copyWith(alarmMode: v)),
        ),
        ListTile(
          leading: const Icon(Icons.timelapse),
          title: const Text('通知时间段（可推任务）'),
          subtitle: Text(s.notificationWindows.isEmpty
              ? '不限制（全天送达）'
              : s.notificationWindows
                  .map((w) => '${_mm(w[0])}–${_mm(w[1])}')
                  .join('、')),
          trailing: const Icon(Icons.edit_outlined),
          onTap: () => showSettingsWindowsDialog(context, _c),
        ),
      ];

  List<Widget> _pickSection(AppSettings s) => [
        SwitchListTile(
          secondary: const Icon(Icons.shuffle),
          title: const Text('每天从散件段挑一件'),
          subtitle: const Text('附到今日清单尾部，不响提醒；手动挑过的日子自动让位'),
          value: s.pickEnabled,
          onChanged: (v) => _c.updateSettings(s.copyWith(pickEnabled: v)),
        ),
        if (s.pickEnabled)
          ListTile(
            leading: const Icon(Icons.update),
            title: const Text('间隔'),
            trailing: SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 1, label: Text('1 天')),
                ButtonSegment(value: 3, label: Text('3 天')),
                ButtonSegment(value: 7, label: Text('7 天')),
              ],
              selected: {s.pickIntervalDays},
              onSelectionChanged: (v) =>
                  _c.updateSettings(s.copyWith(pickIntervalDays: v.first)),
            ),
          ),
      ];

  Widget _notesSection(AppSettings s) => ListTile(
        leading: const Icon(Icons.menu_book_outlined),
        title: const Text('笔记文件路径'),
        subtitle: Text(s.notesPath ?? '未配置'),
        trailing: const Icon(Icons.edit_outlined),
        onTap: () => showSettingsNotesPathDialog(context, _c),
      );

  List<Widget> _themeSection(ThemeData theme, AppSettings s) => [
        // 明暗三选一（§8）：与强调色预设正交——预设换种子，明暗换中性底。
        // 默认跟随系统；切换立即生效（两个引擎都读同一份 settings.json）。
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: SegmentedButton<AppThemeMode>(
            segments: const [
              ButtonSegment(
                  value: AppThemeMode.system, label: Text('跟随系统')),
              ButtonSegment(value: AppThemeMode.light, label: Text('浅色')),
              ButtonSegment(value: AppThemeMode.dark, label: Text('深黑')),
            ],
            selected: {AppThemeMode.fromId(s.themeMode)},
            onSelectionChanged: (v) =>
                _c.updateSettings(s.copyWith(themeMode: v.first.id)),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(
            spacing: 8,
            children: [
              for (final preset in AppThemePreset.values)
                ChoiceChip(
                  avatar: CircleAvatar(backgroundColor: preset.seed, radius: 8),
                  label: Text(preset.label),
                  selected: s.themePreset == preset.id,
                  onSelected: (_) =>
                      _c.updateSettings(s.copyWith(themePreset: preset.id)),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
          child: Text('明暗换中性底（深黑 = 暖深褐黑）、预设换强调色；'
              '逾期橙红等状态语义色不随预设变（暗色下自动提亮，§8）',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ),
      ];

  Widget _trashSection() => ListTile(
        leading: const Icon(Icons.delete_sweep_outlined),
        title: Text('清空回收（${_c.trashTasks.length} 件）'),
        subtitle: const Text('删除的任务先进 .gtd/.trash/，tasks.md 那一行会被注释掉（可捞）'),
        onTap: _c.trashTasks.isEmpty ? null : () => _purgeTrash(context),
      );

  // ---------- 对话框 ----------

  Future<void> _editTaskDir(BuildContext context) async {
    final ctrl = TextEditingController(text: _c.taskDir);
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('任务目录', style: Theme.of(ctx).textTheme.titleSmall),
              const SizedBox(height: 4),
              Text('选择 Obsidian vault 里的目录；改动需要重启应用生效。',
                  style: Theme.of(ctx).textTheme.bodySmall),
              const SizedBox(height: 10),
              TextField(
                controller: ctrl,
                decoration: const InputDecoration(labelText: '目录路径'),
              ),
              const SizedBox(height: 10),
              FilledButton.icon(
                icon: const Icon(Icons.folder_open),
                label: const Text('用系统选择器挑一个目录'),
                onPressed: () async {
                  final picked = await _c.pickTaskDir();
                  if (!ctx.mounted) return;
                  if (picked == null) {
                    ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(
                        content: Text('未选择目录（或缺少"所有文件访问"权限）')));
                    return;
                  }
                  ctrl.text = picked;
                },
              ),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: () async {
                  final dir = ctrl.text.trim();
                  Navigator.of(ctx).pop();
                  if (dir.isEmpty || dir == _c.taskDir) return;
                  await _c.setTaskDir(dir);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        content: Text('已保存，重启应用后生效')));
                  }
                },
                child: const Text('保存'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _purgeTrash(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空回收站？'),
        content: const Text('将真正删除回收站里的文件，不可恢复。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('清空')),
        ],
      ),
    );
    if (ok == true) {
      await _c.purgeTrash();
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('回收站已清空')));
      }
    }
  }
}

class _Section extends StatelessWidget {
  final String title;

  const _Section(this.title);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 4),
        child: Text(title,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: AppColors.accent, fontWeight: FontWeight.w700)),
      );
}

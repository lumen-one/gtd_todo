import 'package:flutter/material.dart';

import '../../application/delivery.dart';
import '../../domain/routine.dart';
import '../../domain/schedule.dart';
import '../app_controller.dart';
import '../dialogs/routine_edit_dialog.dart';
import '../theme.dart';

String _mm(int minuteOfDay) {
  final h = (minuteOfDay ~/ 60).toString().padLeft(2, '0');
  final m = (minuteOfDay % 60).toString().padLeft(2, '0');
  return '$h:$m';
}

/// 设置页（ui-interaction.md §9，暂定 App 唯一主体页面）：
/// 1. 权限引导 + 任务目录 + 悬浮把手；2. 周期任务管理（routines.md）；
/// 3. 提醒（**模式：标准/完整** / 时间段多段式 / 闹钟模式）；4. 定期挑；5. 疑问笔记路径；
/// 6. 周期任务在任务池的显示开关；7. 主题预设；8. 回收站；
/// 9. **排序模式（自动 / 无排序，决议 43）**。
class SettingsPanel extends StatefulWidget {
  final AppController controller;

  const SettingsPanel({super.key, required this.controller});

  @override
  State<SettingsPanel> createState() => _SettingsPanelState();
}

class _SettingsPanelState extends State<SettingsPanel>
    with WidgetsBindingObserver {
  static const List<(PermissionKind, IconData, String, String)> _permissions = [
    (
      PermissionKind.notifications,
      Icons.notifications_active_outlined,
      '通知',
      '到点提醒要能弹出来；被拒则只在应用内高亮（§11）'
    ),
    (
      PermissionKind.exactAlarm,
      Icons.alarm,
      '精确闹钟',
      '安卓 12+ 准点响铃要单独授权；被拒提醒可能迟到（如实提示）'
    ),
    (
      PermissionKind.batteryExemption,
      Icons.battery_saver,
      '电池优化白名单',
      'Doze/省电模式会推迟甚至吞掉闹钟（附录 A）'
    ),
    (
      PermissionKind.overlayWindow,
      Icons.picture_in_picture_alt_outlined,
      '悬浮窗',
      '贴屏把手与其他 App 上方拖出侧边栏；被拒退化为 App 内抽屉（§11）'
    ),
    (
      PermissionKind.showOnLockScreen,
      Icons.screen_lock_portrait_outlined,
      '锁屏/上层显示',
      '闹钟模式的全屏提醒需要它；被拒退化为普通通知 + 响铃'
    ),
    (
      PermissionKind.folderAccess,
      Icons.folder_open,
      '任务目录（所有文件访问）',
      '让 Obsidian 与 App 共用同一个 vault 目录；SAF 下监听不可用，'
          '降级为回前台刷新'
    ),
  ];

  final Map<PermissionKind, bool> _permState = {};
  bool _permLoading = false;

  final Map<String, GlobalKey> _routineKeys = {};
  String? _focusedRoutineId;

  AppController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _c.addListener(_onChange);
    _c.refreshTrash();
    _loadPermissions();
    _syncFocus();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _c.removeListener(_onChange);
    super.dispose();
  }

  /// 系统权限设置页是异步的（用户可能在设置页里改完再回来）：
  /// 回到前台重新查询一遍状态（原生侧 `request*Permission` 只返回"调用那一刻"）。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _loadPermissions();
  }

  void _onChange() {
    if (!mounted) return;
    setState(() {});
    _syncFocus();
  }

  /// 侧边栏『编辑规则』跳进来：滚到该规则并高亮（决议 23）。
  void _syncFocus() {
    final id = _c.settingsFocusRoutineId;
    if (id == null || id == _focusedRoutineId) return;
    _focusedRoutineId = id;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _routineKeys[id]?.currentContext;
      if (ctx == null) return;
      Scrollable.ensureVisible(ctx,
          duration: const Duration(milliseconds: 320),
          alignment: 0.15,
          curve: Curves.easeOutCubic);
    });
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
    final s = _c.settings;

    return ListView(
      padding: const EdgeInsets.fromLTRB(0, 4, 0, 40),
      children: [
        _Section('权限引导'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            '逐项申请并解释用途；被拒时对应功能优雅降级（§11）。'
            '桌面端全部视为已授予。',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
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
                      : AppColors.overdue,
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

        _Section('任务目录与入口'),
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

        _Section('提醒'),
        ListTile(
          leading: const Icon(Icons.notifications_paused_outlined),
          title: const Text('提醒模式'),
          subtitle: Text(
            s.reminderMode == ReminderMode.standard
                ? '标准（默认）：只排列不提醒——要响的任务在编辑表单里开『提醒我』'
                : '完整：凡算法判定该响的都响（标准模式与它的清单顺序完全一样）',
          ),
          trailing: SegmentedButton<ReminderMode>(
            segments: const [
              ButtonSegment(
                  value: ReminderMode.standard, label: Text('标准')),
              ButtonSegment(value: ReminderMode.full, label: Text('完整')),
            ],
            selected: {s.reminderMode},
            onSelectionChanged: (v) =>
                _c.updateSettings(s.copyWith(reminderMode: v.first)),
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
          onTap: () => _editWindows(context),
        ),

        _Section('排序'),
        ListTile(
          leading: const Icon(Icons.low_priority),
          title: const Text('排序模式'),
          subtitle: Text(
            s.sortMode == SortMode.auto
                ? '自动（默认）：按调度优先级排先后（裕度薄的在前，重要度作乘数）'
                : '无排序：不按任何排序键——顺序全靠手动拖，'
                    '今日清单会包含所有有截止的未完成任务',
          ),
          trailing: SegmentedButton<SortMode>(
            segments: const [
              ButtonSegment(value: SortMode.auto, label: Text('自动')),
              ButtonSegment(value: SortMode.manual, label: Text('无排序')),
            ],
            selected: {s.sortMode},
            onSelectionChanged: (v) =>
                _c.updateSettings(s.copyWith(sortMode: v.first)),
          ),
        ),

        _Section('周期任务（routines.md）'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            '规则住在任务目录下的 routines.md（一条一个 frontmatter 条目），'
            'Obsidian 可直接看改；每天生成当天实例，不占工时、默认不响。',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
        if (_c.routines.isEmpty)
          const ListTile(
            leading: Icon(Icons.repeat),
            title: Text('还没有周期任务'),
            subtitle: Text('点下面的按钮新建：每天 / 每周 X，可选时刻与到点提醒'),
          ),
        for (final r in _c.routines)
          _routineTile(context, r,
              highlighted: r.id == _c.settingsFocusRoutineId),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.add),
                  label: const Text('新建周期任务'),
                  onPressed: () => _editRoutine(context, null),
                ),
              ),
            ],
          ),
        ),
        SwitchListTile(
          secondary: const Icon(Icons.view_list_outlined),
          title: const Text('在任务池计划段显示'),
          subtitle: const Text('决议 27：周期任务按"下一次发生日期"升序插入计划段'),
          value: s.routineShowInPool,
          onChanged: (v) => _c.updateSettings(s.copyWith(routineShowInPool: v)),
        ),

        _Section('定期挑'),
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

        _Section('疑问笔记'),
        ListTile(
          leading: const Icon(Icons.menu_book_outlined),
          title: const Text('笔记文件路径'),
          subtitle: Text(s.notesPath ?? '未配置'),
          trailing: const Icon(Icons.edit_outlined),
          onTap: () => _editNotesPath(context),
        ),

        _Section('主题预设'),
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
          child: Text('只换强调色与中性底；逾期橙红、时间徽标等状态语义色不变（§8）',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ),

        _Section('回收站'),
        ListTile(
          leading: const Icon(Icons.delete_sweep_outlined),
          title: Text('清空回收（${_c.trashTasks.length} 件）'),
          subtitle: const Text('删除的任务先进 .gtd/.trash/，tasks.md 那一行会被注释掉（可捞）'),
          onTap: _c.trashTasks.isEmpty ? null : () => _purgeTrash(context),
        ),
      ],
    );
  }

  Widget _routineTile(BuildContext context, Routine r,
      {required bool highlighted}) {
    final key = _routineKeys.putIfAbsent(r.id, () => GlobalKey());
    return Card(
      key: key,
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      shape: highlighted
          ? RoundedRectangleBorder(
              side: BorderSide(color: AppColors.accent, width: 1.6),
              borderRadius: BorderRadius.circular(14),
            )
          : null,
      child: ListTile(
        leading: Icon(Icons.repeat,
            color: r.enabled ? AppColors.accent : Colors.blueGrey),
        title: Text(r.title,
            style: TextStyle(
                color: r.enabled ? null : Theme.of(context).disabledColor)),
        subtitle: Text(routineSubtitle(r)),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Switch(
              value: r.enabled,
              onChanged: (v) => _c.setRoutineEnabled(r.id, v),
            ),
            IconButton(
              tooltip: '删除规则',
              icon: const Icon(Icons.delete_outline, size: 20),
              onPressed: () => _deleteRoutine(context, r),
            ),
          ],
        ),
        onTap: () => _editRoutine(context, r),
      ),
    );
  }

  Future<void> _editRoutine(BuildContext context, Routine? initial) async {
    final draft = await showRoutineEditDialog(context, initial: initial);
    if (draft == null) return;
    if (initial == null) {
      await _c.addRoutine(draft);
    } else {
      await _c.updateRoutine(initial.id, draft);
    }
  }

  Future<void> _deleteRoutine(BuildContext context, Routine r) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除规则「${r.title}」？'),
        content: const Text('从 routines.md 移除；今天未完成的实例一并移入回收站。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok == true) await _c.deleteRoutine(r.id);
  }

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

  Future<void> _editWindows(BuildContext context) async {
    final windows = [
      for (final w in _c.settings.notificationWindows) [w[0], w[1]]
    ];
    Future<void> pick(int index, bool isStart) async {
      final cur = windows[index][isStart ? 0 : 1];
      final t = await showTimePicker(
        context: context,
        initialTime: TimeOfDay(hour: cur ~/ 60, minute: cur % 60),
      );
      if (t == null) return;
      final v = t.hour * 60 + t.minute;
      if (isStart ? v >= windows[index][1] : v <= windows[index][0]) return;
      windows[index][isStart ? 0 : 1] = v;
    }

    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('通知时间段（多段式）',
                    style: Theme.of(ctx).textTheme.titleSmall),
                const SizedBox(height: 4),
                Text(
                    '可推任务的提醒只落在时间段内，段外顺延到下一时段开头（不吞掉）；'
                    '时点性提醒不受限制',
                    textAlign: TextAlign.center,
                    style: Theme.of(ctx).textTheme.bodySmall),
                const SizedBox(height: 8),
                for (var i = 0; i < windows.length; i++)
                  Row(
                    children: [
                      Expanded(
                        child: TextButton(
                          onPressed: () async {
                            await pick(i, true);
                            setSheet(() {});
                          },
                          child: Text(_mm(windows[i][0])),
                        ),
                      ),
                      const Text('–'),
                      Expanded(
                        child: TextButton(
                          onPressed: () async {
                            await pick(i, false);
                            setSheet(() {});
                          },
                          child: Text(_mm(windows[i][1])),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.remove_circle_outline),
                        onPressed: () => setSheet(() => windows.removeAt(i)),
                      ),
                    ],
                  ),
                TextButton.icon(
                  onPressed: () {
                    if (windows.length >= 6) return;
                    setSheet(() => windows.add([9 * 60, 12 * 60]));
                  },
                  icon: const Icon(Icons.add),
                  label: const Text('加一段'),
                ),
                FilledButton(
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    _c.updateSettings(
                        _c.settings.copyWith(notificationWindows: windows));
                  },
                  child: const Text('保存'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _editNotesPath(BuildContext context) async {
    final ctrl = TextEditingController(text: _c.settings.notesPath ?? '');
    final path = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('疑问笔记路径'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: '/storage/…/疑问笔记.md'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (path == null) return;
    await _c.updateSettings(path.isEmpty
        ? _c.settings.copyWith(clearNotesPath: true)
        : _c.settings.copyWith(notesPath: path));
    await _c.refreshNotes();
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

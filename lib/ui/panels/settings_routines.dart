import 'package:flutter/material.dart';

import '../../domain/routine.dart';
import '../app_controller.dart';
import '../dialogs/routine_edit_dialog.dart';
import '../theme.dart';

/// 设置页「周期任务（routines.md）」区：规则列表 + 新建按钮。
/// 规则住在任务目录下的 routines.md（一条一个 frontmatter 条目），Obsidian
/// 可直接看改；每天生成当天实例，不占工时、默认不响。
///
/// 侧边栏『编辑规则』跳进来时：滚到该规则并高亮（决议 23）。
class SettingsRoutinesSection extends StatefulWidget {
  final AppController controller;

  const SettingsRoutinesSection({super.key, required this.controller});

  @override
  State<SettingsRoutinesSection> createState() =>
      _SettingsRoutinesSectionState();
}

class _SettingsRoutinesSectionState extends State<SettingsRoutinesSection> {
  final Map<String, GlobalKey> _routineKeys = {};
  String? _focusedRoutineId;

  AppController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _c.addListener(_onChange);
    _syncFocus();
  }

  @override
  void dispose() {
    _c.removeListener(_onChange);
    super.dispose();
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
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
}

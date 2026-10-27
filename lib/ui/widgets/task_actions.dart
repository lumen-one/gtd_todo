import 'package:flutter/material.dart';

import '../../domain/task.dart';
import '../app_controller.dart';
import '../dialogs/edit_task_sheet.dart';
import '../dialogs/snooze_sheet.dart';
import '../theme.dart';

/// 长按菜单（决议 23/25：按组上下文相关）+ 软删除撤销 toast（决议 15）。
///
/// [onSelectMode] 不为空时，菜单最后多一行『多选』（§10#23）：它是**模式切换**
/// 不是命令，所以不进 [taskMenuEntries] 那份共享条目表——那张表长按菜单与详情卡
/// 共用，而详情卡是"看单件"的场景，不该出现批量的入口。
Future<void> showTaskMenu(
  BuildContext context,
  AppController controller,
  Task task, {
  required TaskMenuKind kind,
  VoidCallback? onSelectMode,
}) {
  // ④ 例行实例（决议 23）：完成 / 跳过今天 / 编辑规则 / 删除规则；无『推迟』
  // （实例默认不响，改节奏去编辑规则），也没有"编辑实例"。
  if (kind == TaskMenuKind.routine) {
    return _showRoutineInstanceMenu(context, controller, task,
        onSelectMode: onSelectMode);
  }

  return _showMenuSheet(
    context,
    title: task.title,
    tag: switch (kind) {
      TaskMenuKind.picked => '被挑散件',
      TaskMenuKind.fixed => '开始型',
      TaskMenuKind.overdue => '逾期',
      TaskMenuKind.inProgress => '挂起中',
      TaskMenuKind.completed => '已完成',
      TaskMenuKind.loose => '散件',
      TaskMenuKind.branch => '支线',
      _ => null,
    },
    entries: taskMenuEntries(context, controller, task, kind),
    onSelectMode: onSelectMode,
  );
}

/// 条目动作表（正典）：**长按菜单与详情卡底部按钮共用这一份**（决议 44）。
///
/// 两处各写一套，动作迟早漂移（今天加个『转正』，只有一处记得加）。
/// 按组上下文相关（决议 23/25）；例行实例与池子条目各有一套。
List<TaskMenuEntry> taskMenuEntries(
  BuildContext context,
  AppController controller,
  Task task,
  TaskMenuKind kind,
) =>
    switch (kind) {
      TaskMenuKind.routine => _routineEntries(context, controller, task),
      TaskMenuKind.pool => _poolEntries(context, controller, task),
      TaskMenuKind.loose => _looseEntries(context, controller, task),
      TaskMenuKind.completed => _completedEntries(context, controller, task),
      _ => _todayEntries(context, controller, task, kind),
    };

/// 今日清单条目（①②③⓿⑤ 组）。
List<TaskMenuEntry> _todayEntries(BuildContext context,
    AppController controller, Task task, TaskMenuKind kind) {
  return [
    ('完成', Icons.check_circle, () => controller.complete(task.id)),
    // ② 的『推迟』= snooze 本次提醒，事件时刻不变（决议 23）；
    // 被挑散件无『推迟』（决议 25）；挂起组也无——长期任务没有截止，没有截止型迟的余地
    // （决议 47）；开始型照常给档位。
    if (kind != TaskMenuKind.picked && kind != TaskMenuKind.inProgress)
      (
        '推迟…',
        Icons.schedule,
        () => showModalBottomSheet<void>(
              context: context,
              builder: (_) => SnoozeSheet(controller: controller, task: task),
            )
      ),
    // 『挂起进行 ↔ 取消挂起』（v0.17，决议 47）：只对长期任务开这个口（有截止的
    // 归调度管）；已在挂起中的（含'转正'后仍占挂位的）给取消。挂起组条目必然
    // 已挂起，走取消那一支。
    if (task.isLongTerm || task.inProgressAt != null)
      task.inProgressAt == null
          ? (
              '挂起进行',
              Icons.play_circle_outline,
              () => controller.setInProgress(task.id, enabled: true)
            )
          : (
              '取消挂起',
              Icons.pause_circle_outline,
              () => controller.setInProgress(task.id, enabled: false)
            ),
    if (kind == TaskMenuKind.flex)
      (
        '插队到最前',
        Icons.keyboard_double_arrow_up,
        () => controller.pinToTop(task.id)
      ),
    if (kind == TaskMenuKind.picked)
      ('放回池子', Icons.undo, () => controller.returnToPool(task.id)),
    (
      '编辑',
      Icons.edit,
      () => showEditSheet(context, controller,
          task: task,
          title: kind == TaskMenuKind.picked ? '编辑（可顺手转正）' : '编辑任务')
    ),
    (
      '删除',
      Icons.delete_outline,
      () => deleteTaskWithUndo(context, controller, task)
    ),
  ];
}

/// 例行实例条目（决议 23）：无『推迟』，改节奏去『编辑规则』。
List<TaskMenuEntry> _routineEntries(
    BuildContext context, AppController controller, Task instance) {
  final routineId = instance.routineId;
  return [
    ('完成', Icons.check_circle, () => controller.complete(instance.id)),
    (
      '跳过今天',
      Icons.skip_next,
      () => controller.skipRoutineToday(instance.id)
    ),
    if (routineId != null)
      (
        '编辑规则',
        Icons.edit_calendar,
        () async => controller.focusRoutineInSettings(routineId)
      ),
    if (routineId != null)
      (
        '删除规则',
        Icons.delete_forever_outlined,
        () => _deleteRoutineWithConfirm(context, controller, routineId)
      ),
  ];
}

/// 例行实例菜单（决议 23）。
Future<void> _showRoutineInstanceMenu(
    BuildContext context, AppController controller, Task instance,
    {VoidCallback? onSelectMode}) {
  return _showMenuSheet(
    context,
    title: instance.title,
    tag: '例行',
    entries: _routineEntries(context, controller, instance),
    onSelectMode: onSelectMode,
  );
}

/// 删除规则需确认（决议 23）；连带清掉未完成的今日实例。
Future<void> _deleteRoutineWithConfirm(BuildContext context,
    AppController controller, String routineId) async {
  final routine = controller.routineById(routineId);
  final name = routine?.title ?? '该规则';
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('删除规则「$name」？'),
      content: const Text('今天未完成的实例一并移入回收站。'),
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
  if (ok == true) await controller.deleteRoutine(routineId);
}

Future<void> _showMenuSheet(
  BuildContext context, {
  required String title,
  required List<TaskMenuEntry> entries,
  String? tag,
  VoidCallback? onSelectMode,
}) {
  return showModalBottomSheet<void>(
    context: context,
    builder: (ctx) => SafeArea(
      // 可滚：今日页那个菜单本来就有五六行（完成 / 推迟 / 挂起 / 插队 / 编辑 /
      // 删除），再加『多选』在矮屏上会顶出 sheet 的限高——溢出的那几行点不到。
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(ctx).textTheme.titleSmall,
                    ),
                  ),
                  if (tag != null) _MenuTag(tag),
                ],
              ),
            ),
            for (final (label, icon, action) in entries)
              ListTile(
                leading: Icon(icon, color: AppColors.accent),
                title: Text(label),
                onTap: () async {
                  Navigator.of(ctx).pop();
                  try {
                    await action();
                  } catch (e) {
                    if (ctx.mounted) {
                      ScaffoldMessenger.of(ctx).showSnackBar(
                          SnackBar(content: Text('操作失败：$e')));
                    }
                  }
                },
              ),
            if (onSelectMode != null) ...[
              const Divider(height: 1),
              _SelectModeTile(onTap: () {
                Navigator.of(ctx).pop();
                onSelectMode();
              }),
            ],
          ],
        ),
      ),
    ),
  );
}

/// 菜单最后一行『多选』：模式切换，单独放在分隔线下面，与上面的命令分开。
class _SelectModeTile extends StatelessWidget {
  final VoidCallback onTap;

  const _SelectModeTile({required this.onTap});

  @override
  Widget build(BuildContext context) => ListTile(
        leading: Icon(Icons.checklist, color: AppColors.accent),
        title: const Text('多选'),
        onTap: onTap,
      );
}

/// 条目所在的位置：决定长按菜单与详情卡给哪些动作（决议 23/25/44）。
/// [pool] = 任务池（计划段与散件段同款，决议 13）。
/// [loose] = 今日页 ⑥ 散件段（仅无排序档，ui 文档 §6.1）。
/// [inProgress] = 今日页最顶的挂起组（决议 47：长期任务"正在做"）。
/// [completed] = 已完成页（ui 文档 §6.7：只有恢复未完成 / 删除）。
/// [branch] = 支线视图（ui 文档 §6.12：条目是任务引用，动作与今日清单同款）。
enum TaskMenuKind {
  overdue,
  fixed,
  flex,
  picked,
  routine,
  pool,
  loose,
  inProgress,
  completed,
  branch
}

class _MenuTag extends StatelessWidget {
  final String label;
  const _MenuTag(this.label);

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: AppColors.accent.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(label,
            style: TextStyle(color: AppColors.accent, fontSize: 11.5)),
      );
}

typedef TaskMenuEntry = (String, IconData, Future<void> Function());

/// 已完成页条目（ui 文档 §6.7）：动作只有两个——恢复未完成 / 删除。
/// **例行实例不给恢复**：实例是临时的，恢复一个往日实例它会从所有清单里消失
/// （今日清单只收当天实例、池子不收实例）——要续节奏去设置页『编辑规则』。
/// 恢复即撤销一次完成（误触兜底）：人类文档那行回 `- [ ]`，剩余工作量回满。
List<TaskMenuEntry> _completedEntries(
    BuildContext context, AppController controller, Task task) {
  return [
    if (task.type != TaskType.routine)
      (
        '恢复未完成',
        Icons.undo,
        () => controller.reopenTask(task.id)
      ),
    (
      '删除',
      Icons.delete_outline,
      () => deleteTaskWithUndo(context, controller, task)
    ),
  ];
}

/// 今日页 ⑥ 散件段的条目（仅无排序档）：这一档散件整段在今日页，所以没有
/// 『挑到今日』（它已经在今日），出口是**『移到任务池』**——搬到池子的散件段，
/// 长期有效；在池子里用『移到今日清单』搬回来（同一个字段的两个方向）。
List<TaskMenuEntry> _looseEntries(
    BuildContext context, AppController controller, Task task) {
  return [
    ('完成', Icons.check_circle, () => controller.complete(task.id)),
    if (task.isLongTerm && task.inProgressAt == null)
      (
        '挂起进行',
        Icons.play_circle_outline,
        () => controller.setInProgress(task.id, enabled: true)
      ),
    (
      '移到任务池',
      Icons.inventory_2_outlined,
      () => controller.setLooseHome(task.id, pool: true)
    ),
    (
      '编辑',
      Icons.edit,
      () => showEditSheet(context, controller, task: task)
    ),
    (
      '删除',
      Icons.delete_outline,
      () => deleteTaskWithUndo(context, controller, task)
    ),
  ];
}

/// 任务池条目（决议 13：散件段与计划段同款）：
/// 长期任务的『挂起进行』（v0.17，决议 47）/ 挑到今日（不转正，附今日尾部）/
/// 完成 / 编辑（补属性即转正）/ 删除。
///
/// **无排序档的散件段换一套**：池子里只剩被搬过来的那些（`loose_home: pool`），
/// 给的是『移到今日清单』——那一档不跑定期挑，⑤ 不存在，"挑到今日"没有去处。
List<TaskMenuEntry> _poolEntries(
    BuildContext context, AppController controller, Task task) {
  final looseHere = controller.isManualSort && task.deadline == null;
  return [
    // 挂起中的件在池子里隐藏（决议 47），所以这里只会给"未挂起"的长期任务。
    if (task.isLongTerm && task.inProgressAt == null)
      (
        '挂起进行',
        Icons.play_circle_outline,
        () => controller.setInProgress(task.id, enabled: true)
      ),
    if (looseHere)
      (
        '移到今日清单',
        Icons.today,
        () => controller.setLooseHome(task.id, pool: false)
      )
    else
      ('挑到今日', Icons.today, () => controller.pickForToday(task.id)),
    ('完成', Icons.check_circle, () => controller.complete(task.id)),
    (
      '编辑',
      Icons.edit,
      () => showEditSheet(context, controller, task: task)
    ),
    (
      '删除',
      Icons.delete_outline,
      () => deleteTaskWithUndo(context, controller, task)
    ),
  ];
}

/// 任务池条目菜单（决议 13）。与今日页那份走同一个 sheet（tag 规则不同），
/// 不再各写一遍——两份手写 sheet 迟早分叉。
Future<void> showPoolMenu(
    BuildContext context, AppController controller, Task task,
    {VoidCallback? onSelectMode}) {
  return _showMenuSheet(
    context,
    title: task.title,
    tag: task.type == TaskType.flex && task.deadline == null
        ? '三无'
        : task.type == TaskType.fixed
            ? '开始型'
            : null,
    entries: taskMenuEntries(context, controller, task, TaskMenuKind.pool),
    onSelectMode: onSelectMode,
  );
}

/// 删除 = 软删除（D11）：内核属性文件进 `.gtd/.trash/`、人类文档那一行注释掉
/// + 撤销 toast（约 4 秒），无二次确认。
Future<void> deleteTaskWithUndo(
    BuildContext context, AppController controller, Task task) async {
  await controller.deleteTask(task.id);
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text('已删除「${task.title}」'),
      // 新版 Flutter 里带 action 的 SnackBar 默认 persist（到点不消失，等用户点
      // action）——与决议 15 的"撤销 toast"口径冲突，显式关掉。
      persist: false,
      duration: const Duration(seconds: 4),
      action: SnackBarAction(
        label: '撤销',
        onPressed: () => controller.restoreTask(task.id),
      ),
    ),
  );
}

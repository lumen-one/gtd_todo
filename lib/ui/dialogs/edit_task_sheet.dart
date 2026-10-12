import 'package:flutter/material.dart';

import '../../domain/schedule.dart';
import '../../domain/task.dart';
import '../app_controller.dart';
import '../widgets/task_tile.dart' show fmtDateTime;
import 'create_task_dialog.dart' show pickDateTime;

/// 编辑态 = 属性展开表单（决议 17）：显式控件直改类型/日期/工时/备注，
/// 改完调度自动重锚。长按滑档位手势只属于『新建』。
/// 散件『转正』复用本表单（补类型/截止/工时，进调度）。
Future<void> showEditSheet(BuildContext context, AppController controller,
    {required Task task, String title = '编辑任务'}) {
  final titleCtrl = TextEditingController(text: task.title);
  final noteCtrl = TextEditingController(text: task.description);
  final workCtrl = TextEditingController(
      text: task.type == TaskType.fixed ? '' : '${task.estimatedWork}');
  var type = task.type;
  DateTime? deadline = task.deadline;
  var deadlineCleared = false;
  var importance = task.importance;
  // 逐任务提醒开关（v0.9 决议 38）：标准模式下让这一件出声；不改顺序。
  var remind = task.remindEnabled;

  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSheet) => Padding(
        padding:
            EdgeInsets.fromLTRB(20, 16, 20, 16 + MediaQuery.of(ctx).viewInsets.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: Theme.of(ctx).textTheme.titleMedium),
            const SizedBox(height: 12),
            TextField(
              controller: titleCtrl,
              decoration: const InputDecoration(labelText: '标题'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: noteCtrl,
              maxLines: 2,
              minLines: 1,
              decoration: const InputDecoration(labelText: '备注（选填）'),
            ),
            const SizedBox(height: 12),
            SegmentedButton<TaskType>(
              segments: const [
                ButtonSegment(
                    value: TaskType.flex,
                    icon: Icon(Icons.schedule),
                    label: Text('可推')),
                ButtonSegment(
                    value: TaskType.fixed,
                    icon: Icon(Icons.push_pin),
                    label: Text('不可推')),
              ],
              selected: {type},
              onSelectionChanged: (s) => setSheet(() {
                type = s.first;
                if (type == TaskType.fixed && deadline == null) {
                  deadline = DateTime.now().add(const Duration(hours: 1));
                }
              }),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Text(
                    deadline == null
                        ? '无截止（散件）'
                        : '截止 ${fmtDateTime(deadline!)}',
                    style: Theme.of(ctx).textTheme.bodyMedium,
                  ),
                ),
                TextButton(
                  onPressed: () async {
                    final dt = await pickDateTime(ctx, initial: deadline);
                    if (dt != null) {
                      setSheet(() {
                        deadline = dt;
                        deadlineCleared = false;
                      });
                    }
                  },
                  child: const Text('选时间'),
                ),
                if (deadline != null)
                  TextButton(
                    onPressed: () => setSheet(() {
                      deadline = null;
                      deadlineCleared = true;
                    }),
                    child: const Text('清除'),
                  ),
              ],
            ),
            if (type == TaskType.flex) ...[
              Row(
                children: [
                  const Text('预计工时（分钟）'),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      controller: workCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(hintText: '30'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  const Text('重要度'),
                  Expanded(
                    child: Slider(
                      value: importance.toDouble(),
                      min: 1,
                      max: 5,
                      divisions: 4,
                      label: '$importance',
                      onChanged: (v) => setSheet(() => importance = v.round()),
                    ),
                  ),
                ],
              ),
            ],
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.notifications_active_outlined),
              title: const Text('提醒我'),
              subtitle: Text(
                controller.reminderMode == ReminderMode.full
                    ? '当前是完整模式：该响的都会响，这个开关不额外做什么'
                    : '当前是标准模式（只排列不提醒）：打开它，这一件才会出声',
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
              value: remind,
              onChanged: (v) => setSheet(() => remind = v),
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: () async {
                final work = int.tryParse(workCtrl.text.trim());
                try {
                  await controller.updateTask(
                    task.id,
                    title: titleCtrl.text.trim(),
                    description: noteCtrl.text,
                    type: type,
                    deadline: deadline,
                    clearDeadline:
                        deadline == null && deadlineCleared,
                    estimatedWorkMinutes: work,
                    importance: importance,
                  );
                } catch (e) {
                  if (ctx.mounted) {
                    ScaffoldMessenger.of(ctx).showSnackBar(
                        SnackBar(content: Text('保存失败：$e')));
                  }
                  return;
                }
                // 提醒开关是独立的持久意图（metadata `remind`），只在真的变了时写一次。
                if (remind != task.remindEnabled) {
                  await controller.setTaskReminder(task.id, enabled: remind);
                }
                if (ctx.mounted) Navigator.of(ctx).pop();
              },
              child: const Text('保存'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    ),
  );
}

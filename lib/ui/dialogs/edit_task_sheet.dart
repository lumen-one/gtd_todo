import 'package:flutter/material.dart';

import '../../domain/schedule.dart';
import '../../domain/task.dart';
import '../app_controller.dart';
import '../widgets/task_tile.dart' show fmtDateTime;
import 'create_task_dialog.dart' show pickDateTime;

/// 编辑态 = 属性展开表单（决议 17）：显式控件直改类型/日期/工时/备注，
/// 改完调度自动重锚。长按滑档位手势只属于『新建』。
/// 散件『转正』复用本表单（补截止 + 把'长期'换成具体工时，进调度；§6.3）。
Future<void> showEditSheet(BuildContext context, AppController controller,
    {required Task task, String title = '编辑任务'}) {
  final titleCtrl = TextEditingController(text: task.title);
  final noteCtrl = TextEditingController(text: task.description);
  // '长期' ↔ 按时长（v1.17，D18）：编辑表单里显式二选一——'长期'是创建缺省
  // 不是不变量，两个方向都走这里显式设，不悄悄改语义（§3.4 防线三）。
  var longTerm = task.isLongTerm;
  final workCtrl = TextEditingController(
      text: task.isLongTerm ? '' : '${task.estimatedWork}');
  var type = task.type;
  DateTime? deadline = task.deadline;
  var deadlineCleared = false;
  var importance = task.importance ?? 3;
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
              // 工作强度二选一（v1.17，D18）：'长期' = 不估工时、不设优先级
              // （内核属性文档只有 id）；'按时长' = 数字工时进 slack 数学。
              Row(
                children: [
                  const Text('工作强度'),
                  const SizedBox(width: 12),
                  SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(value: true, label: Text('长期')),
                      ButtonSegment(value: false, label: Text('按时长')),
                    ],
                    selected: {longTerm},
                    onSelectionChanged: (s) =>
                        setSheet(() => longTerm = s.first),
                  ),
                ],
              ),
              if (!longTerm) ...[
                const SizedBox(height: 4),
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
                // '长期' → '按时长'且没填工时：按 A2 缺省 30 分钟（转正的另一半）；
                // 已经是'按时长'却空着 → 传 null 保持原值，不偷偷改。
                final work = int.tryParse(workCtrl.text.trim()) ??
                    (task.isLongTerm && !longTerm ? 30 : null);
                try {
                  await controller.updateTask(
                    task.id,
                    title: titleCtrl.text.trim(),
                    description: noteCtrl.text,
                    type: type,
                    deadline: deadline,
                    clearDeadline:
                        deadline == null && deadlineCleared,
                    estimatedWorkMinutes: longTerm ? null : work,
                    // 显式设'长期'（三项一起清）；'长期' → '按时长'时走上面的
                    // estimatedWorkMinutes（服务会补剩余量与优先级缺省 3）。
                    clearWork: longTerm && !task.isLongTerm,
                    importance: longTerm ? null : importance,
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

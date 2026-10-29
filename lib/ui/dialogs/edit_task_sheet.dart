import 'package:flutter/material.dart';

import '../../domain/task.dart';
import '../app_controller.dart';
import 'date_pick.dart';
import 'task_form.dart';

/// 编辑态 = 属性展开表单（决议 17）：显式控件直改类型/日期/工时/备注，
/// 改完调度自动重锚。长按滑档位手势只属于『新建』。
///
/// 字段与新建第 2 页同源（[TaskFormBody]）：两边能填的东西一样，
/// 只有"初值从哪来、提交走哪条命令"不同。
Future<void> showEditSheet(
  BuildContext context,
  AppController controller, {
  required Task task,
  String title = '编辑任务',
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _EditTaskSheet(
      controller: controller,
      task: task,
      title: title,
    ),
  );
}

class _EditTaskSheet extends StatefulWidget {
  final AppController controller;
  final Task task;
  final String title;

  const _EditTaskSheet({
    required this.controller,
    required this.task,
    required this.title,
  });

  @override
  State<_EditTaskSheet> createState() => _EditTaskSheetState();
}

class _EditTaskSheetState extends State<_EditTaskSheet> {
  late final _titleCtrl = TextEditingController(text: widget.task.title);
  late final _noteCtrl = TextEditingController(text: widget.task.description);
  late final _workCtrl = TextEditingController(
    text: widget.task.isLongTerm ? '' : '${widget.task.estimatedWork}',
  );
  late TaskFormValue _value = TaskFormValue(
    title: widget.task.title,
    description: widget.task.description,
    type: widget.task.type,
    deadline: widget.task.deadline,
    longTerm: widget.task.isLongTerm,
    importance: widget.task.importance ?? 3,
    remind: widget.task.ringEnabled,
  );

  @override
  void dispose() {
    _titleCtrl.dispose();
    _noteCtrl.dispose();
    _workCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickDeadline() async {
    final picked = await pickDateTime(context, initial: _value.deadline);
    if (picked == null || !mounted) return;
    setState(() => _value = _value.copyWith(deadline: picked));
  }

  Future<void> _save() async {
    final task = widget.task;
    // '长期' → '按时长'且没填工时：按 A2 缺省 30 分钟（转正的另一半）；
    // 已经是'按时长'却空着 → 传 null 保持原值，不偷偷改。
    final work = int.tryParse(_workCtrl.text.trim()) ??
        (task.isLongTerm && !_value.longTerm ? 30 : null);
    try {
      await widget.controller.updateTask(
        task.id,
        title: _titleCtrl.text.trim(),
        description: _noteCtrl.text,
        type: _value.type,
        deadline: _value.deadline,
        clearDeadline: _value.deadline == null && task.deadline != null,
        estimatedWorkMinutes: _value.longTerm ? null : work,
        // 显式设'长期'（三项一起清）；'长期' → '按时长'时走上面的
        // estimatedWorkMinutes（服务会补剩余量与优先级缺省 3）。
        clearWork: _value.longTerm && !task.isLongTerm,
        importance: _value.longTerm ? null : _value.importance,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存失败：$e')),
      );
      return;
    }
    // 响铃是独立的持久意图（metadata `remind`），只在真的变了时写一次。
    if (_value.remind != task.ringEnabled) {
      await widget.controller.setTaskReminder(task.id, enabled: _value.remind);
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        16,
        20,
        16 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(widget.title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          TaskFormBody(
            value: _value,
            onChanged: (v) => setState(() => _value = v),
            titleCtrl: _titleCtrl,
            noteCtrl: _noteCtrl,
            workCtrl: _workCtrl,
            onSubmit: _save,
            deadlineActions: [
              TextButton(
                onPressed: _pickDeadline,
                child: const Text('选时间'),
              ),
              if (_value.deadline != null)
                TextButton(
                  onPressed: () =>
                      setState(() => _value = _value.copyWith(deadline: null)),
                  child: const Text('清除'),
                ),
            ],
          ),
          const SizedBox(height: 12),
          FilledButton(onPressed: _save, child: const Text('保存')),
        ],
      ),
    );
  }
}

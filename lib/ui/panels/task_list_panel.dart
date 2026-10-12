import 'package:flutter/material.dart';

import '../../domain/schedule.dart';
import '../../domain/task.dart';
import '../app_controller.dart';

String _two(int n) => n.toString().padLeft(2, '0');

String fmt(DateTime d) =>
    '${d.month}-${_two(d.day)} ${_two(d.hour)}:${_two(d.minute)}';

/// 任务列表面板（§5.1 panels）：平台无关的功能内容。
/// 窗口级 chrome（AppBar/FAB）归 shell；提醒弹窗与创建对话框属于面板交互。
class TaskListPanel extends StatefulWidget {
  final AppController controller;

  const TaskListPanel({super.key, required this.controller});

  @override
  TaskListPanelState createState() => TaskListPanelState();
}

class TaskListPanelState extends State<TaskListPanel> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChange);
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeShowReminder());
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
    _maybeShowReminder();
  }

  // ---- 供 shell 调用的公开入口 ----

  void openCreateDialog() => _showCreateDialog(context);

  void openWorkRuleDialog() => _showWorkRuleDialog(context);

  void _maybeShowReminder() {
    final event = widget.controller.lastReminder;
    if (event == null || !mounted) return;
    widget.controller.clearReminder();
    final result = event.schedule;
    final task = widget.controller.taskById(result.nextTaskId ?? '');
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('⏰ 该做这件事了'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(task?.title ?? '（任务已不存在）',
                style: Theme.of(ctx).textTheme.titleMedium),
            if (task != null) ...[
              const SizedBox(height: 8),
              Text('剩余约 ${task.remainingWork} 分钟工作量'),
              if (task.deadline != null)
                Text('截止：${fmt(task.deadline!)}'),
            ],
          ],
        ),
        actions: [
          if (task != null) ...[
            TextButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                widget.controller.snooze(task.id, minutes: 30);
              },
              child: const Text('推迟 30 分'),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                widget.controller.snooze(task.id, minutes: 120);
              },
              child: const Text('推迟 2 小时'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                widget.controller.complete(task.id);
              },
              child: const Text('完成'),
            ),
          ] else
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('知道了'),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final schedule = controller.schedule;
    final tasks = _orderedTasks(controller, schedule);
    final warnings = controller.warnings;
    final infeasible = controller.infeasibleCount;
    final nextTitle = controller.nextTaskTitle;

    return Column(
      children: [
        _ScheduleHeader(
          schedule: schedule,
          nextTaskTitle: nextTitle,
          warningCount: warnings.length,
          firstWarning: warnings.isEmpty ? null : warnings.first,
          infeasibleCount: infeasible,
          reminderMode: controller.reminderMode,
        ),
        const Divider(height: 1),
        Expanded(
          child: tasks.isEmpty
              ? const Center(child: Text('还没有任务，点右下角 + 创建'))
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 88),
                  itemCount: tasks.length,
                  itemBuilder: (context, i) =>
                      _TaskCard(controller: controller, task: tasks[i]),
                ),
        ),
      ],
    );
  }

  List<Task> _orderedTasks(AppController controller, ScheduleResult? schedule) {
    final byId = {for (final t in controller.tasks) t.id: t};
    final ordered = <Task>[];
    if (schedule != null) {
      for (final m in schedule.items) {
        final t = byId.remove(m.taskId);
        if (t != null) ordered.add(t);
      }
    }
    ordered.addAll(byId.values);
    return ordered;
  }

  void _showWorkRuleDialog(BuildContext context) {
    final rule = widget.controller.workRule;
    final names = ['一', '二', '三', '四', '五', '六', '日'];
    final rows = <String>[];
    rule.weekly.forEach((day, windows) {
      final w = windows
          .map((x) =>
              '${_two(x.startMinute ~/ 60)}:${_two(x.startMinute % 60)}-'
              '${_two(x.endMinute ~/ 60)}:${_two(x.endMinute % 60)}')
          .join('、');
      rows.add('周${names[day - 1]}：$w');
    });
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('工作时间规则'),
        content: Text(rows.join('\n')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<void> _showCreateDialog(BuildContext context) async {
    final titleCtrl = TextEditingController();
    final minutesCtrl = TextEditingController(text: '60');
    var importance = 3;
    DateTime? pickedDate;
    TimeOfDay? pickedTime;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('新建任务'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: titleCtrl,
                  decoration: const InputDecoration(labelText: '标题'),
                  autofocus: true,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: minutesCtrl,
                  decoration: const InputDecoration(
                      labelText: '预计工时（分钟）'),
                  keyboardType: TextInputType.number,
                ),
                const SizedBox(height: 12),
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
                        onChanged: (v) =>
                            setDialogState(() => importance = v.round()),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: Text(pickedDate == null
                          ? '未选择截止日期'
                          : '截止：${fmt(DateTime(pickedDate!.year, pickedDate!.month, pickedDate!.day, pickedTime?.hour ?? 18, pickedTime?.minute ?? 0))}'),
                    ),
                    TextButton(
                      onPressed: () async {
                        final d = await showDatePicker(
                          context: ctx,
                          firstDate: DateTime.now(),
                          lastDate:
                              DateTime.now().add(const Duration(days: 365)),
                        );
                        if (d != null) setDialogState(() => pickedDate = d);
                      },
                      child: const Text('选日期'),
                    ),
                    TextButton(
                      onPressed: () async {
                        final t = await showTimePicker(
                          context: ctx,
                          initialTime: const TimeOfDay(hour: 18, minute: 0),
                        );
                        if (t != null) setDialogState(() => pickedTime = t);
                      },
                      child: const Text('选时间'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('创建'),
            ),
          ],
        ),
      ),
    );

    if (ok != true || !context.mounted) return;
    final title = titleCtrl.text.trim();
    if (title.isEmpty || pickedDate == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('需要标题和截止日期')),
      );
      return;
    }
    widget.controller.createTask(
      title: title,
      deadline: DateTime(
        pickedDate!.year,
        pickedDate!.month,
        pickedDate!.day,
        pickedTime?.hour ?? 18,
        pickedTime?.minute ?? 0,
      ),
      estimatedWorkMinutes: int.tryParse(minutesCtrl.text.trim()) ?? 60,
      importance: importance,
    );
  }
}

class _ScheduleHeader extends StatelessWidget {
  final ScheduleResult? schedule;
  final String? nextTaskTitle;
  final int warningCount;
  final String? firstWarning;
  final int infeasibleCount;

  /// 提醒模式（v1.9）：标准模式下"没有待提醒的任务"是默认状态而不是故障，
  /// 所以这句话要说清原因，免得被当成通知没配好。
  final ReminderMode reminderMode;

  const _ScheduleHeader({
    required this.schedule,
    this.nextTaskTitle,
    this.warningCount = 0,
    this.firstWarning,
    this.infeasibleCount = 0,
    this.reminderMode = ReminderMode.standard,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = schedule;
    if (s == null) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text('正在计算调度…', style: theme.textTheme.bodySmall),
      );
    }

    final nextReminder = s.nextReminderAt;
    final hasInfeasible = infeasibleCount > 0;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.bolt, size: 20),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  hasInfeasible
                      ? '⚠ 有 $infeasibleCount 个任务按期已不可行，请改截止或砍范围'
                      : '当前建议先做：${nextTaskTitle ?? '—'}',
                  style: theme.textTheme.titleSmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            nextReminder != null
                ? '下次提醒：${fmt(nextReminder)}'
                : reminderMode == ReminderMode.standard
                    ? '不提醒（标准模式：给任务开『提醒我』，或切完整模式）'
                    : '没有待提醒的任务',
            style: theme.textTheme.bodySmall,
          ),
          if (warningCount > 0) ...[
            const SizedBox(height: 4),
            Text(
              '⚠ $warningCount 条告警：${firstWarning ?? ''}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.error),
            ),
          ],
        ],
      ),
    );
  }
}

class _TaskCard extends StatelessWidget {
  final AppController controller;
  final Task task;

  const _TaskCard({required this.controller, required this.task});

  @override
  Widget build(BuildContext context) {
    final schedule = controller.schedule;
    final metric = schedule?.metricOf(task.id);
    final theme = Theme.of(context);

    final badge = switch (metric?.displayStatus) {
      TaskDisplayStatus.infeasible =>
        const _Chip(label: '不可行', color: Colors.deepOrange),
      TaskDisplayStatus.overdue =>
        const _Chip(label: '已逾期', color: Colors.red),
      TaskDisplayStatus.snoozed =>
        const _Chip(label: '已推迟', color: Colors.blueGrey),
      _ => metric == null
          ? const _Chip(label: '已完成', color: Colors.green)
          : _Chip(
              // v1.9：排序键是"调度优先级 = 风险 × 重要度"，展示风险比旧的
              // 紧急度更贴近现在的口径（数值本身不落盘、不进人类文档）。
              label: '风险 ${(metric.risk * 100).toStringAsFixed(0)}%',
              color: metric.risk > 0.7 ? Colors.orange : Colors.teal),
    };

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(task.title, style: theme.textTheme.titleMedium),
                ),
                badge,
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '${task.deadline == null ? '无截止' : '截止 ${fmt(task.deadline!)}'}'
              ' · 剩余 ${task.remainingWork}/${task.estimatedWork} 分钟'
              ' · 重要度 ${task.importance}'
              '${metric == null ? '' : ' · 裕度 ${metric.slackMinutes} 分钟'
                  '${metric.reminderAt == null ? '' : ' · 下次提醒 ${fmt(metric.reminderAt!)}'}'}',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                FilledButton.tonal(
                  onPressed: () => controller.complete(task.id),
                  child: const Text('完成'),
                ),
                OutlinedButton(
                  onPressed: () => controller.snooze(task.id, minutes: 30),
                  child: const Text('推迟30分'),
                ),
                OutlinedButton(
                  onPressed: () => controller.snooze(task.id, minutes: 120),
                  child: const Text('推迟2小时'),
                ),
                OutlinedButton(
                  onPressed: () => controller.snoozeToNextWindow(task.id),
                  child: const Text('到下工作窗'),
                ),
                OutlinedButton(
                  onPressed: () => controller.logWork(task.id, minutes: 30),
                  child: const Text('干了30分'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final Color color;

  const _Chip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(label,
          style: TextStyle(color: color, fontSize: 12)),
    );
  }
}

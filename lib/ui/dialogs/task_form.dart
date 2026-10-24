import 'package:flutter/material.dart';

import '../../domain/schedule.dart';
import '../../domain/task.dart';
import '../app_controller.dart';
import '../widgets/task_tile.dart' show fmtDateTime;

/// 一张表单快照：新建的第 2 页与『编辑』共用同一组字段。
///
/// 控件只实现一遍，两侧的差别只剩"初值从哪儿来、提交走哪条命令"——
/// 分开写的话，新建能填的字段和编辑能填的字段会各自漂移（新建只有标题、
/// 编辑有工时，改一处忘一处）。
@immutable
class TaskFormValue {
  final String title;
  final String description;
  final TaskType type;
  final DateTime? deadline;

  /// 工作强度 = '长期'：不估工时、不设优先级。只在可推时有意义。
  final bool longTerm;
  final int importance;
  final bool remind;

  const TaskFormValue({
    this.title = '',
    this.description = '',
    this.type = TaskType.flex,
    this.deadline,
    this.longTerm = false,
    this.importance = 3,
    this.remind = false,
  });

  /// 「不排期」= 没有截止：只能是可推散件，也不出声。
  bool get isLoose => deadline == null;

  TaskFormValue copyWith({
    String? title,
    String? description,
    TaskType? type,
    Object? deadline = _keep,
    bool? longTerm,
    int? importance,
    bool? remind,
  }) =>
      TaskFormValue(
        title: title ?? this.title,
        description: description ?? this.description,
        type: type ?? this.type,
        deadline:
            identical(deadline, _keep) ? this.deadline : deadline as DateTime?,
        longTerm: longTerm ?? this.longTerm,
        importance: importance ?? this.importance,
        remind: remind ?? this.remind,
      );
}

/// [TaskFormValue.copyWith] 里"这次不动这个字段"的占位值——`null` 本身有意义
/// （清掉截止），所以不能拿 null 当"不改"。
const Object _keep = Object();

/// 表单本体：标题 / 备注 / 截止摘要 + 右侧动作 / 类型 / 工作强度 / 提醒。
///
/// 受控组件——[value] 由宿主持有，每次改动经 [onChanged] 交回去，
/// 提交按钮、日期摘要这些就都能跟着状态走。
class TaskFormBody extends StatelessWidget {
  final AppController controller;
  final TaskFormValue value;
  final ValueChanged<TaskFormValue> onChanged;
  final TextEditingController titleCtrl;
  final TextEditingController noteCtrl;
  final TextEditingController workCtrl;

  /// 标题是否抢焦点：新建要（打开就能打字），编辑不要（改哪项点哪项）。
  final bool autofocusTitle;

  /// 截止行右侧的动作（新建是『改日期』，编辑是『选时间』『清除』）。
  final List<Widget> deadlineActions;

  /// 备注框回车：新建 = 提交，编辑 = 保存。
  final VoidCallback? onSubmit;

  const TaskFormBody({
    super.key,
    required this.controller,
    required this.value,
    required this.onChanged,
    required this.titleCtrl,
    required this.noteCtrl,
    required this.workCtrl,
    this.autofocusTitle = false,
    this.deadlineActions = const [],
    this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.colorScheme.onSurfaceVariant;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: titleCtrl,
          autofocus: autofocusTitle,
          textInputAction: TextInputAction.next,
          onSubmitted: (_) => FocusScope.of(context).nextFocus(),
          onChanged: (t) => onChanged(value.copyWith(title: t)),
          decoration: const InputDecoration(labelText: '标题'),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: noteCtrl,
          maxLines: 2,
          minLines: 1,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => onSubmit?.call(),
          onChanged: (t) => onChanged(value.copyWith(description: t)),
          decoration: const InputDecoration(labelText: '备注（选填）'),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Icon(
              value.isLoose ? Icons.waves : Icons.event,
              size: 18,
              color: hint,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                value.isLoose
                    ? '不排期（散件）'
                    : '截止 ${fmtDateTime(value.deadline!)}',
                style: theme.textTheme.bodyMedium,
              ),
            ),
            ...deadlineActions,
          ],
        ),
        const SizedBox(height: 8),
        SegmentedButton<TaskType>(
          segments: const [
            ButtonSegment(
              value: TaskType.flex,
              icon: Icon(Icons.schedule),
              label: Text('可推'),
            ),
            ButtonSegment(
              value: TaskType.fixed,
              icon: Icon(Icons.push_pin),
              label: Text('不可推'),
            ),
          ],
          selected: {value.type},
          onSelectionChanged: (s) {
            final type = s.first;
            // 不可推必须有确切时刻：没日期就地补一个（一小时后），
            // 不拦着用户先去点『选时间』。
            onChanged(
              type == TaskType.fixed && value.isLoose
                  ? value.copyWith(
                      type: type,
                      deadline: DateTime.now().add(const Duration(hours: 1)),
                    )
                  : value.copyWith(type: type),
            );
          },
        ),
        if (value.type == TaskType.flex) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              const Text('工作强度'),
              const SizedBox(width: 12),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: true, label: Text('长期')),
                  ButtonSegment(value: false, label: Text('按时长')),
                ],
                selected: {value.longTerm},
                onSelectionChanged: (s) =>
                    onChanged(value.copyWith(longTerm: s.first)),
              ),
            ],
          ),
          if (!value.longTerm) ...[
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
                    value: value.importance.toDouble(),
                    min: 1,
                    max: 5,
                    divisions: 4,
                    label: '${value.importance}',
                    onChanged: (v) =>
                        onChanged(value.copyWith(importance: v.round())),
                  ),
                ),
              ],
            ),
          ],
        ],
        // 散件永不出声（§7.0），问"要不要吵你"没有意义。
        if (!value.isLoose)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            secondary: const Icon(Icons.notifications_active_outlined),
            title: const Text('提醒我'),
            subtitle: Text(
              controller.reminderMode == ReminderMode.full
                  ? '完整模式下该响的都会响'
                  : '打开它，这一件才会出声',
              style: theme.textTheme.bodySmall,
            ),
            value: value.remind,
            onChanged: (v) => onChanged(value.copyWith(remind: v)),
          ),
      ],
    );
  }
}

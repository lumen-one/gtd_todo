import 'package:flutter/material.dart';

import '../../domain/schedule.dart';
import '../../domain/task.dart';
import '../theme.dart';
import '../widgets/task_tile.dart' show fmtTime;
import 'date_pick.dart' show atDefaultHour;

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

  /// 工作强度 = '长期'：不估工时、不设优先级。只在截止型时有意义。
  final bool longTerm;
  final int importance;
  final bool remind;

  /// 时刻被用户手动改过：此后切类型不再把它换回默认整点。
  final bool timePinned;

  const TaskFormValue({
    this.title = '',
    this.description = '',
    this.type = TaskType.flex,
    this.deadline,
    this.longTerm = false,
    this.importance = 3,
    // 新建默认打开：用户"设了时间"就是想要一条提醒，不该再让他去翻一个开关。
    // 标准/无排序两档的提醒门槛靠它放行（§7.0），关掉才安静。
    this.remind = true,
    this.timePinned = false,
  });

  /// 「不排期」= 没有截止：只能是截止型散件，也不出声。
  bool get isLoose => deadline == null;

  TaskFormValue copyWith({
    String? title,
    String? description,
    TaskType? type,
    Object? deadline = _keep,
    bool? longTerm,
    int? importance,
    bool? remind,
    bool? timePinned,
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
        timePinned: timePinned ?? this.timePinned,
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
  final TaskFormValue value;
  final ValueChanged<TaskFormValue> onChanged;
  final TextEditingController titleCtrl;
  final TextEditingController noteCtrl;
  final TextEditingController workCtrl;

  /// 标题是否抢焦点：新建要（打开就能打字），编辑不要（改哪项点哪项）。
  final bool autofocusTitle;

  /// 截止行右侧的动作（新建是『改日期』，编辑是『选时间』『清除』）。
  final List<Widget> deadlineActions;

  /// 时刻本身可点开改（新建走这条）；null = 不接，时刻只是文字。
  final VoidCallback? onEditTime;

  /// 切类型时把**没手动改过**的时刻换成该类型的默认整点（新建）。
  ///
  /// 编辑不接：已经落定的时刻不该因为改了个类型被挪走。
  final bool hourFollowsType;

  /// 备注框回车：新建 = 提交，编辑 = 保存。
  final VoidCallback? onSubmit;

  /// **新建时按档位裁的三行**（§5.1 / §7.0）：无排序档全不显示（缺省值照常落盘），
  /// 标准档只显示工时，完整档显示工时 + 重要度。
  ///
  /// **编辑态三个都传 true**：编辑表单不裁——它也是把一件从缺省值升成有估值的
  /// 唯一入口，藏起工时行等于让人先切档。
  final bool showWorkStrength;
  final bool showImportance;

  const TaskFormBody({
    super.key,
    required this.value,
    required this.onChanged,
    required this.titleCtrl,
    required this.noteCtrl,
    required this.workCtrl,
    this.autofocusTitle = false,
    this.deadlineActions = const [],
    this.onEditTime,
    this.hourFollowsType = false,
    this.onSubmit,
    this.showWorkStrength = true,
    this.showImportance = true,
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
              // 「截止」与「开始」是同一字段的两种语义（§4.1）：截止型数着剩余
              // 工时催，开始型到点响一次。文案跟着类型走。
              child: value.isLoose
                  ? Text('不排期（散件）', style: theme.textTheme.bodyMedium)
                  : _DeadlineLabel(value: value, onEditTime: onEditTime),
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
              label: Text('截止型'),
            ),
            ButtonSegment(
              value: TaskType.fixed,
              icon: Icon(Icons.push_pin),
              label: Text('开始型'),
            ),
          ],
          selected: {value.type},
          onSelectionChanged: (s) {
            final type = s.first;
            var next = value.copyWith(type: type);
            // 时刻按类型取默认（截止 18:00、开始 12:00）；用户手动改过的时刻不动。
            if (hourFollowsType && !value.timePinned && value.deadline != null) {
              next = next.copyWith(
                  deadline: atDefaultHour(value.deadline!, type));
            }
            // 开始型必须有确切时刻：没日期就地补一个（一小时后），
            // 不拦着用户先去点『选时间』。
            onChanged(value.isLoose
                ? next.copyWith(
                    deadline: DateTime.now().add(const Duration(hours: 1)))
                : next);
          },
        ),
        if (value.type == TaskType.flex && showWorkStrength) ...[
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
            if (showImportance) ...[
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
        ],
        // 散件永远不提醒（§7.0），问"响不响铃"没有意义。
        // **三档都摆这一行**：提醒一律会发，它管的是声音，不管发不发。
        if (!value.isLoose)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            secondary: Icon(value.remind
                ? Icons.volume_up_outlined
                : Icons.volume_off_outlined),
            title: const Text('响铃'),
            subtitle: Text(
              '提醒一律发到通知栏（带横幅）；关掉只是不出声',
              style: theme.textTheme.bodySmall,
            ),
            value: value.remind,
            onChanged: (v) => onChanged(value.copyWith(remind: v)),
          ),
      ],
    );
  }
}

/// 截止行中间那段：`截止 10-28` 加时刻。
///
/// 时刻可点时用强调色加下划线——这一屏里只有它能改时间，得看得出来点得动。
class _DeadlineLabel extends StatelessWidget {
  final TaskFormValue value;
  final VoidCallback? onEditTime;

  const _DeadlineLabel({required this.value, this.onEditTime});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final d = value.deadline!;
    final label = Text(
      '${value.type == TaskType.fixed ? '开始' : '截止'} ${d.month}-'
      '${d.day.toString().padLeft(2, '0')} ',
      style: theme.textTheme.bodyMedium,
      overflow: TextOverflow.ellipsis,
    );
    final time = Text(
      fmtTime(d),
      style: onEditTime == null
          ? theme.textTheme.bodyMedium
          : theme.textTheme.bodyMedium?.copyWith(
              color: AppColors.accent,
              decoration: TextDecoration.underline,
              decorationColor: AppColors.accent.withValues(alpha: 0.5),
            ),
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(child: label),
        if (onEditTime == null)
          time
        else
          InkWell(
            onTap: onEditTime,
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
              child: time,
            ),
          ),
      ],
    );
  }
}

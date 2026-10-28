import 'package:flutter/material.dart';

import '../../domain/schedule.dart';
import '../../domain/task.dart';
import '../app_controller.dart';
import '../theme.dart';

String _two(int n) => n.toString().padLeft(2, '0');

String fmtTime(DateTime d) => '${_two(d.hour)}:${_two(d.minute)}';

String fmtDateTime(DateTime d) =>
    '${d.month}-${_two(d.day)} ${_two(d.hour)}:${_two(d.minute)}';

/// 任务行（今日清单 / 任务池 / 日历共用）：编号大而醒目（橙）、标题为主文案、
/// 备注弱化、徽标只给关键状态（§8）。
class TaskTile extends StatelessWidget {
  final AppController controller;
  final Task task;

  /// 连续编号；null = 无编号（逾期组 / 被挑散件）。
  final int? number;

  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool dimmed; // 被挑散件弱化呈现（决议 25）
  final Widget? trailing; // 拖拽把手等插槽

  /// 定位高亮（§7.2：点通知 / 编辑规则跳转后高亮目标行）。
  final bool highlight;

  /// 选择模式（多选，§10#23）：左侧编号位换成圆形勾选、整行可勾选。
  /// [selected] 只在 [selecting] 为真时有意义。
  final bool selecting;
  final bool selected;

  const TaskTile({
    super.key,
    required this.controller,
    required this.task,
    this.number,
    this.onTap,
    this.onLongPress,
    this.dimmed = false,
    this.trailing,
    this.highlight = false,
    this.selecting = false,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final metric = controller.schedule?.metricOf(task.id);
    final overdue = task.deadline != null &&
        task.deadline!.isBefore(DateTime.now()) &&
        !task.isCompleted;
    final firstNoteLine = task.description.isEmpty
        ? null
        : task.description
            .split('\n')
            .firstWhere((l) => l.trim().isNotEmpty, orElse: () => '');

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      color: selected
          ? AppColors.accent.withValues(alpha: 0.10)
          : dimmed
              ? theme.cardTheme.color?.withValues(alpha: 0.55)
              : null,
      shape: highlight
          ? RoundedRectangleBorder(
              side: BorderSide(color: AppColors.accent, width: 1.6),
              borderRadius: BorderRadius.circular(14),
            )
          : null,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 12, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (selecting) ...[
                _SelectMark(selected: selected),
                const SizedBox(width: 10),
              ] else if (number != null) ...[
                SizedBox(
                  width: 30,
                  child: Text('$number', style: numberStyle(theme.textTheme)),
                ),
                const SizedBox(width: 8),
              ] else if (overdue) ...[
                _Dot(color: AppColors.overdueFor(theme.brightness)),
                const SizedBox(width: 8),
              ] else if (dimmed) ...[
                const _Dot(color: Colors.blueGrey),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            task.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleMedium
                                ?.copyWith(fontSize: 15),
                          ),
                        ),
                        ..._badges(context, metric, overdue),
                      ],
                    ),
                    if (firstNoteLine != null &&
                        firstNoteLine.trim().isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        firstNoteLine,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: 6),
                trailing!,
              ],
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _badges(BuildContext context, TaskMetric? metric, bool overdue) {
    final badges = <Widget>[];
    final deadline = task.deadline;
    if (task.type == TaskType.fixed && deadline != null) {
      badges.add(_Badge(label: fmtTime(deadline), color: AppColors.timeBadge));
    } else if (overdue) {
      badges.add(_Badge(
          label: '已逾期',
          color: AppColors.overdueFor(Theme.of(context).brightness)));
    } else if (metric?.displayStatus == TaskDisplayStatus.infeasible) {
      badges.add(_Badge(
          label: '裕度告急',
          color: AppColors.overdueFor(Theme.of(context).brightness)));
    } else if (metric?.displayStatus == TaskDisplayStatus.snoozed ||
        (controller.isManualSort && task.status == TaskStatus.snoozed)) {
      // 无排序档没有 metric（不跑调度），snooze 只能从任务自身的状态看。
      badges.add(const _Badge(label: '已推迟', color: Colors.blueGrey));
    } else if (task.pinnedAt != null) {
      badges.add(_Badge(label: '插队', color: AppColors.accent));
    }
    // '长期'任务没有剩余工时可标（D18）：徽标不显示，详情卡里说明。
    // 无排序档不问工时——那个剩余量是缺省 30 分钟，标出来等于把隐藏值露给用户。
    final remaining = task.remainingWork;
    if (task.type == TaskType.flex &&
        remaining != null &&
        remaining > 0 &&
        !controller.isManualSort) {
      badges.add(_Badge(
        label: '$remaining分',
        color: Colors.blueGrey,
        soft: true,
      ));
    }
    return badges;
  }
}

/// 选择模式下的勾选圈（替代编号位，§10#23）：选中填强调色 + 白勾。
class _SelectMark extends StatelessWidget {
  final bool selected;

  const _SelectMark({required this.selected});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected ? AppColors.accent : Colors.transparent,
        border: Border.all(
          color: selected
              ? AppColors.accent
              : theme.colorScheme.outlineVariant,
          width: 1.6,
        ),
      ),
      child: selected
          ? const Icon(Icons.check, size: 14, color: Colors.white)
          : null,
    );
  }
}

class _Dot extends StatelessWidget {
  final Color color;
  const _Dot({required this.color});

  @override
  Widget build(BuildContext context) => Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      );
}

/// 橙色系徽标：只给关键元素（§8）。
class _Badge extends StatelessWidget {
  final String label;
  final Color color;
  final bool soft;

  const _Badge({required this.label, required this.color, this.soft = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: soft ? null : color.withValues(alpha: 0.14),
        border: soft ? Border.all(color: color.withValues(alpha: 0.4)) : null,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(label, style: TextStyle(color: color, fontSize: 11.5)),
    );
  }
}

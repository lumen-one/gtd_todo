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
      color: dimmed ? theme.cardTheme.color?.withValues(alpha: 0.55) : null,
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
              if (number != null) ...[
                SizedBox(
                  width: 30,
                  child: Text('$number', style: numberStyle(theme.textTheme)),
                ),
                const SizedBox(width: 8),
              ] else if (overdue) ...[
                const _Dot(color: AppColors.overdue),
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
      badges.add(const _Badge(label: '已逾期', color: AppColors.overdue));
    } else if (metric?.displayStatus == TaskDisplayStatus.infeasible) {
      badges.add(const _Badge(label: '裕度告急', color: AppColors.overdue));
    } else if (metric?.displayStatus == TaskDisplayStatus.snoozed) {
      badges.add(const _Badge(label: '已推迟', color: Colors.blueGrey));
    } else if (task.pinnedAt != null) {
      badges.add(_Badge(label: '插队', color: AppColors.accent));
    }
    if (task.type == TaskType.flex && task.remainingWork > 0) {
      badges.add(_Badge(
        label: '${task.remainingWork}分',
        color: Colors.blueGrey,
        soft: true,
      ));
    }
    return badges;
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

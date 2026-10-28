import 'package:flutter/material.dart';

import '../../domain/schedule.dart';
import '../../domain/task.dart';
import '../app_controller.dart';
import '../theme.dart';

String _two(int n) => n.toString().padLeft(2, '0');

String fmtTime(DateTime d) => '${_two(d.hour)}:${_two(d.minute)}';

String fmtDateTime(DateTime d) =>
    '${d.month}-${_two(d.day)} ${_two(d.hour)}:${_two(d.minute)}';

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// 行尾那一签与详情卡共用的"什么时候"文案。
///
/// [compact] = 列表行上那一签：同一天只给时刻（整页本来就在说今天），**不同天
/// 只给日期**——`10-30 18:00` 在 240dp 的行上要吃掉四十多 dp，挤掉的是标题；
/// 而跨日的件真正要问的是"哪天"，几点在详情卡里看。详情卡不透传 [compact]，
/// 所以那边同一天写成"今天"、次日写成"明天"，时刻始终带着。
/// 跨年才补两位年：写满四位在行上占掉的宽度够写一个词。
String fmtWhen(DateTime d, {DateTime? now, bool compact = false}) {
  final at = now ?? DateTime.now();
  final clock = fmtTime(d);
  if (_sameDay(d, at)) return compact ? clock : '今天 $clock';
  if (compact) return fmtDay(d, now: at);
  if (_sameDay(d, DateTime(at.year, at.month, at.day + 1))) return '明天 $clock';
  return '${fmtDay(d, now: at)} $clock';
}

/// 任务池那一签：只给日期，**不给时刻**——那一页问的是"哪天轮到我"。
String fmtDay(DateTime d, {DateTime? now}) {
  final at = now ?? DateTime.now();
  return d.year == at.year
      ? '${d.month}-${_two(d.day)}'
      : '${_two(d.year % 100)}-${_two(d.month)}-${_two(d.day)}';
}

/// 行尾那一签报什么（§8 的时间签 / 日期签）。
///
/// [none] 是其余三处（日历弹窗传 [time]）：已完成、支线各自的行另有表达，
/// 不给签也不丢信息。
enum TileTrail {
  none,

  /// 今日清单：`18:00` / `明天 14:30` / `10-30 18:00`。
  time,

  /// 任务池：`10-28`。
  date,
}

/// 任务行（今日清单 / 任务池 / 日历共用）：编号大而醒目（橙）、标题为主文案、
/// 备注弱化、右端一签报时间（§8）。
///
/// 右端只有一签：今日清单给时刻、任务池给日期。颜色取日历那套点色板
/// （开始型与例行 = 开始色，截止型 = 截止色），逾期件整条转逾期橙红——
/// 同一件事在日历格子与清单行上同色，人才认得出是同一种"开始"或"截止"。
class TaskTile extends StatelessWidget {
  final AppController controller;
  final Task task;

  /// 连续编号；null = 无编号（逾期组 / 被挑散件）。
  final int? number;

  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool dimmed; // 被挑散件弱化呈现（决议 25）
  final Widget? trailing; // 拖拽把手等插槽

  /// 行尾那一签（[TileTrail]）：今日清单传 [TileTrail.time]，任务池传
  /// [TileTrail.date]，其余页不传。
  final TileTrail trail;

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
    this.trail = TileTrail.none,
    this.highlight = false,
    this.selecting = false,
    this.selected = false,
  });

  /// 逾期：过点未完成。① 组整组都是它，行内靠左侧红点 + 时间签转色表达，
  /// 不再叠一颗『已逾期』胶囊。
  bool get _overdue =>
      task.deadline != null &&
      task.deadline!.isBefore(DateTime.now()) &&
      !task.isCompleted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final metric = controller.schedule?.metricOf(task.id);
    final firstNoteLine = task.description.isEmpty
        ? null
        : task.description
            .split('\n')
            .firstWhere((l) => l.trim().isNotEmpty, orElse: () => '');
    final whenTag = _trail(context);

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
              ] else if (_overdue) ...[
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
                        ..._badges(theme, metric),
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
              if (whenTag != null) ...[
                const SizedBox(width: 6),
                whenTag,
              ],
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

  /// 行尾那一签：色点 + 文案，颜色见类注释。没有截止（长期任务、三无散件）
  /// 就没有签——宁可不报，也不拿创建时间冒充。
  Widget? _trail(BuildContext context) {
    final deadline = task.deadline;
    if (trail == TileTrail.none || deadline == null) return null;
    final color = trailColor(context, task);
    final label = trail == TileTrail.date
        ? fmtDay(deadline)
        : fmtWhen(deadline, compact: true);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 5),
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: color,
            fontWeight: FontWeight.w600,
            // 等宽数字：各行时间才竖着对得齐（列表里最容易被读的一列）。
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }

  /// 只留两颗状态胶囊（§8）：裕度告急（标准 / 完整档算出来的）、已推迟。
  /// 逾期件不再叠徽标——组头、左侧红点、时间签颜色已经各说了一遍。
  List<Widget> _badges(ThemeData theme, TaskMetric? metric) {
    if (_overdue) return const [];
    final infeasible = metric?.displayStatus == TaskDisplayStatus.infeasible;
    // 无排序档没有 metric（不跑调度），snooze 只能从任务自身的状态看。
    final snoozed = metric?.displayStatus == TaskDisplayStatus.snoozed ||
        (controller.isManualSort && task.status == TaskStatus.snoozed);
    if (infeasible) {
      return [
        _Badge(label: '裕度告急', color: AppColors.overdueFor(theme.brightness)),
      ];
    }
    if (snoozed) return [const _Badge(label: '已推迟', color: Colors.blueGrey)];
    // 工时与『插队』不进列表行（决议见 2026-10-28 卡片）：插队由位置表达，
    // 工时在编辑表单里看。
    return const [];
  }
}

/// 那一签的颜色：逾期压过类型，其余按类型取日历点色板的开始 / 截止色。
Color trailColor(BuildContext context, Task task) {
  final theme = Theme.of(context);
  final deadline = task.deadline;
  if (deadline != null &&
      deadline.isBefore(DateTime.now()) &&
      !task.isCompleted) {
    return AppColors.overdueFor(theme.brightness);
  }
  final dots = AppColors.preset.dotsFor(theme.brightness);
  return task.type == TaskType.flex ? dots.deadline : dots.start;
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

/// 状态胶囊：只给需要当场反应的两颗（裕度告急 / 已推迟）。
class _Badge extends StatelessWidget {
  final String label;
  final Color color;

  const _Badge({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(label, style: TextStyle(color: color, fontSize: 11.5)),
    );
  }
}

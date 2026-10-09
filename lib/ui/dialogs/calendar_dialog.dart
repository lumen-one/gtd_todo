import 'package:flutter/material.dart';

import '../../domain/routine.dart';
import '../../domain/task.dart';
import '../app_controller.dart';
import '../theme.dart';
import '../widgets/task_tile.dart';
import 'create_task_dialog.dart' show pickDateTime;
import 'routine_edit_dialog.dart' show routineSubtitle;

const List<String> _weekLabels = ['一', '二', '三', '四', '五', '六', '日'];

/// 日历弹窗（ui-interaction.md §6.4）：
/// - 月历，有任务的日子打点；
/// - 点某天 → 当天列表从弹窗底部下滑展开（同一弹窗内联动，不叠层）；
/// - 当天列表里可改任务日期，改完调度自动重锚（决议 24：例行实例只读、
///   散件无日期不进日历——例行未落地前无需处理）。
Future<void> showCalendarDialog(
    BuildContext context, AppController controller) {
  return showDialog<void>(
    context: context,
    builder: (_) => _CalendarDialog(controller: controller),
  );
}

class _CalendarDialog extends StatefulWidget {
  final AppController controller;

  const _CalendarDialog({required this.controller});

  @override
  State<_CalendarDialog> createState() => _CalendarDialogState();
}

class _CalendarDialogState extends State<_CalendarDialog> {
  late DateTime _month;
  int? _selectedDay;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _month = DateTime(now.year, now.month);
  }

  List<Task> _tasksOf(DateTime day) {
    return widget.controller.tasks
        .where((t) =>
            !t.isCompleted &&
            t.deadline != null &&
            t.deadline!.year == day.year &&
            t.deadline!.month == day.month &&
            t.deadline!.day == day.day)
        .toList()
      ..sort((a, b) => a.deadline!.compareTo(b.deadline!));
  }

  /// 例行实例/规则在这一天的发生（决议 24：在其发生日打点、只读）。
  List<RoutineOccurrence> _routinesOf(DateTime day) =>
      widget.controller.occurrencesOn(day);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final first = DateTime(_month.year, _month.month);
    // 周一为一周开始
    final lead = (first.weekday + 6) % 7;
    final daysInMonth = DateTime(_month.year, _month.month + 1, 0).day;
    final today = DateTime.now();
    final isThisMonth = _month.year == today.year && _month.month == today.month;

    final cells = <Widget>[
      for (final w in _weekLabels)
        Center(
          child: Text(w,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ),
      for (var i = 0; i < lead; i++) const SizedBox(),
      for (var d = 1; d <= daysInMonth; d++)
        _DayCell(
          day: d,
          isToday: isThisMonth && d == today.day,
          selected: _selectedDay == d,
          marked: _tasksOf(DateTime(_month.year, _month.month, d)).isNotEmpty ||
              _routinesOf(DateTime(_month.year, _month.month, d)).isNotEmpty,
          onTap: () => setState(() => _selectedDay = d),
        ),
    ];

    return Dialog(
      backgroundColor: theme.cardTheme.color,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.78,
          maxWidth: 420,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => setState(() {
                      _month = DateTime(_month.year, _month.month - 1);
                      _selectedDay = null;
                    }),
                    icon: const Icon(Icons.chevron_left),
                  ),
                  Expanded(
                    child: Center(
                      child: Text(
                        '${_month.year} 年 ${_month.month} 月',
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => setState(() {
                      _month = DateTime(_month.year, _month.month + 1);
                      _selectedDay = null;
                    }),
                    icon: const Icon(Icons.chevron_right),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
              child: GridView.count(
                crossAxisCount: 7,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                childAspectRatio: 1.15,
                mainAxisSpacing: 2,
                children: cells,
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: AnimatedSize(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                alignment: Alignment.topCenter,
                child: _selectedDay == null
                    ? Padding(
                        padding: const EdgeInsets.all(14),
                        child: Text('点某一天看当天安排',
                            style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant)),
                      )
                    : _DayList(
                        day: DateTime(_month.year, _month.month, _selectedDay!),
                        controller: widget.controller,
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DayCell extends StatelessWidget {
  final int day;
  final bool isToday;
  final bool selected;
  final bool marked;
  final VoidCallback onTap;

  const _DayCell({
    required this.day,
    required this.isToday,
    required this.selected,
    required this.marked,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: selected
                  ? AppColors.accent
                  : isToday
                      ? AppColors.accent.withValues(alpha: 0.16)
                      : null,
            ),
            child: Text(
              '$day',
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: selected || isToday ? FontWeight.w700 : null,
                color: selected ? Colors.white : null,
              ),
            ),
          ),
          const SizedBox(height: 2),
          Container(
            width: 5,
            height: 5,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: marked ? AppColors.accent : Colors.transparent,
            ),
          ),
        ],
      ),
    );
  }
}

class _DayList extends StatelessWidget {
  final DateTime day;
  final AppController controller;

  const _DayList({required this.day, required this.controller});

  @override
  Widget build(BuildContext context) {
    final tasks = controller.tasks
        .where((t) =>
            !t.isCompleted &&
            t.type != TaskType.routine &&
            t.deadline != null &&
            t.deadline!.year == day.year &&
            t.deadline!.month == day.month &&
            t.deadline!.day == day.day)
        .toList()
      ..sort((a, b) => a.deadline!.compareTo(b.deadline!));

    // 决议 24：例行在其发生日打点、只读（点开跳『编辑规则』）。
    final occurrences = controller.occurrencesOn(day);

    if (tasks.isEmpty && occurrences.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(14),
        child: Text('这一天没有安排',
            style: Theme.of(context).textTheme.bodySmall),
      );
    }

    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 12),
      children: [
        for (final o in occurrences)
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            child: ListTile(
              dense: true,
              leading:
                  Icon(Icons.repeat, size: 18, color: AppColors.accent),
              title: Text(o.routine.title, maxLines: 1,
                  overflow: TextOverflow.ellipsis),
              subtitle: Text(routineSubtitle(o.routine)),
              trailing: const Text('例行', style: TextStyle(fontSize: 11.5)),
              onTap: () async {
                Navigator.of(context).pop();
                controller.focusRoutineInSettings(o.routine.id);
              },
            ),
          ),
        for (final t in tasks)
          TaskTile(
            controller: controller,
            task: t,
            onTap: () async {
              final dt = await pickDateTime(context,
                  initial: t.deadline, title: '改期到哪天？');
              if (dt == null) return;
              await controller.updateTask(t.id, deadline: dt);
            },
          ),
      ],
    );
  }
}

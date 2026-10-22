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
  /// 月历按**月序号**翻页（`2000-01` 记 0）：往前往后都算得出来，
  /// 所以左右滑不到头，不用手写可翻范围。
  static const int _baseYear = 2000;

  late final PageController _pageCtrl;
  late int _page;
  int? _selectedDay;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _page = _monthIndex(DateTime(now.year, now.month));
    _pageCtrl = PageController(initialPage: _page);
  }

  @override
  void dispose() {
    _pageCtrl.dispose();
    super.dispose();
  }

  static int _monthIndex(DateTime m) => (m.year - _baseYear) * 12 + m.month - 1;

  static DateTime _monthAt(int index) =>
      DateTime(_baseYear + index ~/ 12, index % 12 + 1);

  DateTime get _month => _monthAt(_page);

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

  /// 这天有没有安排（任务或例行实例）——日历上的那个点。
  bool _hasItems(DateTime day) =>
      _tasksOf(day).isNotEmpty || _routinesOf(day).isNotEmpty;

  /// 箭头与横滑是同一个动作的两种走法（§6.4）：箭头走相邻一格。
  void _goToMonth(int page) {
    if (!_pageCtrl.hasClients) return;
    _pageCtrl.animateToPage(page,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic);
  }

  /// 一个月的网格：**固定六行**（4 行的月份底部留白）——高度跟着月份变
  /// 会让整块弹窗在滑动中跳（§6.4）。
  Widget _monthGrid(int page, DateTime today) {
    final month = _monthAt(page);
    // 周一为一周开始（`weekday` 里周一 = 1）。
    final lead = (month.weekday + 6) % 7;
    final days = DateTime(month.year, month.month + 1, 0).day;
    final isThisMonth = month.year == today.year && month.month == today.month;
    // 只有当前页认选中：滑动中相邻页同时在树里，不限定的话同号日跟着亮。
    final selected = page == _page ? _selectedDay : null;

    return Column(
      children: [
        for (var row = 0; row < 6; row++)
          Expanded(
            child: Row(
              children: [
                for (var col = 0; col < 7; col++)
                  Expanded(
                    child: _cellFor(
                      dayNumber: row * 7 + col - lead + 1,
                      daysInMonth: days,
                      month: month,
                      today: today,
                      isThisMonth: isThisMonth,
                      selected: selected,
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _cellFor({
    required int dayNumber,
    required int daysInMonth,
    required DateTime month,
    required DateTime today,
    required bool isThisMonth,
    required int? selected,
  }) {
    if (dayNumber < 1 || dayNumber > daysInMonth) {
      return const SizedBox.shrink();
    }
    final day = DateTime(month.year, month.month, dayNumber);
    return _DayCell(
      day: dayNumber,
      isToday: isThisMonth && dayNumber == today.day,
      selected: selected == dayNumber,
      marked: _hasItems(day),
      onTap: () => setState(() => _selectedDay = dayNumber),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final today = DateTime.now();

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
                    onPressed: () => _goToMonth(_page - 1),
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
                    onPressed: () => _goToMonth(_page + 1),
                    icon: const Icon(Icons.chevron_right),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  // 格子宽度由面板宽度定，高度按老比例（宽:高 = 1.15）推，
                  // 六行总高就是月历区的高度。
                  final cellH = constraints.maxWidth / 7 / 1.15;
                  return Column(
                    children: [
                      Row(
                        children: [
                          for (final w in _weekLabels)
                            Expanded(
                              child: Center(
                                child: Text(w,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                        color: theme
                                            .colorScheme.onSurfaceVariant)),
                              ),
                            ),
                        ],
                      ),
                      SizedBox(
                        height: cellH * 6,
                        child: PageView.builder(
                          controller: _pageCtrl,
                          // 切月清空当天选中（§6.4）：展开的当天列表收回去。
                          onPageChanged: (page) => setState(() {
                            _page = page;
                            _selectedDay = null;
                          }),
                          itemBuilder: (context, page) =>
                              _monthGrid(page, today),
                        ),
                      ),
                    ],
                  );
                },
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
            // 28 + 1 + 4 = 33dp：窄屏（320dp 宽时格子高约 37dp）也放得下，
            // 固定六行网格不会因此溢出。
            width: 28,
            height: 28,
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
          const SizedBox(height: 1),
          Container(
            width: 4,
            height: 4,
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

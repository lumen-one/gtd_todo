import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/routine.dart';
import '../../domain/task.dart';
import '../app_controller.dart';
import '../theme.dart';
import '../widgets/task_tile.dart';
import 'date_pick.dart' show pickDateTime;
import 'routine_edit_dialog.dart' show routineSubtitle;

const List<String> _weekLabels = ['一', '二', '三', '四', '五', '六', '日'];

/// 月历之外还要摆下的高度：页头 + 星期行 + 分隔线 + 输入行，再加当天列表最小的
/// 可见高度。键盘抬起后可用高度变小，格子尺寸按它再夹一道（`build` 里的 LayoutBuilder）。
const double _kNonGridHeight = 200;

/// 长按某天加进来的任务落在当天 18:00——与新建对话框里『今天 / 明天』同一档。
const int _kNewTaskHour = 18;

/// 输入行尾那两颗按钮：M3 默认 48dp 见方，一行里横向吃掉近 100dp；收到 34dp。
final ButtonStyle _compactIcon = IconButton.styleFrom(
  minimumSize: const Size(34, 34),
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  padding: EdgeInsets.zero,
);

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// 某一天的任务，按截止时刻排。
///
/// [completed] 选已完成 / 未完成；[noRoutine] 去掉周期实例（当天列表里那些由
/// 例行规则单独画，月历的点不筛，例行实例与规则发生各算各的）。
///
/// 日期不设下限：已经过去的那些天，干完的活照样留在它到期的那一天——翻回去
/// 要看得见那天做了什么。
List<Task> _tasksOn(
  List<Task> all,
  DateTime day, {
  required bool completed,
  required bool noRoutine,
}) {
  return all
      .where((t) =>
          t.isCompleted == completed &&
          (!noRoutine || t.type != TaskType.routine) &&
          t.deadline != null &&
          _sameDay(t.deadline!, day))
      .toList()
    ..sort((a, b) => a.deadline!.compareTo(b.deadline!));
}

/// 日历弹窗（ui-interaction.md §6.4）：
/// - 月历，有安排的日子打点：橙 = 还有没干完的，蓝 = 已经干完的；
/// - 点某天 → 当天列表从弹窗底部下滑展开（同一弹窗内联动，不叠层）；
/// - **长按某天** → 顶部升起一行输入，回车即在那天落一件（截止型 + 有截止）；
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

  /// 当天列表顶部那行输入框是否升起（长按某天进来，加完或取消就收）。
  bool _adding = false;

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

  /// 这天还没干完的活。
  List<Task> _openOf(DateTime day) =>
      _tasksOn(widget.controller.tasks, day, completed: false, noRoutine: false);

  /// 这天**已经干完**的活。过去的那些天也照画——翻回去要看得见那天做了什么。
  List<Task> _doneOf(DateTime day) =>
      _tasksOn(widget.controller.tasks, day, completed: true, noRoutine: false);

  /// 例行实例/规则在这一天的发生（决议 24：在其发生日打点、只读）。
  List<RoutineOccurrence> _routinesOf(DateTime day) =>
      widget.controller.occurrencesOn(day);

  /// 橙点：这天还欠活（任务或例行实例）。
  bool _hasOpen(DateTime day) =>
      _openOf(day).isNotEmpty || _routinesOf(day).isNotEmpty;

  /// 蓝点：这天有已经干完的。
  bool _hasDone(DateTime day) => _doneOf(day).isNotEmpty;

  /// 箭头与横滑是同一个动作的两种走法（§6.4）：箭头走相邻一格。
  void _goToMonth(int page) {
    if (!_pageCtrl.hasClients) return;
    _pageCtrl.animateToPage(page,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic);
  }

  /// 长按某天：选中它，把输入行升起来（加完停在当天列表，看得见新加的那件）。
  void _beginAdd(int dayNumber) {
    HapticFeedback.selectionClick();
    setState(() {
      _selectedDay = dayNumber;
      _adding = true;
    });
  }

  Future<void> _submitAdd(String title) async {
    final text = title.trim();
    final selected = _selectedDay;
    if (text.isEmpty || selected == null) return;
    final day = DateTime(_month.year, _month.month, selected, _kNewTaskHour);
    setState(() => _adding = false); // 输入行先收，键盘随之落下
    await widget.controller.createTask(
      title: text,
      type: TaskType.flex,
      deadline: day,
    );
    if (!mounted) return;
    setState(() {});
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
      marked: _hasOpen(day),
      doneMarked: _hasDone(day),
      onTap: () => setState(() {
        _selectedDay = dayNumber;
        _adding = false;
      }),
      onLongPress: () => _beginAdd(dayNumber),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final today = DateTime.now();
    final size = MediaQuery.of(context).size;
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    final availableH = size.height - keyboard;

    return Dialog(
      backgroundColor: theme.cardTheme.color,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          // 键盘抬起时按剩下的高度算上限，否则弹窗会被顶出屏幕。
          maxHeight: math.min(size.height * 0.78, availableH - 40),
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
                  // 格子宽度由弹窗宽度定，高度按老比例（宽:高 = 1.15）推，
                  // 六行总高就是月历区的高度。键盘抬起后可用高度不够时再夹
                  // 一道，否则当天列表会被挤没、月历直接顶出弹窗。
                  final cellH = math.min(
                    constraints.maxWidth / 7 / 1.15,
                    (availableH - _kNonGridHeight) / 6,
                  );
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
                            _adding = false;
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
                        child: Text('点某天看安排，长按某天加一件',
                            style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant)),
                      )
                    : _DayList(
                        day: DateTime(_month.year, _month.month, _selectedDay!),
                        controller: widget.controller,
                        adding: _adding,
                        onCreate: _submitAdd,
                        onCancelAdd: () => setState(() => _adding = false),
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

  /// 这天还欠活（橙点）。
  final bool marked;

  /// 这天有已经干完的（蓝点）。两色可同时出现，橙在前。
  final bool doneMarked;

  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _DayCell({
    required this.day,
    required this.isToday,
    required this.selected,
    required this.marked,
    required this.doneMarked,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      onLongPress: onLongPress,
      // 格子矮的时候（窄屏、或键盘抬起把月历压小）整格等比缩小，而不是让
      // 33dp 的内容顶出格子——不然会看到黄黑条。
      child: Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                // 28 + 1 + 4 = 33dp。
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
              SizedBox(
                height: 4,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 选中日整颗圈是强调色填充，橙点贴上去会连成一片——那一格
                    // 不画橙点（下面展开的列表本来就在说这天有什么），蓝点照画。
                    if (marked && !selected) _Pip(color: AppColors.accent),
                    if (doneMarked) ...[
                      if (marked && !selected) const SizedBox(width: 3),
                      _Pip(color: AppColors.doneFor(theme.brightness)),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 日期下面那颗小点（4dp，§6.4 的两色口径）。
class _Pip extends StatelessWidget {
  final Color color;
  const _Pip({required this.color});

  @override
  Widget build(BuildContext context) => Container(
        width: 4,
        height: 4,
        decoration: BoxDecoration(shape: BoxShape.circle, color: color),
      );
}

class _DayList extends StatelessWidget {
  final DateTime day;
  final AppController controller;

  /// 顶部输入行是否升起（长按某天进来）。
  final bool adding;
  final ValueChanged<String> onCreate;
  final VoidCallback onCancelAdd;

  const _DayList({
    required this.day,
    required this.controller,
    required this.adding,
    required this.onCreate,
    required this.onCancelAdd,
  });

  @override
  Widget build(BuildContext context) {
    final tasks = _tasksOn(controller.tasks, day,
        completed: false, noRoutine: true);
    // 已完成件排末尾、不可点（与月历蓝点同一条口径，不按今天划线）。
    final done = _tasksOn(controller.tasks, day,
        completed: true, noRoutine: true);

    // 决议 24：例行在其发生日打点、只读（点开跳『编辑规则』）。
    final occurrences = controller.occurrencesOn(day);

    if (tasks.isEmpty && done.isEmpty && occurrences.isEmpty) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (adding) _AddRow(day: day, onSubmit: onCreate, onCancel: onCancelAdd),
          if (!adding)
            Padding(
              padding: const EdgeInsets.all(14),
              child: Text('这一天没有安排',
                  style: Theme.of(context).textTheme.bodySmall),
            ),
        ],
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (adding) _AddRow(day: day, onSubmit: onCreate, onCancel: onCancelAdd),
        // 条目多了要能滚：输入行吃掉的高度不能让列表溢出（弹窗高度有上限）。
        Flexible(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 12),
            children: [
              for (final o in occurrences)
                Card(
                  margin: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 3),
                  child: ListTile(
                    dense: true,
                    leading:
                        Icon(Icons.repeat, size: 18, color: AppColors.accent),
                    title: Text(o.routine.title, maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                    subtitle: Text(routineSubtitle(o.routine)),
                    trailing:
                        const Text('例行', style: TextStyle(fontSize: 11.5)),
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
              for (final t in done) _DoneRow(task: t),
            ],
          ),
        ),
      ],
    );
  }
}

/// 当天列表顶部那一行：敲标题、回车即落账（§6.4）。左侧标着落在哪一天，
/// 免得长按错了一天却不知道落去了哪里。
class _AddRow extends StatefulWidget {
  final DateTime day;
  final ValueChanged<String> onSubmit;
  final VoidCallback onCancel;

  const _AddRow({
    required this.day,
    required this.onSubmit,
    required this.onCancel,
  });

  @override
  State<_AddRow> createState() => _AddRowState();
}

class _AddRowState extends State<_AddRow> {
  final _ctrl = TextEditingController();
  final _focus = FocusNode();

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _submit() => widget.onSubmit(_ctrl.text);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final d = widget.day;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 0),
      child: Row(
        children: [
          Text(
            '${d.month}-${d.day.toString().padLeft(2, '0')}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _ctrl,
              focusNode: _focus,
              autofocus: true,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(),
              decoration: const InputDecoration(
                isDense: true,
                hintText: '加一件，回车确认',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          IconButton(
            tooltip: '取消',
            visualDensity: VisualDensity.compact,
            style: _compactIcon,
            icon: const Icon(Icons.close, size: 18),
            onPressed: widget.onCancel,
          ),
          IconButton(
            tooltip: '加在这一天',
            visualDensity: VisualDensity.compact,
            style: _compactIcon,
            icon: const Icon(Icons.check),
            onPressed: _submit,
          ),
        ],
      ),
    );
  }
}

/// 当天列表里的已完成件：勾 + 删除线 + "已完成"，**不可点**——改期对已经
/// 干完的活没有意义，要恢复去已完成页。
class _DoneRow extends StatelessWidget {
  final Task task;

  const _DoneRow({required this.task});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = AppColors.doneFor(theme.brightness);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 12, 8),
        child: Row(
          children: [
            Icon(Icons.check_circle, size: 16, color: color),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                task.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontSize: 15,
                  fontWeight: FontWeight.w400,
                  color: theme.colorScheme.onSurfaceVariant,
                  decoration: TextDecoration.lineThrough,
                  decorationColor: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(width: 6),
            Text('已完成', style: TextStyle(fontSize: 11.5, color: color)),
          ],
        ),
      ),
    );
  }
}

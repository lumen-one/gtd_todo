import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/routine.dart';
import '../../domain/task.dart';
import '../app_controller.dart';
import '../theme.dart';
import '../widgets/month_calendar.dart';
import '../widgets/task_actions.dart';
import '../widgets/task_tile.dart';
import 'date_pick.dart' show pickDateTime;
import 'routine_edit_dialog.dart' show routineSubtitle;

/// 六行网格之外还要摆下的高度：组件自己的页头与星期行、分隔线、输入行，再加
/// 当天列表最小的可见高度。键盘抬起后可用高度变小，网格按它再夹一道
/// （`build` 里传给 [MonthCalendar.gridMaxHeight]）。
const double _kNonGridHeight = 200;

/// 长按某天加进来的任务落在当天 18:00——与新建流程里截止型的默认时刻同一档。
const int _kNewTaskHour = 18;

/// 输入行尾那两颗按钮：M3 默认 48dp 见方，一行里横向吃掉近 100dp；收到 34dp。
final ButtonStyle _compactIcon = IconButton.styleFrom(
  minimumSize: const Size(34, 34),
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  padding: EdgeInsets.zero,
);

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
          sameDay(t.deadline!, day))
      .toList()
    ..sort((a, b) => a.deadline!.compareTo(b.deadline!));
}

/// 日历弹窗（ui-interaction.md §6.4）：
/// - 月历，有安排的日子打点：开始型 / 截止型 / 已经干完的三种点，色值随主题预设走
///   （§8 的日历点色板），一天最多三点；
/// - 点某天 → 当天列表从弹窗底部下滑展开（同一弹窗内联动，不叠层）；
/// - **长按某天** → 顶部升起一行输入，回车即在那天落一件（截止型 + 有截止）；
/// - 当天列表里**点条目改期**、**长按条目开菜单**（完成 / 推迟 / 编辑 / 删除，
///   编辑走与别处同一张表单），改完调度自动重锚（决议 24：例行实例只读、
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
  DateTime? _selected;

  /// 当天列表顶部那行输入框是否升起（长按某天进来，加完或取消就收）。
  bool _adding = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    super.dispose();
  }

  /// 弹窗是独立路由，不随侧边栏重建：任务在里面被改（改期、菜单里的完成 / 编辑 /
  /// 删除）之后，当天列表与月历上的点都得自己跟一次。
  void _onChanged() {
    if (mounted) setState(() {});
  }

  /// 这天还没干完的活。
  List<Task> _openOf(DateTime day) =>
      _tasksOn(widget.controller.tasks, day, completed: false, noRoutine: false);

  /// 这天**已经干完**的活。过去的那些天也照画——翻回去要看得见那天做了什么。
  List<Task> _doneOf(DateTime day) =>
      _tasksOn(widget.controller.tasks, day, completed: true, noRoutine: false);

  /// 例行实例/规则在这一天的发生（决议 24：在其发生日打点、只读）。
  List<RoutineOccurrence> _routinesOf(DateTime day) =>
      widget.controller.occurrencesOn(day);

  /// 开始点：这天有开始型的活欠着。例行实例的发生也算——它同样是个"时刻开始"。
  bool _hasStart(DateTime day) =>
      _routinesOf(day).isNotEmpty ||
      _openOf(day).any((t) => t.type != TaskType.flex);

  /// 截止点：这天有截止型的活欠着，得在这天收尾。
  bool _hasDeadline(DateTime day) =>
      _openOf(day).any((t) => t.type == TaskType.flex);

  /// 完成点：这天有已经干完的，不分类型。
  bool _hasDone(DateTime day) => _doneOf(day).isNotEmpty;

  DayDots _dotsOf(DateTime day) => DayDots(
        start: _hasStart(day),
        deadline: _hasDeadline(day),
        done: _hasDone(day),
      );

  /// 长按某天：选中它，把输入行升起来（加完停在当天列表，看得见新加的那件）。
  void _beginAdd(DateTime day) {
    HapticFeedback.selectionClick();
    setState(() {
      _selected = day;
      _adding = true;
    });
  }

  Future<void> _submitAdd(String title) async {
    final text = title.trim();
    final day = _selected;
    if (text.isEmpty || day == null) return;
    setState(() => _adding = false); // 输入行先收，键盘随之落下
    await widget.controller.createTask(
      title: text,
      type: TaskType.flex,
      deadline: DateTime(day.year, day.month, day.day, _kNewTaskHour),
    );
    if (!mounted) return;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
            MonthCalendar(
              selected: _selected,
              dots: _dotsOf,
              onPick: (day) => setState(() {
                _selected = day;
                _adding = false;
              }),
              onLongPress: _beginAdd,
              // 切月清空当天选中（§6.4）：展开的当天列表收回去。
              onMonthChanged: (_) => setState(() {
                _selected = null;
                _adding = false;
              }),
              gridMaxHeight: availableH - _kNonGridHeight,
            ),
            const Divider(height: 1),
            Flexible(
              child: AnimatedSize(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                alignment: Alignment.topCenter,
                child: _selected == null
                    ? Padding(
                        padding: const EdgeInsets.all(14),
                        child: Text('点某天看安排，长按某天加一件',
                            style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant)),
                      )
                    : _DayList(
                        day: _selected!,
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
    // 已完成件排末尾、不可点（与月历完成点同一条口径，不按今天划线）。
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
                  // 当天列表里时间才是新信息（日期整页都在说）——同款时间签。
                  trail: TileTrail.time,
                  onTap: () async {
                    final dt = await pickDateTime(context,
                        initial: t.deadline, title: '改期到哪天？');
                    if (dt == null) return;
                    await controller.updateTask(t.id, deadline: dt);
                  },
                  // 点按是改期（这一页的主动作），长按才给其余动作：完成 / 推迟 /
                  // 编辑 / 删除。日历里没有"最前"这个序，所以菜单里也不给插队。
                  onLongPress: () =>
                      showTaskMenu(context, controller, t,
                          kind: TaskMenuKind.calendar),
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
    // 勾用日历上那颗完成色（3.6:1，图形元素够用）；"已完成"三个字仍取正文灰——
    // 11.5px 的文字要 4.5:1，完成色那档偏淡。
    final done = AppColors.preset.dotsFor(theme.brightness).done;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 12, 8),
        child: Row(
          children: [
            Icon(Icons.check_circle, size: 16, color: done),
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
            Text('已完成',
                style: TextStyle(
                    fontSize: 11.5, color: theme.colorScheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}

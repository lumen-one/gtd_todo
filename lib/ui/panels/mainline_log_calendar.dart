import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../domain/mainline.dart';
import '../app_controller.dart';
import '../theme.dart';

const List<String> _weekLabels = ['一', '二', '三', '四', '五', '六', '日'];

/// 主线『记录』页（ui-interaction.md §6.9）：**log 的展现形式就是这个日历**。
///
/// - 每天格子里只放日期数字；有内容（勾过步骤 / 圈覆盖）的日子下留一个小点；
/// - **按住某天拖到另一天** → 松手写文字 → 这一段被一个圆角圈框住，文字在圈里；
/// - 点某一天 → 下方列当天的自动流水（几点勾了哪一步）与覆盖它的圈；
/// - **月头那行年月是视图开关**：点它把上半区换成这一年的十二行月记（一个月一句），
///   再点切回日历。月记不覆盖任何一天，所以它不进格子、也不进当天详情
///   （`docs/decisions/2026-10-25-mainline-month-note.md`）。
///
/// 手势全部走一个 [Listener] + 几何换算（行高 = 可用高/周数、列宽 = 宽/7）：
/// 日历放在**不滚动的**区域里，纵向拖动不会被外面的列表抢走——跨周圈选要的
/// 就是这条。放不下时压缩行高、每行最多画三条圈，更多的从当天详情里看。
///
/// 横滑按区域分工：**日历里 = 圈日期**（这里不能让给翻页），
/// **下半区（当天详情 / 空提示）= 翻页**（向右滑回行为链，见 [onSwipeBack]）。
/// 月记模式下没有日历可圈，整块列表都归翻页那条手势。
class MainlineLogCalendar extends StatefulWidget {
  final AppController controller;
  final Mainline mainline;
  final bool readOnly;

  /// 下半区向右滑 → 回行为链页（覆盖页用 PageController 翻回去）。
  final VoidCallback? onSwipeBack;

  const MainlineLogCalendar({
    super.key,
    required this.controller,
    required this.mainline,
    this.readOnly = false,
    this.onSwipeBack,
  });

  @override
  State<MainlineLogCalendar> createState() => _MainlineLogCalendarState();
}

class _MainlineLogCalendarState extends State<MainlineLogCalendar> {
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);
  DateTime? _selected;

  /// 上半区是月历还是月记列表（点月头那行年月切换）。
  bool _monthView = false;

  DateTime? _dragAnchor;
  DateTime? _dragCursor;
  bool _dragging = false;
  Offset? _downAt;

  @override
  void didUpdateWidget(covariant MainlineLogCalendar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 换了一条主线（归档后看另一条）：选中日与拖动态归零
    if (oldWidget.mainline.id != widget.mainline.id) {
      _selected = null;
      _dragAnchor = null;
      _dragCursor = null;
      _dragging = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        _monthHeader(theme),
        if (_monthView)
          // 月记没有日历可圈，整块列表让给"右滑回行为链"那条手势。
          Expanded(child: _swipeBackLayer(_buildMonthList(theme)))
        else ...[
          const SizedBox(height: 2),
          _weekdayRow(theme),
          Expanded(
            flex: 3,
            child: LayoutBuilder(builder: (context, box) {
              final layout = _Layout.of(
                  _month, box.maxWidth, box.maxHeight, widget.mainline);
              return _buildGrid(context, theme, layout, box);
            }),
          ),
          const Divider(height: 1),
          Expanded(flex: 2, child: _swipeBackLayer(_buildDayDetail(theme))),
        ],
      ],
    );
  }

  // ---------- 月头 ----------

  double _detailDx = 0;

  /// 下半区（当天详情 / 空提示）向右滑 = 回行为链。
  ///
  /// 日历那块必须留给"拖选日期"，翻页手势只能落在这一半；横向拖动与里面
  /// ListView 的纵向滚动正交，两边不抢手。
  Widget _swipeBackLayer(Widget child) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragStart: (_) => _detailDx = 0,
      onHorizontalDragUpdate: (d) => _detailDx += d.delta.dx,
      onHorizontalDragEnd: (d) {
        final v = d.primaryVelocity ?? 0;
        if (_detailDx > 48 || v > 500) widget.onSwipeBack?.call();
        _detailDx = 0;
      },
      child: child,
    );
  }

  Widget _monthHeader(ThemeData theme) {
    return Row(
      children: [
        _chevron(Icons.chevron_left, () => _step(-1)),
        Expanded(
          child: Center(
            // 这行年月就是视图开关：点它把上半区在月历与月记之间切。
            child: Tooltip(
              message: _monthView ? '回月历' : '按月记',
              child: InkWell(
                onTap: () => setState(() => _monthView = !_monthView),
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 240dp 的窄面板上左右两个箭头 + 这行字本来就贴边，留个省略兜底
                      // （真机上不会触发，测试字体是等宽方块才会）。
                      Flexible(
                        child: Text(
                          _monthView
                              ? '${_month.year} 年'
                              : '${_month.year} 年 ${_month.month} 月',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(Icons.swap_horiz,
                          size: 14,
                          color: theme.colorScheme.onSurfaceVariant),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        _chevron(Icons.chevron_right, () => _step(1)),
      ],
    );
  }

  /// 翻一格：月历翻月，月记翻年（月记列表是一年十二行）。
  void _step(int delta) {
    setState(() {
      _month = _monthView
          ? DateTime(_month.year + delta, _month.month)
          : DateTime(_month.year, _month.month + delta);
      _selected = null;
    });
  }

  Widget _chevron(IconData icon, VoidCallback onTap) => SizedBox(
        width: 32,
        height: 32,
        child: IconButton(
          padding: EdgeInsets.zero,
          iconSize: 18,
          icon: Icon(icon),
          onPressed: onTap,
        ),
      );

  Widget _weekdayRow(ThemeData theme) => Row(
        children: [
          for (final w in _weekLabels)
            Expanded(
              child: Center(
                child: Text(w,
                    style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant)),
              ),
            ),
        ],
      );

  // ---------- 网格 ----------

  Widget _buildGrid(
    BuildContext context,
    ThemeData theme,
    _Layout layout,
    BoxConstraints box,
  ) {
    final cellW = box.maxWidth / 7;
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (e) {
        _downAt = e.localPosition;
        _dragAnchor = layout.dayAt(e.localPosition);
        _dragCursor = _dragAnchor;
        _dragging = false;
      },
      onPointerMove: (e) {
        final anchor = _dragAnchor;
        if (anchor == null) return;
        final at = layout.dayAt(e.localPosition);
        if (at == null) return;
        final down = _downAt;
        if (!_dragging &&
            down != null &&
            (e.localPosition - down).distance > 6) {
          _dragging = true;
        }
        if (_dragging) setState(() => _dragCursor = at);
      },
      onPointerUp: (e) {
        final anchor = _dragAnchor;
        final cursor = _dragCursor;
        final moved = _dragging;
        _dragAnchor = null;
        _dragCursor = null;
        _dragging = false;
        if (anchor == null) return;
        if (moved && cursor != null) {
          final start = anchor.isBefore(cursor) ? anchor : cursor;
          final end = anchor.isBefore(cursor) ? cursor : anchor;
          setState(() {});
          _promptNewLog(start: start, end: end);
          return;
        }
        // 没拖 = 点：落在圈上就改圈，否则选那天
        final week = layout.weekAt(e.localPosition);
        final hit = week == null ? null : layout.bandAt(week, e.localPosition);
        if (hit != null) {
          _promptEditLog(hit.log);
          return;
        }
        final day = layout.dayAt(e.localPosition);
        if (day != null) setState(() => _selected = day);
      },
      onPointerCancel: (_) {
        _dragAnchor = null;
        _dragCursor = null;
        _dragging = false;
      },
      child: SizedBox(
        width: box.maxWidth,
        height: box.maxHeight,
        child: Stack(
          children: [
            for (var w = 0; w < layout.weeks.length; w++)
              Positioned(
                top: layout.weekTop(w),
                left: 0,
                right: 0,
                height: layout.rowH,
                child: _weekStack(context, theme, layout, w, cellW),
              ),
          ],
        ),
      ),
    );
  }

  Widget _weekStack(
    BuildContext context,
    ThemeData theme,
    _Layout layout,
    int weekIndex,
    double cellW,
  ) {
    final week = layout.weeks[weekIndex];
    final children = <Widget>[];

    // 拖选中的临时高亮（铺在日期数字底下）
    if (_dragging) {
      final a = _dragAnchor;
      final b = _dragCursor;
      if (a != null && b != null) {
        final start = a.isBefore(b) ? a : b;
        final end = a.isBefore(b) ? b : a;
        final seg = layout.segmentOf(start, end, weekIndex);
        if (seg != null) {
          children.add(Positioned(
            left: seg.$1 * cellW + 2,
            width: (seg.$2 - seg.$1 + 1) * cellW - 4,
            top: 2,
            height: layout.dateH - 4,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: AppColors.accent.withValues(alpha: 0.22),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ));
        }
      }
    }

    // 日期数字 + 内容小点
    for (var col = 0; col < 7; col++) {
      final day = week.cells[col];
      if (day == null) continue;
      final isToday = isSameDay(day, DateTime.now());
      final selected = _selected != null && isSameDay(day, _selected!);
      final marked = widget.mainline.hasActivityOn(day);
      children.add(Positioned(
        left: col * cellW,
        width: cellW,
        top: 0,
        height: layout.dateH,
        child: Center(
          child: Container(
            width: 22,
            height: 22,
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
              '${day.day}',
              style: theme.textTheme.bodySmall?.copyWith(
                fontSize: 11.5,
                fontWeight: isToday || selected ? FontWeight.w700 : null,
                color: selected ? theme.colorScheme.onPrimary : null,
              ),
            ),
          ),
        ),
      ));
      if (marked) {
        children.add(Positioned(
          left: col * cellW + cellW / 2 - 1.5,
          top: layout.dateH - 5,
          width: 3,
          height: 3,
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.accent.withValues(alpha: 0.85),
            ),
          ),
        ));
      }
    }

    // 圈（按周分段的多日条）
    for (final band in week.bands) {
      if (band.slot >= layout.maxBands) continue;
      children.add(Positioned(
        left: band.startCol * cellW + 1.5,
        width: (band.endCol - band.startCol + 1) * cellW - 3,
        top: layout.dateH + band.slot * layout.bandH,
        height: math.max(layout.bandH - 2, 7),
        child: Container(
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          decoration: BoxDecoration(
            color: AppColors.accent.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: AppColors.accent.withValues(alpha: 0.65),
              width: 1,
            ),
          ),
          child: Text(
            band.text.isEmpty ? '（空）' : band.text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              fontSize: 9.5,
              height: 1.1,
              color: AppColors.accent,
            ),
          ),
        ),
      ));
    }

    // 这一周没画出来的圈：右上角 +N（点日期看当天详情）
    final hidden = week.bands.length - layout.maxBands;
    if (hidden > 0 && layout.maxBands > 0) {
      children.add(Positioned(
        right: 2,
        top: layout.dateH + (layout.maxBands - 1) * layout.bandH,
        height: math.max(layout.bandH - 2, 7),
        child: Text('+$hidden',
            style: theme.textTheme.labelSmall?.copyWith(
                fontSize: 9, color: theme.colorScheme.onSurfaceVariant)),
      ));
    }

    return Stack(children: children);
  }

  // ---------- 月记 ----------

  /// 月记：一年十二行，一个月一句。写过的行左侧有圆点，没写的是灰字提示。
  Widget _buildMonthList(ThemeData theme) {
    final year = _month.year;
    return ListView(
      // 不满一屏也要能 overscroll：覆盖页的上滑退出发生在"末尾之后"。
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 14),
      children: [
        for (var m = 1; m <= 12; m++) _monthRow(theme, year, m),
        const SizedBox(height: 10),
        Text(
          '点某个月写一句，一个月只留一条；再点上面的年份回月历',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }

  Widget _monthRow(ThemeData theme, int year, int month) {
    final text = widget.mainline.monthNoteOf(year, month)?.text ?? '';
    final written = text.isNotEmpty;
    final now = DateTime.now();
    final isNow = year == now.year && month == now.month;
    final muted = theme.colorScheme.onSurfaceVariant;
    return InkWell(
      onTap: widget.readOnly ? null : () => _promptMonthNote(year, month),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 9),
        child: Row(
          children: [
            // 写过的行左侧留一个点：与日历格子上那个点是同一个意思。
            SizedBox(
              width: 12,
              child: written
                  ? Center(
                      child: SizedBox(
                        width: 5,
                        height: 5,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: AppColors.accent.withValues(alpha: 0.85),
                          ),
                        ),
                      ),
                    )
                  : null,
            ),
            SizedBox(
              width: 44,
              child: Text(
                '$month 月',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: isNow || written ? FontWeight.w600 : null,
                  color: isNow ? AppColors.accent : null,
                ),
              ),
            ),
            Expanded(
              child: Text(
                written ? text : (widget.readOnly ? '—' : '记一句'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: written ? theme.colorScheme.onSurface : muted,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------- 当天详情 ----------

  Widget _buildDayDetail(ThemeData theme) {
    final day = _selected;
    if (day == null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
        child: Text(
          '点某一天看当天，或按住拖选一段日期写记录；向右滑回行为链',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      );
    }
    final steps = widget.mainline.stepsDoneOn(day);
    final logs = widget.mainline.logsCovering(day);
    return ListView(
      // 不满一屏也要能 overscroll：覆盖页的上滑退出发生在"末尾之后"。
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 12),
      children: [
        Text('${day.month} 月 ${day.day} 日', style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        if (steps.isEmpty && logs.isEmpty)
          Text('这一天没有记录',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        for (final s in steps)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.check_circle,
                    size: 14, color: AppColors.accent.withValues(alpha: 0.8)),
                const SizedBox(width: 6),
                if (s.doneAt != null) ...[
                  Text(_timeText(s.doneAt!),
                      style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)),
                  const SizedBox(width: 6),
                ],
                Expanded(
                  child: Text(
                    s.note.trim().isEmpty ? s.title : '${s.title} · ${s.note}',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
        for (final log in logs)
          InkWell(
            onTap: widget.readOnly ? null : () => _promptEditLog(log),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    margin: const EdgeInsets.only(top: 5),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: AppColors.accent, width: 1.6),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      log.text.trim().isEmpty ? '（这段还没写字）' : log.text,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  static String _timeText(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  // ---------- 写记录 ----------

  Future<void> _promptNewLog({
    required DateTime start,
    required DateTime end,
  }) async {
    if (widget.readOnly) return;
    final outcome = await _textDialog(
      title: '这一段记点什么',
      subtitle: _rangeText(start, end),
      initial: '',
    );
    if (outcome == null) return;
    await widget.controller.addMainlineLog(
      widget.mainline.id,
      start: start,
      end: end,
      text: outcome.text,
    );
  }

  Future<void> _promptEditLog(MainlineLog log) async {
    if (widget.readOnly) return;
    final outcome = await _textDialog(
      title: '改这一段',
      subtitle: _rangeText(log.start, log.end),
      initial: log.text,
      allowDelete: true,
    );
    if (outcome == null) return;
    // 身份取"打开对话框那一刻"的样子：这期间别处把它改了或删了，命令就找不到它、
    // 明确报错——而不是按下标改到另一条上。
    final ref = MainlineLogRef.of(log);
    try {
      if (outcome.deleted) {
        await widget.controller.removeMainlineLog(widget.mainline.id, ref);
        return;
      }
      await widget.controller
          .updateMainlineLog(widget.mainline.id, ref, text: outcome.text);
    } on StateError {
      _toast('这一段已经不在了（可能被别处改过）');
    }
  }

  void _toast(String message) {
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(message)));
  }

  /// 写 / 改某个月的月记：一个月只留一条，有字才给删除。
  Future<void> _promptMonthNote(int year, int month) async {
    if (widget.readOnly) return;
    final existing = widget.mainline.monthNoteOf(year, month)?.text ?? '';
    final outcome = await _textDialog(
      title: '$year 年 $month 月',
      subtitle: '一个月写一句：这个月在做什么',
      initial: existing,
      allowDelete: existing.isNotEmpty,
      // 不写例句：上面那行 subtitle 已经说明这个框里写什么，框里再来一行灰字是同一句
      // 话的第二次，还占掉一行高。
      hint: null,
      minLines: 1,
    );
    if (outcome == null) return;
    await widget.controller.setMainlineMonthNote(
      widget.mainline.id,
      year,
      month,
      outcome.deleted ? '' : outcome.text,
    );
  }

  Future<_LogOutcome?> _textDialog({
    required String title,
    required String subtitle,
    required String initial,
    bool allowDelete = false,
    String? hint = '这段时间在做什么',
    int minLines = 2,
  }) async {
    final ctrl = TextEditingController(text: initial);
    final result = await showDialog<_LogOutcome>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(subtitle,
                style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                    color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
            const SizedBox(height: 8),
            TextField(
              controller: ctrl,
              autofocus: true,
              minLines: minLines,
              maxLines: 4,
              decoration: InputDecoration(
                hintText: hint,
                border: const OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          if (allowDelete)
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(const _LogOutcome(deleted: true)),
              child: const Text('删除'),
            ),
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(), child: const Text('取消')),
          FilledButton(
            onPressed: () =>
                Navigator.of(ctx).pop(_LogOutcome(text: ctrl.text.trim())),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    return result;
  }

  static String _rangeText(DateTime a, DateTime b) => isSameDay(a, b)
      ? '${a.year} 年 ${a.month} 月 ${a.day} 日'
      : '${a.year} 年 ${a.month} 月 ${a.day} 日 ~ '
          '${b.month} 月 ${b.day} 日（${b.difference(a).inDays + 1} 天）';
}

class _LogOutcome {
  final String text;
  final bool deleted;

  const _LogOutcome({this.text = '', this.deleted = false});
}

// ---------- 几何 ----------

/// 一次布局算好的几何：周行、行高、每周的圈段。手势换算全靠它。
class _Layout {
  final List<_Week> weeks;
  final double rowH;
  final double dateH;
  final double bandH;
  final int maxBands;
  final double cellW;

  const _Layout({
    required this.weeks,
    required this.rowH,
    required this.dateH,
    required this.bandH,
    required this.maxBands,
    required this.cellW,
  });

  double weekTop(int index) => index * rowH;

  static _Layout of(
    DateTime month,
    double width,
    double height,
    Mainline mainline,
  ) {
    final first = DateTime(month.year, month.month, 1);
    final lead = (first.weekday + 6) % 7;
    final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
    final weekCount = ((lead + daysInMonth) + 6) ~/ 7;
    final rowH = height <= 0 ? 44.0 : height / weekCount;
    final dateH = math.min(32.0, math.max(rowH - 14, 20.0));
    final bandH = math.max(math.min(14.0, rowH - dateH - 2), 1.0);
    final maxBands = math.max(0, math.min(3, ((rowH - dateH - 2) / bandH).floor()));

    final weeks = <_Week>[];
    final logs = mainline.logsInOrder;
    for (var w = 0; w < weekCount; w++) {
      final cells = <DateTime?>[];
      for (var col = 0; col < 7; col++) {
        final dayNum = w * 7 + col - lead + 1;
        cells.add(dayNum >= 1 && dayNum <= daysInMonth
            ? DateTime(month.year, month.month, dayNum)
            : null);
      }
      final weekStart = DateTime(month.year, month.month, 1 + w * 7 - lead);
      final weekEnd = weekStart.add(const Duration(days: 6));
      final bands = <_BandSegment>[];
      // 圈只存对象引用，不存下标：命令通道按"起止日 + 原文"定位（见 MainlineLogRef），
      // 界面这边的下标也用不上。
      for (final log in logs) {
        if (log.end.isBefore(weekStart) || log.start.isAfter(weekEnd)) continue;
        final startCol =
            math.max(0, log.start.difference(weekStart).inDays);
        final endCol = math.min(6, log.end.difference(weekStart).inDays);
        if (startCol > endCol) continue;
        final used = {for (final b in bands) b.slot};
        var slot = 0;
        while (used.contains(slot)) {
          slot++;
        }
        bands.add(_BandSegment(
          log: log,
          startCol: startCol,
          endCol: endCol,
          slot: slot,
          text: log.text,
        ));
      }
      weeks.add(_Week(cells: cells, weekStart: weekStart, bands: bands));
    }

    return _Layout(
      weeks: weeks,
      rowH: rowH,
      dateH: dateH,
      bandH: bandH,
      maxBands: maxBands,
      cellW: width / 7,
    );
  }

  DateTime? dayAt(Offset local) {
    if (local.dx < 0 || local.dy < 0 || rowH <= 0 || cellW <= 0) return null;
    final week = (local.dy / rowH).floor();
    final col = (local.dx / cellW).floor();
    if (week < 0 || week >= weeks.length || col < 0 || col > 6) return null;
    return weeks[week].cells[col];
  }

  _Week? weekAt(Offset local) {
    if (rowH <= 0 || local.dy < 0) return null;
    final index = (local.dy / rowH).floor();
    if (index < 0 || index >= weeks.length) return null;
    return weeks[index];
  }

  /// 点在哪条圈上（用周内局部 y 判行，再按该周的列范围判列）。
  _BandSegment? bandAt(_Week week, Offset local) {
    final index = weeks.indexOf(week);
    if (index < 0) return null;
    final relY = local.dy - weekTop(index);
    if (relY < dateH) return null;
    final slot = ((relY - dateH) / bandH).floor();
    final col = (local.dx / cellW).floor();
    for (final b in week.bands) {
      if (b.slot == slot && col >= b.startCol && col <= b.endCol) return b;
    }
    return null;
  }

  /// 一段日期落在这一周的哪几列；不与本周相交 → null。
  (int, int)? segmentOf(DateTime start, DateTime end, int weekIndex) {
    final week = weeks[weekIndex];
    final weekEnd = week.weekStart.add(const Duration(days: 6));
    if (end.isBefore(week.weekStart) || start.isAfter(weekEnd)) return null;
    final a = math.max(0, start.difference(week.weekStart).inDays);
    final b = math.min(6, end.difference(week.weekStart).inDays);
    if (a > b) return null;
    return (a, b);
  }
}

class _Week {
  final List<DateTime?> cells;
  final DateTime weekStart;
  final List<_BandSegment> bands;

  const _Week({
    required this.cells,
    required this.weekStart,
    required this.bands,
  });
}

class _BandSegment {
  final MainlineLog log;
  final int startCol;
  final int endCol;
  final int slot;
  final String text;

  const _BandSegment({
    required this.log,
    required this.startCol,
    required this.endCol,
    required this.slot,
    required this.text,
  });
}

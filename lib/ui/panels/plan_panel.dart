import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;

import '../../domain/plan.dart';
import '../../domain/task.dart';
import '../app_controller.dart';
import '../theme.dart';
import 'branch_panel.dart';

/// 编排覆盖页（panels/plan.md §6.11；格式见 docs/formats/plan.md）。
///
/// **只排不做**：条目不是任务，完成 / 逾期 / 提醒都在今日清单里。这一页只有一条
/// 时间轴——左侧时刻、右侧标题、中间一条竖线。
///
/// 三天窗口：昨天只读、今天明天可排，打开落在今天。改时刻或新增一条时，应用会把这
/// 一天按时刻归位（`PlanService` 里做），拖动是唯一能盖过它的操作。
class PlanOverlay extends StatefulWidget {
  final AppController controller;

  final VoidCallback onClose;

  /// 锚点日 = 界面上那个"今天"（测试注入；默认取真实日期）。三页由它派生。
  final DateTime? day;

  /// 判定"现在"用的时刻（测试注入；默认取真实时间）。只有"现在"游标与
  /// "已过的时刻"弱化用到它——编排本身没有时间语义。
  final DateTime? now;

  const PlanOverlay({
    super.key,
    required this.controller,
    required this.onClose,
    this.day,
    this.now,
  });

  @override
  State<PlanOverlay> createState() => _PlanOverlayState();
}

class _PlanOverlayState extends State<PlanOverlay> {
  /// 三页里的"今天"；打开落在这一页，左边是昨天、右边是明天。
  static const int _todayIndex = 1;

  late final PageController _pages = PageController(initialPage: _todayIndex);

  int _index = _todayIndex;

  DateTime get _anchor => planDay(widget.day ?? DateTime.now());

  DateTime get _now => widget.now ?? DateTime.now();

  /// 第 [i] 页是哪一天（0 = 昨天 / 1 = 今天 / 2 = 明天）。
  DateTime _dayAt(int i) =>
      DateTime(_anchor.year, _anchor.month, _anchor.day + i - 1);

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 同一块壳的两面（§6.11 / §6.12）：数据各是各的，只有页头与进出共用。
    final branch = widget.controller.arrangeView == ArrangeView.branch;
    final count = branch
        ? widget.controller.branches.length
        : widget.controller.planEntriesFor(_dayAt(_index)).length;
    return Material(
      color: theme.scaffoldBackgroundColor,
      child: Column(
        children: [
          _header(theme, count, branch: branch),
          const Divider(height: 1),
          Expanded(
            // 桌面：overscroll 只能靠按住鼠标拖出来（滚轮滚到头继续滚是常态，
            // 认了就是天天误触），所以这一页和今日页一样要放开鼠标拖拽。横向同理
            // ——桌面上滑页也得能用鼠标拖。
            child: ScrollConfiguration(
              behavior: ScrollConfiguration.of(context).copyWith(
                dragDevices: PointerDeviceKind.values.toSet(),
              ),
              child: NotificationListener<ScrollNotification>(
                onNotification: _onScroll,
                child: branch
                    ? BranchBoard(controller: widget.controller)
                    : PageView(
                        controller: _pages,
                        onPageChanged: (i) => setState(() => _index = i),
                        children: [
                          for (var i = 0; i < 3; i++)
                            _DayTimeline(
                              key: ValueKey(planDayKey(_dayAt(i))),
                              controller: widget.controller,
                              day: _dayAt(i),
                              now: _now,
                              readOnly: i == 0,
                            ),
                        ],
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 末尾之后继续上滑 = 退出（与今日页"到顶再下拉"同一条规则的两端）。
  ///
  /// **按轴筛，不按 depth 筛**：这一页外面套了横向 PageView，里面列表的通知冒上来时
  /// depth 已经是 1，按 depth 过滤会把退出手势整个吃掉。只认手指拖出来的 overscroll
  /// （`dragDetails` 非空）：鼠标滚轮滚到底继续滚是常态，认了就是天天误退。
  bool _onScroll(ScrollNotification n) {
    if (n.metrics.axis != Axis.vertical) return false;
    if (n is OverscrollNotification &&
        n.dragDetails != null &&
        n.overscroll > 0) {
      widget.controller.pullPlanExit(n.overscroll);
    } else if (n is ScrollEndNotification) {
      // 向上快甩是 dy < 0（页面往上走）。
      widget.controller
          .settlePlanExit(n.dragDetails?.velocity.pixelsPerSecond.dy ?? 0);
    }
    return false;
  }

  // ---- 头部 ----

  Widget _header(ThemeData theme, int count, {required bool branch}) {
    final hint = theme.colorScheme.onSurfaceVariant;
    // 昨天只读是编排视图的事；支线不分天，没有"锁"这一说。
    final readOnly = !branch && _index == 0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 4, 12, 0),
      child: Column(
        children: [
          Row(
            children: [
              IconButton(
                tooltip: '返回',
                icon: const Icon(Icons.arrow_back),
                onPressed: widget.onClose,
              ),
              // 这一页同时装昨天、明天和支线：标题位置给"视图切换"，
              // 写死的「编排」在支线视图上是错的。
              _viewTab(theme, ArrangeView.plan, '编排'),
              const SizedBox(width: 8),
              _viewTab(theme, ArrangeView.branch, '支线'),
              const Spacer(),
              if (readOnly) ...[
                Icon(Icons.lock_outline, size: 14, color: hint),
                const SizedBox(width: 4),
              ],
              if (count > 0)
                Text(
                  branch ? '$count 条线' : '$count 项',
                  style: theme.textTheme.labelMedium?.copyWith(color: hint),
                ),
            ],
          ),
          if (!branch)
            Row(
              children: [
                for (var i = 0; i < 3; i++) Expanded(child: _tab(theme, i)),
              ],
            ),
        ],
      ),
    );
  }

  /// 页头那两段视图切换：当前那段强调色加粗 + 下划线，点另一个就换视图。
  ///
  /// 切换只改这一次打开看到的东西，不动数据、不改开合；下次从哪个入口进来
  /// 还是落哪个视图（[AppController.openPlan] / [AppController.openBranch]）。
  Widget _viewTab(ThemeData theme, ArrangeView value, String label) {
    final selected = widget.controller.arrangeView == value;
    final accent = AppColors.accent;
    return InkWell(
      onTap: () => widget.controller.showArrangeView(value),
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 7),
        child: Container(
          padding: const EdgeInsets.only(bottom: 2),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: selected ? accent : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Text(
            label,
            style: theme.textTheme.titleMedium?.copyWith(
              color: selected ? accent : theme.colorScheme.onSurfaceVariant,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }

  /// 日期轴的一段：`昨天 22` / `今天 23` / `明天 24`，当前那段强调色 + 下划线。
  ///
  /// 标签是给桌面的：Windows 上横滑没有肌肉记忆，只有手势等于没有入口。
  Widget _tab(ThemeData theme, int i) {
    final selected = _index == i;
    final accent = AppColors.accent;
    return InkWell(
      onTap: () => _goTo(i),
      child: Container(
        padding: const EdgeInsets.only(top: 4, bottom: 5),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: selected ? accent : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Text(
          '${_relativeLabel(i)} ${_dayAt(i).day}',
          textAlign: TextAlign.center,
          style: theme.textTheme.labelMedium?.copyWith(
            color: selected ? accent : theme.colorScheme.onSurfaceVariant,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }

  void _goTo(int i) {
    if (i == _index) return;
    _pages.animateToPage(
      i,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
    );
  }

  static String _relativeLabel(int i) =>
      const ['昨天', '今天', '明天'][i.clamp(0, 2)];
}

/// 一天的编排（时间轴本体）。昨天那一页只读：照常渲染，不加、不拖、不改。
class _DayTimeline extends StatefulWidget {
  final AppController controller;

  final DateTime day;

  /// 判定"现在"的时刻。
  final DateTime now;

  /// 只读 = 昨天：没有添加行、不可拖动、点条目不开编辑面板。
  final bool readOnly;

  const _DayTimeline({
    super.key,
    required this.controller,
    required this.day,
    required this.now,
    required this.readOnly,
  });

  @override
  State<_DayTimeline> createState() => _DayTimelineState();
}

class _DayTimelineState extends State<_DayTimeline> {
  /// 时刻列宽 + 竖线所在的空隙（竖线在两者之间）。
  static const double _timeWidth = 46;
  static const double _railGap = 16;
  static const double _railX = _timeWidth + 8;

  /// 候选最多几条（再多就该用输入框筛了，面板也就那么高）。
  static const int _maxCandidates = 6;

  /// 新条目默认离开上一条一小时。
  static const int _defaultGap = 60;

  final TextEditingController _draft = TextEditingController();
  final FocusNode _draftFocus = FocusNode();

  /// 『现在』游标的锚：打开时把镜头挪到它身上（`ensureVisible` 要 context）。
  final GlobalKey _nowKey = GlobalKey();

  /// 添加行展开着吗（提交后不收起，可以连着写）。
  bool _adding = false;

  /// 正在写的那一条的时刻；null = 没有时刻。
  int? _draftMinutes;

  /// 拖动改顺序后、落盘完成前的行序（见 [_reorder]）。null = 用控制器那份。
  List<PlanEntry>? _dragged;

  List<PlanEntry> get _entries =>
      _dragged ?? widget.controller.planEntriesFor(widget.day);

  bool get _isToday {
    final now = widget.now;
    final d = widget.day;
    return now.year == d.year && now.month == d.month && now.day == d.day;
  }

  int get _nowMinutes => widget.now.hour * 60 + widget.now.minute;

  @override
  void initState() {
    super.initState();
    // 打开就把镜头落到『现在』：编排一长就得滚，落在顶部等于先给人看一段早就
    // 过完的安排。得等第一帧排完版才量得到游标的位置，所以推到帧后。
    if (!widget.readOnly) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _revealNow());
    }
  }

  @override
  void dispose() {
    _draft.dispose();
    _draftFocus.dispose();
    super.dispose();
  }

  /// 把时间轴滚到『现在』：游标停在视口上方三分之一处，前面留一小截已过的、
  /// 后面露出还没到的。
  ///
  /// 游标没建出来就不动（不是今天那一页；或者一天长得超出列表的预建范围）——
  /// 那种情况下"现在"本来也不在这个视口里，硬滚只会滚到一个猜出来的位置。
  void _revealNow() {
    if (!mounted) return;
    final anchor = _nowKey.currentContext;
    if (anchor == null) return;
    Scrollable.ensureVisible(anchor, alignment: 0.32, duration: Duration.zero);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entries = _entries;
    // 游标插在第几条之前（-1 = 不画：不是今天）。全过完了就落在末尾。
    final cursorAt = widget.readOnly ? -1 : _cursorIndex(entries);

    if (widget.readOnly) {
      return ListView.builder(
        // 内容不满一屏也要能 overscroll：上滑退出发生在"末尾之后"。
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(10, 8, 12, 32),
        itemCount: entries.isEmpty ? 1 : entries.length,
        itemBuilder: (context, i) => entries.isEmpty
            ? _emptyHint(theme)
            : _entryRow(theme, entries, i, beforeCursor: false),
      );
    }

    return ReorderableListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(10, 8, 12, 32),
      // 把视口外的行也建出来：打开时要滚到『现在』，而 `ensureVisible` 只认识
      // 已经建好的 context——游标在屏幕外就滚不过去。一天几十条的量，全建下来
      // 也不值钱。
      scrollCacheExtent: const ScrollCacheExtent.pixels(3000),
      buildDefaultDragHandles: false,
      // newIndex 已按"移除旧位"调整好，直接就是落点（同挂起组）。
      onReorderItem: (from, to) => _reorder(entries, from, to),
      itemCount: entries.length,
      header: entries.isEmpty ? _emptyHint(theme) : null,
      footer: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (entries.isNotEmpty && cursorAt == entries.length)
            _cursorRow(theme),
          _addRow(theme),
        ],
      ),
      itemBuilder: (context, i) => Column(
        key: ObjectKey(entries[i]),
        mainAxisSize: MainAxisSize.min,
        children: [
          if (i == cursorAt) _cursorRow(theme),
          ReorderableDelayedDragStartListener(
            index: i,
            child: _entryRow(theme, entries, i,
                beforeCursor: cursorAt < 0 || i < cursorAt),
          ),
        ],
      ),
    );
  }

  /// "现在"落在第几条之前 = 第一个时刻晚于现在的条目；全都已过就是末尾。
  /// 没有时刻的条目不参与比较（它没有可比的点）。
  int _cursorIndex(List<PlanEntry> entries) {
    if (!_isToday) return -1;
    final now = _nowMinutes;
    for (var i = 0; i < entries.length; i++) {
      final m = entries[i].minutesOfDay;
      if (m != null && m > now) return i;
    }
    return entries.length;
  }

  /// 现在游标：左侧当前时刻、一条强调色横线、右端标『现在』。
  ///
  /// 它是**行间的分隔**，不是精确刻度——行距等距，游标只在跨过某一条时往前走一格。
  Widget _cursorRow(ThemeData theme) {
    final accent = AppColors.accent;
    return SizedBox(
      key: _nowKey,
      height: 24,
      child: Stack(
        children: [
          Positioned(
            left: 0,
            width: _timeWidth,
            top: 5,
            child: Text(
              _fmtMinutes(_nowMinutes),
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 10.5,
                height: 1.2,
                color: accent,
                fontWeight: FontWeight.w700,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          Positioned(
            left: _railX - 3,
            top: 7,
            child: Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(shape: BoxShape.circle, color: accent),
            ),
          ),
          Positioned(
            left: _railX,
            right: 26,
            top: 10,
            child: Container(height: 1, color: accent.withValues(alpha: 0.55)),
          ),
          Positioned(
            right: 0,
            top: 4,
            child: Text(
              '现在',
              style: TextStyle(
                fontSize: 10,
                height: 1.2,
                color: accent,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---- 时间轴 ----

  Widget _entryRow(ThemeData theme, List<PlanEntry> entries, int index,
      {required bool beforeCursor}) {
    final entry = entries[index];
    final minutes = entry.minutesOfDay;
    final prev = index == 0 ? null : entries[index - 1].minutesOfDay;
    // 倒挂 = 时刻比上一条还早。只剩两个来源：手改文件、手动拖动。
    final inverted = minutes != null && prev != null && minutes < prev;
    final past = _isToday && minutes != null && minutes < _nowMinutes;
    final hint = theme.colorScheme.onSurfaceVariant;
    // 过了的那几条整行压淡：时刻与标题用同一个值，游标就是界线。只压字，
    // 底色不动——铺淡一层会让"已过"看着像"被划掉"。
    final pastInk = hint.withValues(alpha: 0.45);
    final timeColor = inverted
        ? AppColors.timeBadge
        : past
            ? pastInk
            : hint;
    final line = theme.colorScheme.outlineVariant;
    // 游标以上的竖线用强调色：这一段是今天已经走完的部分（进度条的"已过"）。
    final rail = beforeCursor ? AppColors.accent.withValues(alpha: 0.45) : line;
    final isLast = index == entries.length - 1;

    final row = Stack(
      children: [
        // 竖线：最后一条只画到节点为止，免得线拖出一条尾巴。
        Positioned(
          left: _railX,
          top: 0,
          bottom: isLast ? null : 0,
          height: isLast ? 18 : null,
          child: Container(width: 1, color: rail),
        ),
        Positioned(
          left: _railX - 3,
          top: 13,
          child: Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: inverted ? AppColors.timeBadge : line,
            ),
          ),
        ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: _timeWidth,
              child: Padding(
                padding: const EdgeInsets.only(top: 9),
                child: Text(
                  entry.timeText ?? '—',
                  textAlign: TextAlign.right,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: timeColor,
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
            const SizedBox(width: _railGap),
            Expanded(
              child: Container(
                margin: const EdgeInsets.symmetric(vertical: 3),
                padding: const EdgeInsets.fromLTRB(12, 9, 12, 10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest
                      .withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  entry.title,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: past ? pastInk : null),
                ),
              ),
            ),
          ],
        ),
      ],
    );

    // 昨天只读：整行就是一块字，点了什么也不发生。
    if (widget.readOnly) return row;
    return InkWell(onTap: () => _edit(entries, index), child: row);
  }

  Widget _emptyHint(ThemeData theme) {
    final hint = theme.colorScheme.onSurfaceVariant;
    final title = widget.readOnly
        ? '昨天没有编排'
        : _isToday
            ? '今天还没有编排'
            : '明天还没有编排';
    final sub = widget.readOnly
        ? '那天没排，也就没留下什么'
        : _isToday
            ? '把今天要做的事按时刻排一条'
            : '提前把明天排出来';
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 48, 6, 10),
      child: Column(
        children: [
          Icon(Icons.event_note_outlined, size: 36, color: hint),
          const SizedBox(height: 10),
          Text(title),
          const SizedBox(height: 4),
          Text(
            sub,
            style: theme.textTheme.bodySmall?.copyWith(color: hint),
          ),
        ],
      ),
    );
  }

  // ---- 添加 ----

  Widget _addRow(ThemeData theme) {
    if (!_adding) {
      final hint = theme.colorScheme.onSurfaceVariant;
      return Padding(
        padding: const EdgeInsets.only(top: 4),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: _startAdding,
          child: Container(
            height: 44,
            decoration: BoxDecoration(
              border: Border.all(
                  color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6)),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.add, size: 18, color: hint),
                const SizedBox(width: 6),
                Text('添加一项',
                    style: theme.textTheme.bodyMedium?.copyWith(color: hint)),
              ],
            ),
          ),
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          margin: const EdgeInsets.only(top: 4),
          padding: const EdgeInsets.fromLTRB(6, 4, 4, 4),
          decoration: BoxDecoration(
            border: Border.all(color: AppColors.accent.withValues(alpha: 0.5)),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              TextButton(
                onPressed: _pickDraftTime,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  minimumSize: const Size(0, 32),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  textStyle: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600),
                ),
                child: Text(
                  _draftMinutes == null ? '加时刻' : _fmtMinutes(_draftMinutes!),
                  style:
                      const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
                ),
              ),
              Expanded(
                child: TextField(
                  controller: _draft,
                  focusNode: _draftFocus,
                  textInputAction: TextInputAction.done,
                  // **不写占位提示**：窄面板上"几点做什么"只剩"几…"，
                  // 看不清反而成噪音。左边是时刻、右边是确定，上下文已经够了。
                  decoration: const InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                  ),
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) => _commit(),
                ),
              ),
              // 两颗图标钮收到 34dp（默认 48dp 会把输入区挤成一条缝）。Material 3
              // 下 `constraints` 被 ButtonStyle 接管，只能用 `style` 收。
              IconButton(
                tooltip: '添加',
                iconSize: 20,
                style: IconButton.styleFrom(
                  minimumSize: const Size(34, 34),
                  padding: EdgeInsets.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                icon: const Icon(Icons.check),
                onPressed: _commit,
              ),
              IconButton(
                tooltip: '收起',
                iconSize: 20,
                style: IconButton.styleFrom(
                  minimumSize: const Size(34, 34),
                  padding: EdgeInsets.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                icon: const Icon(Icons.close),
                onPressed: _cancelAdding,
              ),
            ],
          ),
        ),
        _candidateList(theme),
      ],
    );
  }

  /// 快捷添加的候选：今日清单（按清单顺序）+ 任务池（计划段、散件段）的标题。
  ///
  /// **只借标题文字**（『贴的是文字，不是引用』）：点击后的编排条目与任务没有任何
  /// 关系，所以这里也按标题去重——同名任务贴一次就够。输入框里的字按包含匹配筛，最多
  /// [_maxCandidates] 条。
  List<String> _candidates() {
    final controller = widget.controller;
    final today = controller.todayView;
    final pool = controller.poolView;
    final ordered = <Task>[
      ...today.inProgress,
      ...today.overdue,
      ...today.fixed,
      ...today.pinned,
      ...today.flex,
      ...today.routines,
      if (today.picked != null) today.picked!,
      ...today.loose,
      ...pool.plan,
      ...pool.loose,
    ];
    final query = _draft.text.trim().toLowerCase();
    final seen = <String>{};
    final out = <String>[];
    for (final task in ordered) {
      final title = task.title.trim();
      if (title.isEmpty || !seen.add(title)) continue;
      if (query.isNotEmpty && !title.toLowerCase().contains(query)) continue;
      out.add(title);
      if (out.length >= _maxCandidates) break;
    }
    return out;
  }

  Widget _candidateList(ThemeData theme) {
    final items = _candidates();
    if (items.isEmpty) return const SizedBox.shrink();
    // 编排里已有同名条目：标一个勾，但照样能点（一天做两次同一件事是允许的）。
    final planned = {for (final e in _entries) e.title.trim()};
    final hint = theme.colorScheme.onSurfaceVariant;
    return Container(
      margin: const EdgeInsets.only(top: 6),
      decoration: BoxDecoration(
        border: Border.all(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final title in items)
            InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => _pickCandidate(title),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
                child: Row(
                  children: [
                    Icon(Icons.add, size: 15, color: hint),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                    if (planned.contains(title))
                      Text(
                        '已排',
                        style: theme.textTheme.labelSmall
                            ?.copyWith(color: AppColors.accent),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 点一条候选 = 直接落一条编排（时刻用当前默认），可以连点连排。
  Future<void> _pickCandidate(String title) async {
    await widget.controller.addPlanEntry(
      widget.day,
      PlanEntry(title: title, minutesOfDay: _draftMinutes),
    );
    if (!mounted) return;
    setState(() {
      _draft.clear();
      _draftMinutes = _suggestedMinutes();
    });
    _draftFocus.requestFocus();
  }

  void _startAdding() {
    setState(() {
      _adding = true;
      _draftMinutes = _suggestedMinutes();
    });
    // 输入框这一帧才挂上，焦点放到下一帧。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _draftFocus.requestFocus();
    });
  }

  void _cancelAdding() {
    setState(() {
      _adding = false;
      _draft.clear();
      _draftMinutes = null;
    });
  }

  Future<void> _commit() async {
    final title = _draft.text.trim();
    if (title.isEmpty) {
      _cancelAdding();
      return;
    }
    await widget.controller.addPlanEntry(
      widget.day,
      PlanEntry(title: title, minutesOfDay: _draftMinutes),
    );
    if (!mounted) return;
    // 加号留在原位：清空、重算默认时刻，接着写。
    setState(() {
      _draft.clear();
      _draftMinutes = _suggestedMinutes();
    });
    _draftFocus.requestFocus();
  }

  /// 默认时刻 = 最近一条有时刻的 + 一小时；还没有条目时：今天取现在向上取整到半点，
  /// **昨天 / 明天取 09:00**——晚上排明天，"现在"落上去没有意义。
  int _suggestedMinutes() {
    final entries = _entries;
    for (var i = entries.length - 1; i >= 0; i--) {
      final m = entries[i].minutesOfDay;
      if (m != null) return (m + _defaultGap).clamp(0, 23 * 60 + 59);
    }
    if (!_isToday) return 9 * 60;
    final now = widget.now;
    final round = ((now.hour * 60 + now.minute + 29) ~/ 30) * 30;
    return round.clamp(0, 23 * 60 + 59);
  }

  Future<void> _pickDraftTime() async {
    final picked = await _pickTime(context, _draftMinutes);
    if (picked == null || !mounted) return;
    setState(() => _draftMinutes = picked);
  }

  // ---- 编辑 ----

  Future<void> _edit(List<PlanEntry> entries, int index) async {
    final result = await showModalBottomSheet<Object>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _PlanEditSheet(entry: entries[index]),
    );
    if (result == null) return;
    if (result is _DeletePlanEntry) {
      // 标题清空也算删掉：没有"无标题条目"这种状态。
      await widget.controller.removePlanEntry(widget.day, index);
      return;
    }
    if (result is PlanEntry) {
      await widget.controller.updatePlanEntry(widget.day, index, result);
    }
  }

  // ---- 排序 ----

  /// 拖动改顺序：**先把新序摆上去，再落盘**。
  ///
  /// 落盘是"读整份 → 改一天 → 整份写回"，等它回来才重排的话，松手那一帧会先
  /// 弹回原位、写完再跳到新位——看着就是来回闪两下。所以顺序在本地先定住，
  /// 控制器的数据跟上之后再交回它（那时两边一致，交换不产生任何位移）。
  Future<void> _reorder(List<PlanEntry> entries, int from, int to) async {
    final next = [...entries]
      ..removeAt(from)
      ..insert(to, entries[from]);
    setState(() => _dragged = next);
    try {
      await widget.controller.setPlanEntries(widget.day, next);
    } finally {
      if (mounted) setState(() => _dragged = null);
    }
  }

  // ---- 时间小工具 ----

  Future<int?> _pickTime(BuildContext context, int? current) =>
      pickPlanTime(context, current);
}

/// 改一条编排：标题 + 时刻 + 删除。
///
/// 输入框的 controller 归这个 State 所有——不能像内联 sheet 那样在 `_edit` 里
/// 手动 dispose：sheet 的退场动画还没跑完，TextField 还在树上，先 dispose 会炸。
class _PlanEditSheet extends StatefulWidget {
  final PlanEntry entry;

  const _PlanEditSheet({required this.entry});

  @override
  State<_PlanEditSheet> createState() => _PlanEditSheetState();
}

class _PlanEditSheetState extends State<_PlanEditSheet> {
  late final TextEditingController _title =
      TextEditingController(text: widget.entry.title);
  late int? _minutes = widget.entry.minutesOfDay;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final picked = await pickPlanTime(context, _minutes);
    if (picked == null || !mounted) return;
    setState(() => _minutes = picked);
  }

  void _save() {
    final title = _title.text.trim();
    if (title.isEmpty) {
      Navigator.pop(context, const _DeletePlanEntry());
      return;
    }
    Navigator.pop(context, PlanEntry(title: title, minutesOfDay: _minutes));
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _title,
              autofocus: true,
              decoration: const InputDecoration(labelText: '做什么'),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                TextButton.icon(
                  onPressed: _pick,
                  icon: const Icon(Icons.schedule, size: 18),
                  label: Text(
                      _minutes == null ? '加个时刻' : _fmtMinutes(_minutes!)),
                ),
                if (_minutes != null)
                  TextButton(
                    onPressed: () => setState(() => _minutes = null),
                    child: const Text('清掉时刻'),
                  ),
                const Spacer(),
                TextButton(
                  onPressed: () =>
                      Navigator.pop(context, const _DeletePlanEntry()),
                  child: const Text('删除'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            SizedBox(
              width: double.infinity,
              child: FilledButton(onPressed: _save, child: const Text('保存')),
            ),
          ],
        ),
      ),
    );
  }
}

/// 时刻选择：24 小时制，返回"当天第几分钟"。
Future<int?> pickPlanTime(BuildContext context, int? current) async {
  final picked = await showTimePicker(
    context: context,
    initialTime: current == null
        ? const TimeOfDay(hour: 9, minute: 0)
        : TimeOfDay(hour: current ~/ 60, minute: current % 60),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
      child: child ?? const SizedBox.shrink(),
    ),
  );
  if (picked == null) return null;
  return picked.hour * 60 + picked.minute;
}

String _fmtMinutes(int m) =>
    '${(m ~/ 60).toString().padLeft(2, '0')}:${(m % 60).toString().padLeft(2, '0')}';

/// 删除标记：`showModalBottomSheet` 的返回值只能用 Object 传两种结果。
class _DeletePlanEntry {
  const _DeletePlanEntry();
}

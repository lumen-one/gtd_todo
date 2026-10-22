import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../domain/mainline.dart';
import '../app_controller.dart';
import '../theme.dart';
import 'mainline_log_calendar.dart';

/// 主线覆盖页（ui-interaction.md §6.9）：**盖住整块侧边栏**（含面板头）。
///
/// 两页横滑：第 1 页**行为链**、第 2 页**记录**（日历）。顶栏是唯一入口
/// （`side_panel.dart` 的第二行），退出走左上返回 / 系统返回键。
///
/// 分工：勾选是高频动作 → 靶在链的**节点**上；改名写备注是低频 → 靶在**文字**上。
/// 归档必须显式点（全勾完才出现），归档后只读。
class MainlineOverlay extends StatefulWidget {
  final AppController controller;
  final VoidCallback onClose;

  const MainlineOverlay({
    super.key,
    required this.controller,
    required this.onClose,
  });

  @override
  State<MainlineOverlay> createState() => _MainlineOverlayState();
}

class _MainlineOverlayState extends State<MainlineOverlay> {
  final PageController _pages = PageController();
  int _page = 0;
  bool _editing = false;
  bool _busy = false;
  String? _viewingId;

  final TextEditingController _nameCtrl = TextEditingController();
  List<_StepDraft> _drafts = [];
  int _draftSeq = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.mainlineCloseGuard = _closeGuard;
  }

  /// 存住 tear-off：dispose 时要把**同一个**函数撤销掉，否则控制器会捏着
  /// 一个已经销毁的 State 不放（下次关覆盖页就炸）。
  late final Future<bool> Function() _closeGuard = _canClose;

  @override
  void dispose() {
    if (identical(widget.controller.mainlineCloseGuard, _closeGuard)) {
      widget.controller.mainlineCloseGuard = null;
    }
    _pages.dispose();
    _nameCtrl.dispose();
    for (final d in _drafts) {
      d.dispose();
    }
    super.dispose();
  }

  /// 编辑态按返回：先问"放弃这次编辑"，答是就只退出编辑态（覆盖页留着），
  /// 不直接关掉整页——免得一次误触把改了一半的链丢了。
  Future<bool> _canClose() async {
    if (!_editing) return true;
    final discard = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('放弃这次编辑？'),
        content: const Text('改动还没保存。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('继续编辑')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('放弃')),
        ],
      ),
    );
    if (discard == true && mounted) setState(() => _editing = false);
    return false; // 这一步只收编辑态，覆盖页等下一次返回再关
  }

  /// 正在看的那条：归档查看优先，否则当前主线。
  Mainline? get _shown {
    final id = _viewingId;
    if (id != null) {
      final m = widget.controller.mainlineById(id);
      if (m != null) return m;
    }
    return widget.controller.activeMainline;
  }

  bool get _isReadingArchive => _viewingId != null;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m = _shown;
    // 返回键不在这里挂 PopScope：同一条路由上的 PopScope 会**全部**收到通知，
    // 覆盖页再挂一个就会连带把面板也收起。宿主问 `controller.mainlineOpen`
    // 分两步收（编辑器靠 mainlineCloseGuard 拦一道）。
    return Material(
      color: theme.scaffoldBackgroundColor,
      child: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _header(theme, m),
            const Divider(height: 1),
            Expanded(child: _body(theme, m)),
          ],
        ),
      ),
    );
  }

  // ---------- 顶栏 ----------

  Widget _header(ThemeData theme, Mainline? m) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 2, 4, 0),
      child: Row(
        children: [
          SizedBox(
            width: 34,
            height: 34,
            child: IconButton(
              padding: EdgeInsets.zero,
              iconSize: 20,
              tooltip: '返回',
              icon: const Icon(Icons.arrow_back),
              onPressed: _editing ? null : widget.onClose,
            ),
          ),
          Expanded(
            child: Text(
              _editing ? '编辑主线' : (m?.title ?? '主线'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium,
            ),
          ),
          if (_editing) ...[
            _iconButton(Icons.check, '保存', _busy ? null : () => _save(m!)),
            _iconButton(
              Icons.close,
              '取消',
              () => setState(() => _editing = false),
            ),
          ] else ...[
            if (m != null && !_isReadingArchive)
              Tooltip(
                message: _page == 0 ? '翻到记录' : '翻回行为链',
                child: InkWell(
                  onTap: _togglePage,
                  borderRadius: BorderRadius.circular(6),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                    child: Text(
                      '${_page + 1}/2',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
            if (m != null && !_isReadingArchive)
              _iconButton(Icons.edit_outlined, '编辑', () => _beginEdit(m)),
            if (m != null && _isReadingArchive)
              TextButton(
                onPressed: () => setState(() => _viewingId = null),
                child: const Text('返回当前'),
              ),
            if (m != null && !_isReadingArchive && m.isAllDone)
              _iconButton(
                  Icons.check_circle_outline, '完成主线', () => _archive(m)),
          ],
        ],
      ),
    );
  }

  Widget _iconButton(IconData icon, String tooltip, VoidCallback? onPressed) =>
      SizedBox(
        width: 34,
        height: 34,
        child: IconButton(
          padding: EdgeInsets.zero,
          iconSize: 20,
          tooltip: tooltip,
          icon: Icon(icon),
          onPressed: onPressed,
        ),
      );

  // ---------- 主体 ----------

  Widget _body(ThemeData theme, Mainline? m) {
    if (m == null) return _emptyState(theme);
    if (_editing) return _editor(theme, m);
    // 上滑退出只接两页里"内容到底之后"的一下（§6.9）：编辑态不接——那时页面
    // 有自己的一套输入意图，收了会把没保存的东西一起推走。
    return NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: PageView(
        controller: _pages,
        // 记录页里横滑属于日历（拖选日期圈一段），翻页交给页头那颗 `1/2`：
        // 两套横滑抢同一个手势，谁都不肯让，只能按页分工。
        physics: _page == 1
            ? const NeverScrollableScrollPhysics()
            : const PageScrollPhysics(),
        onPageChanged: (i) => setState(() => _page = i),
        children: [
          _chainPage(theme, m),
          MainlineLogCalendar(
            controller: widget.controller,
            mainline: m,
            readOnly: !m.isActive,
            // 日历区域横滑归圈日期，翻页落在下半区（当天详情 / 空提示）
            onSwipeBack: () => _pages.animateToPage(0,
                duration: const Duration(milliseconds: 240),
                curve: Curves.easeOutCubic),
          ),
        ],
      ),
    );
  }

  /// 内容到底后继续上滑 = 退出（与编排页同一条规则）。
  ///
  /// 只认纵向：PageView 的横滑也会从这里过，跟着认就会"翻一页就把页面关了"。
  /// 不能按 `depth` 过滤——两页的列表都嵌在 PageView 里，通知的 depth 是 1。
  /// 只认手指拖出来的 overscroll（滚轮滚到底继续滚是常态）。
  bool _onScroll(ScrollNotification n) {
    if (n.metrics.axis != Axis.vertical) return false;
    if (n is OverscrollNotification &&
        n.dragDetails != null &&
        n.overscroll > 0) {
      widget.controller.pullMainlineExit(n.overscroll);
    } else if (n is ScrollEndNotification) {
      widget.controller
          .settleMainlineExit(n.dragDetails?.velocity.pixelsPerSecond.dy ?? 0);
    }
    return false;
  }

  void _togglePage() {
    final next = _page == 0 ? 1 : 0;
    if (!_pages.hasClients) {
      setState(() => _page = next);
      return;
    }
    _pages.animateToPage(next,
        duration: const Duration(milliseconds: 240), curve: Curves.easeOutCubic);
  }

  Widget _emptyState(ThemeData theme) {
    final archived = widget.controller.archivedMainlines;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.route_outlined,
                size: 40, color: AppColors.accent.withValues(alpha: 0.7)),
            const SizedBox(height: 10),
            Text('还没有主线', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              '一条主线 = 一串行为链 + 日历上的记录',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 14),
            FilledButton(
              onPressed: _createFlow,
              child: const Text('新建主线'),
            ),
            if (archived.isNotEmpty) ...[
              const SizedBox(height: 6),
              TextButton(
                onPressed: _showArchive,
                child: Text('已完成的主线 · ${archived.length} 条'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ---------- 行为链页 ----------

  Widget _chainPage(ThemeData theme, Mainline m) {
    final nextIndex = m.nextStepIndex;
    final archived = widget.controller.archivedMainlines;
    return ListView(
      // 不满一屏也要能 overscroll：上滑退出发生在"末尾之后"。
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 20),
      children: [
        if (!m.isActive) _archivedBanner(theme, m),
        _progressHeader(theme, m),
        const SizedBox(height: 6),
        if (m.steps.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 18),
            child: Text(
              '行为链还是空的——点右上角铅笔加几步',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        for (var i = 0; i < m.steps.length; i++)
          _StepRow(
            step: m.steps[i],
            first: i == 0,
            last: i == m.steps.length - 1,
            aboveDone: i > 0 && m.steps[i - 1].done,
            isNext: i == nextIndex,
            readOnly: !m.isActive,
            onToggle: () => widget.controller.toggleMainlineStep(
              m.id,
              i,
              done: !m.steps[i].done,
            ),
            onOpen: () => _stepDialog(m, i),
          ),
        if (m.isActive && m.isAllDone)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 12, 8, 0),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.tonalIcon(
                onPressed: () => _archive(m),
                icon: const Icon(Icons.inventory_2_outlined, size: 18),
                label: const Text('完成主线并归档'),
              ),
            ),
          ),
        const SizedBox(height: 10),
        const Divider(),
        InkWell(
          onTap: _showArchive,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
            child: Row(
              children: [
                Icon(Icons.inventory_2_outlined,
                    size: 16, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '已完成的主线 · ${archived.length} 条',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
                Icon(Icons.chevron_right,
                    size: 16, color: theme.colorScheme.onSurfaceVariant),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _archivedBanner(ThemeData theme, Mainline m) {
    final at = m.completedAt;
    return Container(
      margin: const EdgeInsets.fromLTRB(6, 4, 6, 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(Icons.inventory_2_outlined,
              size: 15, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              at == null
                  ? '已归档 · 只读'
                  : '已归档 · ${at.year}-${at.month.toString().padLeft(2, '0')}'
                      '-${at.day.toString().padLeft(2, '0')} 完成 · 只读',
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  Widget _progressHeader(ThemeData theme, Mainline m) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                m.progressText,
                style: theme.textTheme.headlineSmall?.copyWith(
                  color: AppColors.accent,
                  fontWeight: FontWeight.w800,
                  height: 1,
                ),
              ),
              const SizedBox(width: 6),
              Padding(
                padding: const EdgeInsets.only(bottom: 1),
                child: Text('已完成',
                    style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant)),
              ),
              const Spacer(),
              if (m.isAllDone)
                Text('可归档',
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: AppColors.accent)),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: m.progress,
              minHeight: 4,
              backgroundColor:
                  theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
              color: AppColors.accent,
            ),
          ),
        ],
      ),
    );
  }

  // ---------- 编辑态 ----------

  Widget _editor(ThemeData theme, Mainline m) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: TextField(
            controller: _nameCtrl,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(
              labelText: '主线名',
              isDense: true,
              border: OutlineInputBorder(),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 6, 14, 2),
          child: Row(
            children: [
              Text('行为链', style: theme.textTheme.labelLarge),
              const Spacer(),
              Text('长按把手可拖动排序',
                  style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant)),
            ],
          ),
        ),
        Expanded(
          child: ReorderableListView.builder(
            buildDefaultDragHandles: false,
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            itemCount: _drafts.length,
            onReorder: (oldIndex, newIndex) {
              setState(() {
                if (newIndex > oldIndex) newIndex -= 1;
                final d = _drafts.removeAt(oldIndex);
                _drafts.insert(newIndex, d);
              });
            },
            itemBuilder: (context, i) {
              final draft = _drafts[i];
              return Padding(
                key: ValueKey('draft-${draft.key}'),
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                child: Row(
                  children: [
                    ReorderableDragStartListener(
                      index: i,
                      child: Icon(Icons.drag_handle,
                          size: 18,
                          color: theme.colorScheme.onSurfaceVariant),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: TextField(
                        controller: draft.title,
                        decoration: InputDecoration(
                          isDense: true,
                          hintText: '第 ${i + 1} 步',
                          border: const UnderlineInputBorder(),
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 34,
                      height: 34,
                      child: IconButton(
                        padding: EdgeInsets.zero,
                        iconSize: 18,
                        tooltip: '删除这一步',
                        icon: const Icon(Icons.remove_circle_outline),
                        onPressed: () => setState(() {
                          _drafts.removeAt(i).dispose();
                        }),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 2, 12, 8),
          child: Row(
            children: [
              TextButton.icon(
                onPressed: () => setState(() {
                  _drafts.add(_StepDraft.empty(++_draftSeq));
                }),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('添加一步'),
              ),
              const Spacer(),
              Text('共 ${_drafts.length} 步',
                  style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant)),
            ],
          ),
        ),
      ],
    );
  }

  void _beginEdit(Mainline m) {
    _nameCtrl.text = m.title;
    for (final d in _drafts) {
      d.dispose();
    }
    _drafts = [
      for (final s in m.steps) _StepDraft.from(s, ++_draftSeq),
    ];
    setState(() => _editing = true);
  }

  Future<void> _save(Mainline m) async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      _toast('主线名不能为空');
      return;
    }
    setState(() => _busy = true);
    try {
      if (name != m.title) {
        await widget.controller.renameMainline(m.id, name);
      }
      await widget.controller.setMainlineSteps(
        m.id,
        [for (final d in _drafts) d.toStep()],
      );
      if (mounted) setState(() => _editing = false);
    } catch (e) {
      _toast('保存失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---------- 对话框 ----------

  Future<void> _createFlow() async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建主线'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(
            labelText: '这条主线叫什么',
            hintText: '例：论文冲刺',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    final created = await widget.controller.createMainline(name);
    if (created != null && mounted) _beginEdit(created);
  }

  Future<void> _stepDialog(Mainline m, int index) async {
    if (!m.isActive) return;
    final step = m.steps[index];
    final titleCtrl = TextEditingController(text: step.title);
    final noteCtrl = TextEditingController(text: step.note);
    var done = step.done;
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('这一步'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: titleCtrl,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: '名字',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: noteCtrl,
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: '备注（这一笔手写记在这）',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 6),
              InkWell(
                onTap: () => setLocal(() => done = !done),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: [
                      Icon(
                        done
                            ? Icons.check_circle
                            : Icons.radio_button_unchecked,
                        size: 18,
                        color: done
                            ? AppColors.accent
                            : Theme.of(ctx).colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 8),
                      Text(done ? '已完成（点一下取消）' : '标记为已完成'),
                    ],
                  ),
                ),
              ),
              if (step.doneAt != null)
                Text(
                  '完成于 ${step.doneAt!.year}-${step.doneAt!.month.toString().padLeft(2, '0')}'
                  '-${step.doneAt!.day.toString().padLeft(2, '0')} '
                  '${step.doneAt!.hour.toString().padLeft(2, '0')}:'
                  '${step.doneAt!.minute.toString().padLeft(2, '0')}',
                  style: Theme.of(ctx).textTheme.labelSmall?.copyWith(
                      color: Theme.of(ctx).colorScheme.onSurfaceVariant),
                ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('取消')),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (result != true) return;
    if (done != step.done) {
      await widget.controller.toggleMainlineStep(m.id, index, done: done);
    }
    final title = titleCtrl.text.trim();
    final note = noteCtrl.text.trim();
    if ((title.isNotEmpty && title != step.title) || note != step.note) {
      await widget.controller.updateMainlineStep(
        m.id,
        index,
        title: title.isEmpty ? step.title : title,
        note: note,
      );
    }
  }

  Future<void> _archive(Mainline m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('完成这条主线？'),
        content: const Text('归档后从顶栏撤下，整条（行为链 + 记录）留在 主线.md 里，'
            '之后只能只读查看。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('再想想')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('归档')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await widget.controller.completeMainline(m.id);
      if (!mounted) return;
      widget.onClose();
    } catch (e) {
      _toast('$e');
    }
  }

  Future<void> _showArchive() async {
    final items = widget.controller.archivedMainlines;
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                child: Text('已完成的主线', style: theme.textTheme.titleSmall),
              ),
              if (items.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
                  child: Text('还没有归档的主线',
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)),
                )
              else
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final m in items)
                        ListTile(
                          dense: true,
                          leading: const Icon(Icons.inventory_2_outlined,
                              size: 18),
                          title: Text(m.title, maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                          subtitle: Text(
                            '完成于 ${_dayText(m.completedAt)} · ${m.progressText}',
                            style: theme.textTheme.labelSmall,
                          ),
                          onTap: () => Navigator.of(ctx).pop(m.id),
                        ),
                    ],
                  ),
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
    if (picked != null && mounted) {
      setState(() {
        _viewingId = picked;
        _editing = false;
      });
    }
  }

  static String _dayText(DateTime? d) => d == null
      ? '—'
      : '${d.year}-${d.month.toString().padLeft(2, '0')}-'
          '${d.day.toString().padLeft(2, '0')}';

  void _toast(String message) {
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(message)));
  }
}

// ---------- 行为链的一行 ----------

class _StepRow extends StatelessWidget {
  final MainlineStep step;
  final bool first;
  final bool last;
  final bool aboveDone;
  final bool isNext;
  final bool readOnly;
  final VoidCallback onToggle;
  final VoidCallback onOpen;

  const _StepRow({
    required this.step,
    required this.first,
    required this.last,
    required this.aboveDone,
    required this.isNext,
    required this.readOnly,
    required this.onToggle,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final done = step.done;
    final muted = theme.colorScheme.onSurfaceVariant;
    final meta = _metaText();
    return SizedBox(
      height: 56,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 节点 = 勾选靶（高频动作给最小的靶）
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: readOnly ? null : onToggle,
            child: SizedBox(
              width: 30,
              child: CustomPaint(
                painter: _RailPainter(
                  done: done,
                  aboveDone: aboveDone,
                  isNext: isNext,
                  first: first,
                  last: last,
                  accent: AppColors.accent,
                  line: theme.colorScheme.outlineVariant,
                  surface: theme.scaffoldBackgroundColor,
                ),
              ),
            ),
          ),
          Expanded(
            child: InkWell(
              onTap: readOnly ? null : onOpen,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      step.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        height: 1.2,
                        fontWeight: done
                            ? null
                            : (isNext ? FontWeight.w700 : FontWeight.w500),
                        color: done ? muted : theme.colorScheme.onSurface,
                        decoration: done ? TextDecoration.lineThrough : null,
                        decorationColor: muted,
                      ),
                    ),
                    if (meta.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        meta,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style:
                            theme.textTheme.labelSmall?.copyWith(color: muted),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _metaText() {
    final parts = <String>[];
    if (step.done) {
      final at = step.doneAt;
      if (at != null) {
        parts.add('完成 ${at.month}月${at.day}日 '
            '${at.hour.toString().padLeft(2, '0')}:'
            '${at.minute.toString().padLeft(2, '0')}');
      } else {
        parts.add('已完成');
      }
    }
    if (step.note.trim().isNotEmpty) parts.add(step.note.trim());
    return parts.join(' · ');
  }
}

/// 链的竖线与节点：完成段实色，未完成段虚线；第一个没勾的节点加一圈描边。
class _RailPainter extends CustomPainter {
  final bool done;
  final bool aboveDone;
  final bool isNext;
  final bool first;
  final bool last;
  final Color accent;
  final Color line;
  final Color surface;

  const _RailPainter({
    required this.done,
    required this.aboveDone,
    required this.isNext,
    required this.first,
    required this.last,
    required this.accent,
    required this.line,
    required this.surface,
  });

  static const double _nodeY = 20;
  static const double _r = 6.5;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final solid = Paint()
      ..color = accent
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    final dashed = Paint()
      ..color = line
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round;

    if (!first) {
      final end = _nodeY - _r - 1;
      if (aboveDone) {
        canvas.drawLine(Offset(cx, 0), Offset(cx, end), solid);
      } else {
        _dashLine(canvas, cx, 0, end, dashed);
      }
    }
    if (!last) {
      final start = _nodeY + _r + 1;
      if (done) {
        canvas.drawLine(Offset(cx, start), Offset(cx, size.height), solid);
      } else {
        _dashLine(canvas, cx, start, size.height, dashed);
      }
    }

    final center = Offset(cx, _nodeY);
    if (isNext) {
      canvas.drawCircle(
        center,
        _r + 3,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4
          ..color = accent.withValues(alpha: 0.45),
      );
    }
    if (done) {
      canvas.drawCircle(center, _r, Paint()..color = accent);
      final check = Paint()
        ..color = Colors.white
        ..strokeWidth = 1.8
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke;
      final path = Path()
        ..moveTo(cx - 3.2, _nodeY)
        ..lineTo(cx - 0.8, _nodeY + 2.4)
        ..lineTo(cx + 3.4, _nodeY - 2.4);
      canvas.drawPath(path, check);
    } else {
      canvas.drawCircle(center, _r, Paint()..color = surface);
      canvas.drawCircle(
        center,
        _r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = isNext ? 2 : 1.6
          ..color = isNext ? accent : line,
      );
    }
  }

  void _dashLine(Canvas canvas, double x, double from, double to, Paint p) {
    const dash = 4.0;
    const gap = 3.0;
    var y = from;
    while (y < to) {
      canvas.drawLine(
          Offset(x, y), Offset(x, math.min(y + dash, to)), p);
      y += dash + gap;
    }
  }

  @override
  bool shouldRepaint(covariant _RailPainter old) =>
      old.done != done ||
      old.aboveDone != aboveDone ||
      old.isNext != isNext ||
      old.first != first ||
      old.last != last ||
      old.accent != accent ||
      old.line != line ||
      old.surface != surface;
}

// ---------- 编辑态的一行草稿 ----------

class _StepDraft {
  final TextEditingController title;
  final String note;
  final bool done;
  final DateTime? doneAt;
  final int key;

  _StepDraft.from(MainlineStep step, this.key)
      : title = TextEditingController(text: step.title),
        note = step.note,
        done = step.done,
        doneAt = step.doneAt;

  _StepDraft.empty(this.key)
      : title = TextEditingController(),
        note = '',
        done = false,
        doneAt = null;

  MainlineStep toStep() => MainlineStep(
        title: title.text.trim(),
        done: done,
        doneAt: doneAt,
        note: note,
      );

  void dispose() => title.dispose();
}

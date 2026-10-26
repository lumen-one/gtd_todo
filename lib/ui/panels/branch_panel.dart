import 'package:flutter/material.dart';

import '../../domain/branch.dart';
import '../../domain/task.dart';
import '../app_controller.dart';
import '../dialogs/task_detail_sheet.dart';
import '../theme.dart';
import '../widgets/task_actions.dart';
import '../widgets/task_tile.dart' show fmtTime;

/// 支线视图（panels/branch.md §6.12）：编排覆盖页的另一面。
///
/// 一条支线一张文件夹卡片，里面是**真实任务**：勾一下就是完成那个任务，点行开
/// 详情卡。与编排同页不同源——这里加一条，时间轴上不出现。
///
/// 已完成的行沉到卡片末尾（弱化），取消勾选自动回到原来的位置：文件里只存一个
/// 全序，渲染时分两段，所以"回去"不需要记下标。
class BranchBoard extends StatefulWidget {
  final AppController controller;

  const BranchBoard({super.key, required this.controller});

  @override
  State<BranchBoard> createState() => _BranchBoardState();
}

class _BranchBoardState extends State<BranchBoard> {
  /// 候选最多几条（与编排的添加行同一档：再多就该用输入框筛了）。
  static const int _maxCandidates = 6;

  /// 展开着的支线（**默认全收起**，所以存"展开了哪些"；折叠状态不落盘）。
  /// 收起态一页只露文件夹名，装得下更多条；要看里面就在卡片头上点一下。
  final Set<int> _expanded = {};

  /// 正在挑任务的是哪条支线；null = 没有。
  int? _addingFor;

  /// 正在新建支线（页底那行输入框开着）。
  bool _creating = false;

  final TextEditingController _draft = TextEditingController();
  final FocusNode _draftFocus = FocusNode();
  final TextEditingController _newName = TextEditingController();
  final FocusNode _newFocus = FocusNode();

  @override
  void dispose() {
    _draft.dispose();
    _draftFocus.dispose();
    _newName.dispose();
    _newFocus.dispose();
    super.dispose();
  }

  List<Branch> get _branches => widget.controller.branches;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_branches.isEmpty && !_creating) return _empty(theme);

    return ListView(
      // 内容不满一屏也要能 overscroll：上滑退出发生在"末尾之后"。
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 32),
      children: [
        for (var i = 0; i < _branches.length; i++) _card(theme, i),
        // 输入框和那颗按钮是同一个入口的两态，别同时摆出来。
        if (_creating) _createRow(theme) else _newBranchRow(theme),
      ],
    );
  }

  // ---- 卡片 ----

  Widget _card(ThemeData theme, int index) {
    final branch = _branches[index];
    final rows = _rowsOf(index);
    final done = rows.where((r) => r.done).length;
    final collapsed = !_expanded.contains(index);
    final allDone = rows.isNotEmpty && done == rows.length;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        border: Border.all(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.55)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => _toggle(index),
            onLongPress: () => _cardMenu(index),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(11, 9, 10, 9),
              child: Row(
                children: [
                  Icon(
                    collapsed
                        ? Icons.folder_outlined
                        : Icons.folder_open_outlined,
                    size: 18,
                    color: AppColors.accent,
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      branch.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                  if (rows.isNotEmpty)
                    Text(
                      '$done/${rows.length}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: allDone
                            ? AppColors.accent
                            : theme.colorScheme.onSurfaceVariant,
                        fontWeight:
                            allDone ? FontWeight.w700 : FontWeight.w600,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  const SizedBox(width: 2),
                  Icon(
                    collapsed ? Icons.expand_more : Icons.expand_less,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
          if (!collapsed) ...[
            const Divider(height: 1),
            if (rows.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '空文件夹',
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant
                            .withValues(alpha: 0.8)),
                  ),
                ),
              )
            else
              _rowList(theme, index, rows),
            _addingFor == index
                ? _candidateBox(theme, index)
                : _addTaskRow(theme, index),
          ],
        ],
      ),
    );
  }

  void _toggle(int index) => setState(() {
        if (!_expanded.remove(index)) _expanded.add(index);
      });

  /// 两段渲染：未完成（含失效引用）在前、已完成在后，各段内保持文件里的行序。
  List<_Row> _rowsOf(int index) {
    final pending = <_Row>[];
    final done = <_Row>[];
    for (final entry in widget.controller.branchEntries(index)) {
      final row = _Row(entry: entry, task: widget.controller.taskById(entry.taskId));
      if (row.done) {
        done.add(row);
      } else {
        pending.add(row);
      }
    }
    return [...pending, ...done];
  }

  Widget _rowList(ThemeData theme, int index, List<_Row> rows) {
    final pendingCount = rows.where((r) => !r.done).length;
    return ReorderableListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      // newIndex 已按"移除旧位"调整好，直接就是落点（同今日页的挂起组）。
      onReorderItem: (from, to) => _reorder(index, rows, pendingCount, from, to),
      itemCount: rows.length,
      itemBuilder: (context, i) => Column(
        key: ObjectKey(rows[i].entry),
        mainAxisSize: MainAxisSize.min,
        children: [
          _taskRow(theme, index, rows[i],
              // 已完成的沉底区不参与拖动：它们的顺序由状态决定。
              gripIndex: i < pendingCount ? i : null),
        ],
      ),
    );
  }

  Widget _taskRow(ThemeData theme, int index, _Row row,
      {required int? gripIndex}) {
    final hint = theme.colorScheme.onSurfaceVariant;
    final task = row.task;

    // 失效引用：任务被删了 / 还没同步过来。保留在文件里，只标灰 + 长按移出。
    if (task == null) {
      return InkWell(
        onLongPress: () => _removeEntry(index, row.entry),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 7, 12, 7),
          child: Row(
            children: [
              Icon(Icons.help_outline, size: 15, color: hint),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  row.entry.title.isEmpty ? '（找不到这条任务）' : row.entry.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: hint.withValues(alpha: 0.7),
                    decoration: TextDecoration.lineThrough,
                  ),
                ),
              ),
              Text('已失效',
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: hint.withValues(alpha: 0.7))),
            ],
          ),
        ),
      );
    }

    final overdue = task.deadline != null &&
        task.deadline!.isBefore(DateTime.now()) &&
        !task.isCompleted;
    final due = branchDueLabel(task, DateTime.now());
    final rowWidget = InkWell(
      onTap: () => showTaskDetailSheet(
        context,
        widget.controller,
        task,
        kind: TaskMenuKind.branch,
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 2, 10, 2),
        child: Row(
          children: [
            Checkbox(
              value: task.isCompleted,
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              onChanged: (v) => _toggleDone(task, v == true),
            ),
            const SizedBox(width: 2),
            Expanded(
              child: Text(
                task.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: task.isCompleted ? hint.withValues(alpha: 0.6) : null,
                  decoration:
                      task.isCompleted ? TextDecoration.lineThrough : null,
                ),
              ),
            ),
            if (overdue)
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: AppColors.overdueFor(theme.brightness),
                    shape: BoxShape.circle,
                  ),
                ),
              )
            else if (due != null)
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Text(
                  due,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: AppColors.timeBadge,
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            if (gripIndex != null)
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: ReorderableDragStartListener(
                  index: gripIndex,
                  child: Icon(Icons.drag_handle,
                      size: 16, color: hint.withValues(alpha: 0.55)),
                ),
              ),
          ],
        ),
      ),
    );
    return rowWidget;
  }

  Future<void> _toggleDone(Task task, bool done) async {
    if (done) {
      await widget.controller.complete(task.id);
    } else {
      await widget.controller.reopenTask(task.id);
    }
  }

  /// 拖动落位：只动未完成那一段，已完成那几条接在后面原样写回。
  Future<void> _reorder(int index, List<_Row> rows, int pendingCount, int from,
      int to) async {
    if (from >= pendingCount || to >= pendingCount) return;
    final pending = [for (var i = 0; i < pendingCount; i++) rows[i].entry];
    final done = [
      for (var i = pendingCount; i < rows.length; i++) rows[i].entry,
    ];
    final moved = pending.removeAt(from);
    pending.insert(to, moved);
    await widget.controller.setBranchEntries(index, [...pending, ...done]);
  }

  // ---- 候选 ----

  Widget _addTaskRow(ThemeData theme, int index) {
    final hint = theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => setState(() {
          _addingFor = index;
          _draft.clear();
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _draftFocus.requestFocus();
          });
        }),
        child: Container(
          height: 34,
          decoration: BoxDecoration(
            border: Border.all(
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.7)),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.add, size: 16, color: hint),
              const SizedBox(width: 5),
              Text('添加任务',
                  style: theme.textTheme.bodySmall?.copyWith(color: hint)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _candidateBox(ThemeData theme, int index) {
    final items = _candidates(index);
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 2, 10, 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(8, 0, 4, 0),
            decoration: BoxDecoration(
              border:
                  Border.all(color: AppColors.accent.withValues(alpha: 0.5)),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _draft,
                    focusNode: _draftFocus,
                    textInputAction: TextInputAction.done,
                    // 不写占位提示：窄面板上那半句话只剩几个点，反成噪音。
                    decoration: const InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                    ),
                    style: theme.textTheme.bodySmall,
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) => _pickFirst(index, items),
                  ),
                ),
                IconButton(
                  tooltip: '收起',
                  iconSize: 18,
                  style: IconButton.styleFrom(
                    minimumSize: const Size(30, 30),
                    padding: EdgeInsets.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  icon: const Icon(Icons.close),
                  onPressed: () => setState(() => _addingFor = null),
                ),
              ],
            ),
          ),
          if (items.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(top: 6),
              decoration: BoxDecoration(
                border: Border.all(
                    color: theme.colorScheme.outlineVariant
                        .withValues(alpha: 0.6)),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final task in items) _candidateRow(theme, index, task),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _candidateRow(ThemeData theme, int index, Task task) {
    final here = widget.controller.branches[index].contains(task.id);
    final elsewhere = here
        ? const <String>[]
        : widget.controller.branchNamesOf(task.id);
    final hint = theme.colorScheme.onSurfaceVariant;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      // 已经在这条线里的不再落一次（同一行不出现两次）。
      onTap: here ? null : () => _pick(index, task.id),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 7, 10, 7),
        child: Row(
          children: [
            Expanded(
              child: Text(
                task.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: here ? hint.withValues(alpha: 0.7) : null,
                ),
              ),
            ),
            if (here)
              Icon(Icons.check, size: 14, color: AppColors.accent)
            else if (elsewhere.isNotEmpty)
              Text(
                elsewhere.first,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: hint.withValues(alpha: 0.65)),
              ),
          ],
        ),
      ),
    );
  }

  /// 候选：今日清单（按清单顺序）+ 任务池（计划段、散件段）。
  ///
  /// **例行实例不列**：那是当天的实例，明天就不在了，挂进来只会立刻失效。
  List<Task> _candidates(int index) {
    final controller = widget.controller;
    final today = controller.todayView;
    final pool = controller.poolView;
    final ordered = <Task>[
      ...today.inProgress,
      ...today.overdue,
      ...today.fixed,
      ...today.pinned,
      ...today.flex,
      if (today.picked != null) today.picked!,
      ...today.loose,
      ...pool.plan,
      ...pool.loose,
    ];
    final query = _draft.text.trim().toLowerCase();
    final seen = <String>{};
    final out = <Task>[];
    for (final task in ordered) {
      if (!seen.add(task.id)) continue;
      if (query.isNotEmpty && !task.title.toLowerCase().contains(query)) {
        continue;
      }
      out.add(task);
      if (out.length >= _maxCandidates) break;
    }
    return out;
  }

  Future<void> _pick(int index, String taskId) async {
    await widget.controller.addTaskToBranch(index, taskId);
    if (!mounted) return;
    setState(() => _draft.clear());
  }

  /// 输入框里回车：有候选就落第一条，没有就什么都不做。
  Future<void> _pickFirst(int index, List<Task> items) async {
    if (items.isEmpty) return;
    await _pick(index, items.first.id);
  }

  Future<void> _removeEntry(int index, BranchEntry entry) async {
    await widget.controller.removeTaskFromBranch(index, entry.taskId);
  }

  // ---- 新建 / 改名 / 删除 ----

  Widget _newBranchRow(ThemeData theme) {
    final hint = theme.colorScheme.onSurfaceVariant;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => setState(() {
        _creating = true;
        _newName.clear();
        _addingFor = null;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _newFocus.requestFocus();
        });
      }),
      child: Container(
        height: 42,
        margin: const EdgeInsets.only(top: 2),
        decoration: BoxDecoration(
          border: Border.all(
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6)),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.create_new_folder_outlined, size: 17, color: hint),
            const SizedBox(width: 6),
            Text('新建支线',
                style: theme.textTheme.bodyMedium?.copyWith(color: hint)),
          ],
        ),
      ),
    );
  }

  Widget _createRow(ThemeData theme) {
    return Container(
      margin: const EdgeInsets.only(top: 2),
      padding: const EdgeInsets.fromLTRB(10, 0, 4, 0),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.accent.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.create_new_folder_outlined,
              size: 17, color: AppColors.accent),
          const SizedBox(width: 6),
          Expanded(
            child: TextField(
              controller: _newName,
              focusNode: _newFocus,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(
                isDense: true,
                border: InputBorder.none,
              ),
              style: theme.textTheme.bodyMedium,
              onSubmitted: (_) => _commitNew(),
            ),
          ),
          IconButton(
            tooltip: '建这条线',
            iconSize: 18,
            style: IconButton.styleFrom(
              minimumSize: const Size(32, 32),
              padding: EdgeInsets.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            icon: const Icon(Icons.check),
            onPressed: _commitNew,
          ),
          IconButton(
            tooltip: '取消',
            iconSize: 18,
            style: IconButton.styleFrom(
              minimumSize: const Size(32, 32),
              padding: EdgeInsets.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            icon: const Icon(Icons.close),
            onPressed: () => setState(() => _creating = false),
          ),
        ],
      ),
    );
  }

  Future<void> _commitNew() async {
    final name = _newName.text.trim();
    if (name.isEmpty) {
      setState(() => _creating = false);
      return;
    }
    final at = _branches.length;
    await widget.controller.addBranch(name);
    if (!mounted) return;
    // 建完紧接着挑第一批任务：空文件夹停在原地，下一步必然是往里放东西。
    // 刚建的那条**展开**——默认收起是为了"一页看得下更多条"，不是让新建的
    // 东西立刻消失在合着的卡片里。
    setState(() {
      _creating = false;
      _newName.clear();
      _addingFor = at;
      _expanded.add(at);
      _draft.clear();
    });
  }

  /// 卡片头长按：改名 / 删除（删除只删分组，任务不动）。
  Future<void> _cardMenu(int index) async {
    final branch = _branches[index];
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(branch.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(ctx).textTheme.titleSmall),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline),
              title: const Text('改名'),
              onTap: () => Navigator.of(ctx).pop('rename'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('删除支线'),
              subtitle: const Text('只删这条分组，任务一件都不动'),
              onTap: () => Navigator.of(ctx).pop('delete'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'rename') {
      await _rename(index, branch.name);
    } else if (action == 'delete') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('删除「${branch.name}」？'),
          content: const Text('只删这条分组，里面的任务都还在。'),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('取消')),
            FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('删除')),
          ],
        ),
      );
      if (ok == true) {
        await widget.controller.removeBranch(index);
        if (!mounted) return;
        // 删掉一条之后下标整体前移：展开态与"正在挑任务"的那个下标都对不上了。
        setState(() {
          _expanded.clear();
          _addingFor = null;
        });
      }
    }
  }

  Future<void> _rename(int index, String current) async {
    final text = TextEditingController(text: current);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('改名字'),
        content: TextField(
          controller: text,
          autofocus: true,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(hintText: '这条线叫什么'),
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(text.text),
              child: const Text('保存')),
        ],
      ),
    );
    text.dispose();
    if (name == null || name.trim().isEmpty) return;
    await widget.controller.renameBranch(index, name);
  }

  // ---- 空态 ----

  Widget _empty(ThemeData theme) {
    final hint = theme.colorScheme.onSurfaceVariant;
    // 空态也要能上滑退出：所以是一张可滚的列表，不是居中一块（同今日页空态）。
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(top: 96),
      children: [
        Column(
          children: [
            Icon(Icons.call_split, size: 40, color: hint),
            const SizedBox(height: 10),
            const Text('还没有支线'),
            const SizedBox(height: 4),
            Text(
              '把任务按线归堆',
              style: theme.textTheme.bodySmall?.copyWith(color: hint),
            ),
            const SizedBox(height: 14),
            FilledButton.tonal(
              onPressed: () => setState(() {
                _creating = true;
                _newName.clear();
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) _newFocus.requestFocus();
                });
              }),
              child: const Text('新建支线'),
            ),
            if (_creating) _createRow(theme),
          ],
        ),
      ],
    );
  }
}

/// 渲染用的一行：文件里的条目 + 当前查到的任务（null = 失效引用）。
class _Row {
  final BranchEntry entry;
  final Task? task;

  const _Row({required this.entry, required this.task});

  bool get done => task?.isCompleted ?? false;
}

/// 今天该响的时刻（`14:30`）；没有截止 → null。支线行右侧只标"今天"的那一档，
/// 明天以后的不标——那是编排与清单的事。
String? branchDueLabel(Task task, DateTime now) {
  final d = task.deadline;
  if (d == null || task.isCompleted) return null;
  if (d.year != now.year || d.month != now.month || d.day != now.day) {
    return null;
  }
  return fmtTime(d);
}

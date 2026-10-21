import 'package:flutter/material.dart';

import '../../domain/plan.dart';
import '../app_controller.dart';
import '../theme.dart';

/// 今日编排覆盖页（ui-interaction.md §6.11；格式见 docs/formats/plan.md）。
///
/// **只排不做**：条目不是任务，完成 / 逾期 / 提醒都在今日清单里。这一页只有一条
/// 时间轴——左侧时刻、右侧标题、中间一条竖线；拖动只改行序，不改时刻，所以顺序和
/// 时刻会打架，打架时只把时间标橙，不自动纠正。
class PlanOverlay extends StatefulWidget {
  final AppController controller;

  final VoidCallback onClose;

  /// 编排哪一天（测试注入；默认今天）。界面只显示一天，跨天由装配层重算。
  final DateTime? day;

  const PlanOverlay({
    super.key,
    required this.controller,
    required this.onClose,
    this.day,
  });

  @override
  State<PlanOverlay> createState() => _PlanOverlayState();
}

class _PlanOverlayState extends State<PlanOverlay> {
  /// 时刻列宽 + 竖线所在的空隙（竖线在两者之间）。
  static const double _timeWidth = 46;
  static const double _railGap = 16;
  static const double _railX = _timeWidth + 8;

  final TextEditingController _draft = TextEditingController();
  final FocusNode _draftFocus = FocusNode();

  /// 添加行展开着吗（提交后不收起，可以连着写）。
  bool _adding = false;

  /// 正在写的那一条的时刻；null = 没有时刻。
  int? _draftMinutes;

  DateTime get _day => planDay(widget.day ?? DateTime.now());

  List<PlanEntry> get _entries => widget.controller.planEntriesFor(_day);

  @override
  void dispose() {
    _draft.dispose();
    _draftFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entries = _entries;
    return Material(
      color: theme.scaffoldBackgroundColor,
      child: Column(
        children: [
          _header(theme, entries.length),
          const Divider(height: 1),
          Expanded(
            child: ReorderableListView.builder(
              padding: const EdgeInsets.fromLTRB(10, 8, 12, 32),
              buildDefaultDragHandles: false,
              // newIndex 已按"移除旧位"调整好，直接就是落点（同挂起组）。
              onReorderItem: (from, to) => _reorder(entries, from, to),
              itemCount: entries.length,
              header: entries.isEmpty ? _emptyHint(theme) : null,
              footer: _addRow(theme),
              itemBuilder: (context, i) => ReorderableDelayedDragStartListener(
                key: ObjectKey(entries[i]),
                index: i,
                child: _entryRow(theme, entries, i),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---- 头部 ----

  Widget _header(ThemeData theme, int count) {
    final hint = theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 6, 12, 4),
      child: Row(
        children: [
          IconButton(
            tooltip: '返回',
            icon: const Icon(Icons.arrow_back),
            onPressed: widget.onClose,
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('今日编排',
                    style: theme.textTheme.titleMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                Text(
                  _dayLabel(_day),
                  style: theme.textTheme.bodySmall?.copyWith(color: hint),
                ),
              ],
            ),
          ),
          if (count > 0)
            Text(
              '$count 项',
              style: theme.textTheme.labelMedium?.copyWith(color: hint),
            ),
        ],
      ),
    );
  }

  // ---- 时间轴 ----

  Widget _entryRow(ThemeData theme, List<PlanEntry> entries, int index) {
    final entry = entries[index];
    final minutes = entry.minutesOfDay;
    final prev = index == 0 ? null : entries[index - 1].minutesOfDay;
    // 倒挂 = 时刻比上一条还早（拖动只改行序，不改时刻，所以它们会打架）。
    final inverted = minutes != null && prev != null && minutes < prev;
    final past = _isToday && minutes != null && minutes < _nowMinutes;
    final hint = theme.colorScheme.onSurfaceVariant;
    final timeColor = inverted
        ? AppColors.timeBadge
        : past
            ? hint.withValues(alpha: 0.45)
            : hint;
    final line = theme.colorScheme.outlineVariant;
    final isLast = index == entries.length - 1;

    return InkWell(
      onTap: () => _edit(entries, index),
      child: Stack(
        children: [
          // 竖线：最后一条只画到节点为止，免得线拖出一条尾巴。
          Positioned(
            left: _railX,
            top: 0,
            bottom: isLast ? null : 0,
            height: isLast ? 18 : null,
            child: Container(width: 1, color: line),
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
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _emptyHint(ThemeData theme) {
    final hint = theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 48, 6, 10),
      child: Column(
        children: [
          Icon(Icons.event_note_outlined, size: 36, color: hint),
          const SizedBox(height: 10),
          const Text('今天还没有编排'),
          const SizedBox(height: 4),
          Text(
            '把今天要做的事按时刻排一条',
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

    return Container(
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
            child: Text(
              _draftMinutes == null ? '加时刻' : _fmtMinutes(_draftMinutes!),
              style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
            ),
          ),
          Expanded(
            child: TextField(
              controller: _draft,
              focusNode: _draftFocus,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: '几点做什么',
              ),
              onSubmitted: (_) => _commit(),
            ),
          ),
          IconButton(
            tooltip: '添加',
            icon: const Icon(Icons.check),
            onPressed: _commit,
          ),
          IconButton(
            tooltip: '收起',
            icon: const Icon(Icons.close),
            onPressed: _cancelAdding,
          ),
        ],
      ),
    );
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
      _day,
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

  /// 默认时刻 = 上一条 + 30 分钟；还没有条目 = 现在向上取整到半点。
  int _suggestedMinutes() {
    final entries = _entries;
    for (var i = entries.length - 1; i >= 0; i--) {
      final m = entries[i].minutesOfDay;
      if (m != null) return (m + 30).clamp(0, 23 * 60 + 59);
    }
    final now = DateTime.now();
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
      await widget.controller.removePlanEntry(_day, index);
      return;
    }
    if (result is PlanEntry) {
      await widget.controller.updatePlanEntry(_day, index, result);
    }
  }

  // ---- 排序 ----

  Future<void> _reorder(List<PlanEntry> entries, int from, int to) async {
    final next = [...entries]
      ..removeAt(from)
      ..insert(to, entries[from]);
    await widget.controller.setPlanEntries(_day, next);
  }

  // ---- 时间小工具 ----

  bool get _isToday {
    final now = DateTime.now();
    final d = _day;
    return now.year == d.year && now.month == d.month && now.day == d.day;
  }

  int get _nowMinutes {
    final now = DateTime.now();
    return now.hour * 60 + now.minute;
  }

  static String _dayLabel(DateTime d) {
    const weeks = ['一', '二', '三', '四', '五', '六', '日'];
    return '${d.month} 月 ${d.day} 日 · 周${weeks[d.weekday - 1]}';
  }

  /// 24 小时制：时间轴上一律 `08:30`，不跟着系统 12/24 制变（同一页要能竖着扫）。
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

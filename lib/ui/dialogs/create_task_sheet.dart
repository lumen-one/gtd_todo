import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../domain/task.dart';
import '../app_controller.dart';
import '../theme.dart';
import '../widgets/month_calendar.dart';
import 'date_pick.dart' show atDefaultHour;
import 'task_form.dart';

/// 新建流程：**先问什么时候，再填内容**。
///
/// 日期不再是表单里的一行档位：绝大多数任务都有日期，把它挪到第一步，
/// 剩下的类型/工时/重要度才落进表单。两页住同一个 sheet 里——
/// 选完日期原地切页，不另弹一层。
///
/// 第 1 页是月历（与日历弹窗共用 [MonthCalendar]，这里不打点）：点某天即
/// 落定，没有『确定』这一步——日期在第 2 页仍然看得见、改得动。
/// 『不排期』从"第四档"挪到标题行右侧，仍然是要显式点一下的那一档。
Future<void> showCreateFlow(
  BuildContext context,
  AppController controller,
) async {
  final created = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _CreateFlowSheet(controller: controller),
  );
  if (created != true || !context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(content: Text('已创建'), duration: Duration(seconds: 2)),
  );
}

class _CreateFlowSheet extends StatefulWidget {
  final AppController controller;

  const _CreateFlowSheet({required this.controller});

  @override
  State<_CreateFlowSheet> createState() => _CreateFlowSheetState();
}

class _CreateFlowSheetState extends State<_CreateFlowSheet> {
  final _titleCtrl = TextEditingController();
  final _noteCtrl = TextEditingController();
  final _workCtrl = TextEditingController();

  /// true = 第 1 页（挑日期），false = 第 2 页（填内容）。
  bool _pickingWhen = true;
  TaskFormValue _value = const TaskFormValue();
  bool _saving = false;

  /// 月历上高亮的那天（回第 1 页时保持选中，选的是哪天一目了然）。
  DateTime? _picked;

  @override
  void dispose() {
    _titleCtrl.dispose();
    _noteCtrl.dispose();
    _workCtrl.dispose();
    super.dispose();
  }

  /// 落定日期并翻到表单页。[when] 为 null = 不排期。
  ///
  /// 时刻手改过的，换日期时连着时刻一起带过去；没改过的取该类型的默认整点
  /// （截止 18:00 / 开始 12:00）。
  void _enterForm(DateTime? when) {
    var at = when;
    if (when != null && _value.timePinned && _value.deadline != null) {
      final prev = _value.deadline!;
      at = DateTime(when.year, when.month, when.day, prev.hour, prev.minute);
    }
    setState(() {
      _value = _value.copyWith(deadline: at, longTerm: at == null);
      _picked = at;
      _pickingWhen = false;
    });
  }

  /// 改时刻：弹时间选择器，落定即钉住——之后再切类型不跟着换。
  Future<void> _pickTime() async {
    final deadline = _value.deadline;
    if (deadline == null) return;
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: deadline.hour, minute: deadline.minute),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _value = _value.copyWith(
        deadline: DateTime(deadline.year, deadline.month, deadline.day,
            picked.hour, picked.minute),
        timePinned: true,
      );
    });
  }

  Future<void> _submit() async {
    final title = _titleCtrl.text.trim();
    if (title.isEmpty || _saving) return;
    // 开始型不进调度、'长期'不估工时：两种都不传分钟数。
    // 截止型 + 按时长却空着：有截止让服务补 30；不排期这边自己补，
    // 否则"按时长"会被服务折回'长期'，用户选的那档就没了。
    final work = _value.type == TaskType.fixed || _value.longTerm
        ? null
        : (int.tryParse(_workCtrl.text.trim()) ?? (_value.isLoose ? 30 : null));
    setState(() => _saving = true);
    try {
      final task = await widget.controller.createTask(
        title: title,
        type: _value.type,
        deadline: _value.deadline,
        estimatedWorkMinutes: work,
        importance: _value.importance,
        description: _noteCtrl.text,
      );
      // 散件永不提醒（§7.0），别给它留一个没有意义的标记——表单默认是开着的。
      if (_value.remind && !_value.isLoose) {
        await widget.controller.setTaskReminder(task.id, enabled: true);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('创建失败：$e')),
      );
      return;
    }
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        14,
        20,
        16 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: AnimatedSize(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        alignment: Alignment.topCenter,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          child: _pickingWhen ? _buildWhenPage(theme) : _buildFormPage(theme),
        ),
      ),
    );
  }

  Widget _buildWhenPage(ThemeData theme) {
    return LayoutBuilder(
      key: const ValueKey('when'),
      builder: (context, constraints) {
        // 月历之外还要摆下的：标题行、组件自己的页头与星期行、底部那行提示、
        // 上下内边距。可用高度不够时压格子，而不是让整页溢出——面板高度
        // 下限是 320。
        const chrome = 190.0;
        final gridMax = constraints.maxHeight.isFinite
            ? math.max(96.0, constraints.maxHeight - chrome)
            : null;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('什么时候？', style: theme.textTheme.titleMedium),
                ),
                // 三无是少数派，但必须留一条路：桌面壳建三无只有这里
                // （快记只在系统级悬浮把手上）。
                TextButton(
                  onPressed: () => _enterForm(null),
                  child: const Text('不排期'),
                ),
              ],
            ),
            // 桌面壳的 sheet 是全窗口宽——不限宽的话七列每格能到 100dp 以上，
            // 月历会撑成一屏半。与日历弹窗同一个上限，居中等宽。
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: MonthCalendar(
                  selected: _picked,
                  gridMaxHeight: gridMax,
                  onPick: (day) =>
                      _enterForm(atDefaultHour(day, _value.type)),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                '点某天，接着填内容',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildFormPage(ThemeData theme) {
    // 问多少由档位与开关决定（§5.1）：无排序档只问标题和日期，标准档多问工时，
    // 重要度看设置里的『问重要度』（关掉时整个维度不参与，表单里就没有这一行）。
    // 『响铃』不在裁剪之列——提醒一律会发，它只是声音开关。
    final mode = widget.controller.scheduleMode;
    return Column(
      key: const ValueKey('form'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TaskFormBody(
          value: _value,
          onChanged: (v) => setState(() => _value = v),
          titleCtrl: _titleCtrl,
          noteCtrl: _noteCtrl,
          workCtrl: _workCtrl,
          autofocusTitle: true,
          onSubmit: _submit,
          hourFollowsType: true,
          onEditTime: _pickTime,
          showWorkStrength: !mode.isManual,
          showImportance: widget.controller.askImportance,
          deadlineActions: [
            TextButton(
              onPressed: () => setState(() => _pickingWhen = true),
              child: const Text('改日期'),
            ),
          ],
        ),
        const SizedBox(height: 10),
        FilledButton(
          onPressed: _value.title.trim().isEmpty || _saving ? null : _submit,
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(52),
            backgroundColor: AppColors.accent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
          ),
          child: const Text(
            '✱ 创建',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w700,
              letterSpacing: 2,
            ),
          ),
        ),
      ],
    );
  }
}

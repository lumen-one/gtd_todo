import 'package:flutter/material.dart';

import '../../domain/task.dart';
import '../app_controller.dart';
import '../theme.dart';
import '../widgets/task_tile.dart' show fmtDateTime;
import 'date_pick.dart';
import 'task_form.dart';

/// 新建流程：**先问什么时候，再填内容**。
///
/// 日期不再是表单里的一行档位：绝大多数任务都有日期，把它挪到第一步，
/// 剩下的类型/工时/重要度才落进表单。两页住同一个 sheet 里——
/// 选完日期原地切页，不另弹一层。
///
/// 『不排期』仍然在，只是从"默认值"变成"要显式点一下的那一档"。
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

  @override
  void dispose() {
    _titleCtrl.dispose();
    _noteCtrl.dispose();
    _workCtrl.dispose();
    super.dispose();
  }

  /// 落定日期并翻到表单页。[when] 为 null = 不排期。
  void _enterForm(DateTime? when) {
    setState(() {
      _value = _value.copyWith(deadline: when, longTerm: when == null);
      _pickingWhen = false;
    });
  }

  Future<void> _pickCustom() async {
    final picked = await pickDateTime(context);
    if (picked == null || !mounted) return;
    _enterForm(picked);
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
    final now = DateTime.now();
    final today = dayAt18(now);
    final tomorrow = dayAt18(now.add(const Duration(days: 1)));
    return Column(
      key: const ValueKey('when'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('什么时候？', style: theme.textTheme.titleMedium),
        const SizedBox(height: 6),
        _WhenTile(
          icon: Icons.today,
          label: '今天',
          detail: fmtDateTime(today),
          onTap: () => _enterForm(today),
        ),
        _WhenTile(
          icon: Icons.event_note,
          label: '明天',
          detail: fmtDateTime(tomorrow),
          onTap: () => _enterForm(tomorrow),
        ),
        _WhenTile(
          icon: Icons.edit_calendar,
          label: '自选日期时间…',
          onTap: _pickCustom,
        ),
        _WhenTile(
          icon: Icons.waves,
          label: '不排期',
          detail: '进任务池',
          onTap: () => _enterForm(null),
        ),
      ],
    );
  }

  Widget _buildFormPage(ThemeData theme) {
    return Column(
      key: const ValueKey('form'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TaskFormBody(
          controller: widget.controller,
          value: _value,
          onChanged: (v) => setState(() => _value = v),
          titleCtrl: _titleCtrl,
          noteCtrl: _noteCtrl,
          workCtrl: _workCtrl,
          autofocusTitle: true,
          onSubmit: _submit,
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

/// 日期档位一行：图标 + 档名 + 右侧日期。
class _WhenTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? detail;
  final VoidCallback onTap;

  const _WhenTile({
    required this.icon,
    required this.label,
    this.detail,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      leading: Icon(icon, color: AppColors.accent),
      title: Text(label),
      trailing: detail == null
          ? null
          : Text(
              detail!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
      onTap: onTap,
    );
  }
}

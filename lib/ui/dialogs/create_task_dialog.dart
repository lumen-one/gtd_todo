import 'package:flutter/material.dart';

import '../../domain/task.dart';
import '../app_controller.dart';
import '../theme.dart';

/// 创建流程（§5.1，v0.11 去手势化）：类型与日期档位**常驻**在对话框里，确认键纯点按。
/// - 标题首焦点；回车 = 跳到备注（对话框上有提示文案）；
/// - 类型档位【三无 / 有截止 / 定点】，默认『三无』；点后两个才升起日期档位
///   （有截止 → 今天 / 明天 / 自选…；定点 → 只给自选…）；点回『三无』清掉已选日期；
/// - 确认 = 纯点按：三无态直接建三无入池散件段；选了类型但没选日期 → 弹日期+时间弹窗。
enum CreateKind { plain, withDeadline, fixedAtTime }

/// 选日期+时间的级联弹窗（fixed 与 flex·有截止 共用）。
Future<DateTime?> pickDateTime(
  BuildContext context, {
  DateTime? initial,
  String title = '什么时候？',
}) async {
  final now = DateTime.now();
  final base = initial ?? now;
  final date = await showDatePicker(
    context: context,
    initialDate: base,
    firstDate: DateTime(now.year - 1),
    lastDate: DateTime(now.year + 2),
    helpText: title,
  );
  if (date == null || !context.mounted) return null;
  final time = await showTimePicker(
    context: context,
    initialTime: TimeOfDay(hour: base.hour, minute: 0),
  );
  if (time == null) return null;
  return DateTime(date.year, date.month, date.day, time.hour, time.minute);
}

/// 『今天』/『明天』这两个快捷档位落在该日 18:00（§5.1 第 4 条）。
DateTime _dayCutoff(DateTime base) =>
    DateTime(base.year, base.month, base.day, 18);

String _format(DateTime d) =>
    '${d.month}-${d.day.toString().padLeft(2, '0')} '
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

/// 打开创建对话框并完成后续（缺日期时弹日期弹窗 / 直接入池）。各面板与壳共用。
Future<void> showCreateFlow(
  BuildContext context,
  AppController controller,
) async {
  final result = await showDialog<_CreateResult>(
    context: context,
    builder: (_) => const _CreateTaskDialog(),
  );
  if (result == null || !context.mounted) return;
  final title = result.title.trim();
  if (title.isEmpty) return;
  var date = result.date;
  if (result.kind != CreateKind.plain && date == null) {
    date = await pickDateTime(
      context,
      title: result.kind == CreateKind.fixedAtTime ? '固定时点：哪天几点？' : '截止到哪天？',
    );
    if (date == null) return;
  }
  await controller.createTask(
    title: title,
    description: result.description,
    type: result.kind == CreateKind.fixedAtTime
        ? TaskType.fixed
        : TaskType.flex,
    deadline: date,
  );
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(content: Text('已创建'), duration: Duration(seconds: 2)),
  );
}

class _CreateResult {
  final CreateKind kind;
  final DateTime? date;
  final String title;
  final String description;

  const _CreateResult(this.kind, this.date, this.title, this.description);
}

class _CreateTaskDialog extends StatefulWidget {
  const _CreateTaskDialog();

  @override
  State<_CreateTaskDialog> createState() => _CreateTaskDialogState();
}

class _CreateTaskDialogState extends State<_CreateTaskDialog> {
  final _titleCtrl = TextEditingController();
  final _noteCtrl = TextEditingController();
  final _titleFocus = FocusNode();
  final _noteFocus = FocusNode();

  CreateKind _kind = CreateKind.plain; // 默认三无
  DateTime? _date; // 三无态恒为 null

  @override
  void dispose() {
    _titleCtrl.dispose();
    _noteCtrl.dispose();
    _titleFocus.dispose();
    _noteFocus.dispose();
    super.dispose();
  }

  DateTime get _today => _dayCutoff(DateTime.now());
  DateTime get _tomorrow =>
      _dayCutoff(DateTime.now().add(const Duration(days: 1)));

  void _pickKind(CreateKind kind) {
    setState(() {
      _kind = kind;
      if (kind == CreateKind.plain) _date = null; // 点回三无 → 清掉已选日期
    });
  }

  void _pickDay(DateTime day) => setState(() => _date = day);

  Future<void> _pickCustom() async {
    final dt = await pickDateTime(
      context,
      title: _kind == CreateKind.fixedAtTime ? '固定时点：哪天几点？' : '截止到哪天？',
    );
    if (dt == null || !mounted) return;
    setState(() => _date = dt);
  }

  void _confirm() {
    Navigator.of(
      context,
    ).pop(_CreateResult(_kind, _date, _titleCtrl.text, _noteCtrl.text));
  }

  String get _hint {
    switch (_kind) {
      case CreateKind.plain:
        return '点确认 = 稍后整理（入池散件段）';
      case CreateKind.withDeadline:
        return _date == null ? '点确认会先问截止到哪天' : '截止 ${_format(_date!)}';
      case CreateKind.fixedAtTime:
        return _date == null ? '点确认会先问哪天几点' : '定点 ${_format(_date!)}';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final today = _today;
    final tomorrow = _tomorrow;
    final customPicked = _date != null && _date != today && _date != tomorrow;
    return Dialog(
      backgroundColor: theme.cardTheme.color,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('新建待办', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              '回车 = 跳到备注 · 直接点确认 = 三无',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _titleCtrl,
              focusNode: _titleFocus,
              autofocus: true,
              textInputAction: TextInputAction.next,
              onSubmitted: (_) => _noteFocus.requestFocus(),
              decoration: const InputDecoration(hintText: '标题…'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _noteCtrl,
              focusNode: _noteFocus,
              maxLines: 2,
              minLines: 1,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _confirm(),
              decoration: const InputDecoration(hintText: '备注…（选填）'),
            ),
            const SizedBox(height: 12),
            Text(
              '类型',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: _Chip(
                    label: '三无',
                    icon: Icons.waves,
                    selected: _kind == CreateKind.plain,
                    onTap: () => _pickKind(CreateKind.plain),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _Chip(
                    label: '有截止',
                    icon: Icons.event,
                    selected: _kind == CreateKind.withDeadline,
                    onTap: () => _pickKind(CreateKind.withDeadline),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _Chip(
                    label: '定点',
                    icon: Icons.push_pin,
                    selected: _kind == CreateKind.fixedAtTime,
                    onTap: () => _pickKind(CreateKind.fixedAtTime),
                  ),
                ),
              ],
            ),
            if (_kind != CreateKind.plain) ...[
              const SizedBox(height: 10),
              Text(
                '日期',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  if (_kind == CreateKind.withDeadline) ...[
                    Expanded(
                      child: _Chip(
                        label: '今天',
                        icon: Icons.today,
                        selected: _date == today,
                        onTap: () => _pickDay(today),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _Chip(
                        label: '明天',
                        icon: Icons.event_note,
                        selected: _date == tomorrow,
                        onTap: () => _pickDay(tomorrow),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: _Chip(
                      label: customPicked ? _format(_date!) : '自选…',
                      icon: Icons.more_time,
                      selected: customPicked,
                      onTap: _pickCustom,
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 12),
            GestureDetector(
              onTap: _confirm,
              child: Container(
                height: 52,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppColors.accent,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Text(
                  '✱ 确认',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 2,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Center(
              child: Text(
                _hint,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 档位按钮（类型与日期共用）：选中 = 强调色填充，未选中 = 描边。
class _Chip extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  const _Chip({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 橙只给关键元素（§8）：选中态用强调色填充，未选中退回中性描边。
    final color = selected ? Colors.white : theme.colorScheme.onSurfaceVariant;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        height: 44,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected
              ? AppColors.accent
              : AppColors.accent.withValues(alpha: 0.10),
          border: Border.all(
            color: selected ? AppColors.accent : theme.colorScheme.outline,
            width: 1.2,
          ),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: color, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

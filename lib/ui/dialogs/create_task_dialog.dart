import 'package:flutter/material.dart';

import '../../domain/task.dart';
import '../app_controller.dart';
import '../theme.dart';

/// 创建流程（§5.1）：完整对话框（侧边栏内弹出）→ 分类档位 → 日期弹窗。
/// - 标题首焦点；回车 = 跳到备注（对话框常驻提示文案）；
/// - 确认键手势 = 按住不松一滑到底：长按升起档位，滑到"不可推"→ 弹日期弹窗；
///   滑到"可推"→ 档位再二分一次（有截止日 / 无截止日）；
/// - 直接点按 = 默认创建三无（可推、无截止、无提醒），之后可再编辑补属性。
enum CreateIntent { fixedAtTime, flexWithDeadline, flexNoDeadline }

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

/// 打开创建对话框并完成后续（选日期 / 直接入池）。各面板与壳共用。
Future<void> showCreateFlow(BuildContext context, AppController controller,
    {bool jumpToDate = true}) async {
  final result = await showDialog<_CreateResult>(
    context: context,
    builder: (_) => const _CreateTaskDialog(),
  );
  if (result == null || !context.mounted) return;
  final title = result.title.trim();
  if (title.isEmpty) return;
  final messenger = ScaffoldMessenger.of(context);
  switch (result.intent) {
    case CreateIntent.fixedAtTime:
      final dt = await pickDateTime(context, title: '固定时点：哪天几点？');
      if (dt == null) return;
      await controller.createTask(
        title: title,
        description: result.description,
        type: TaskType.fixed,
        deadline: dt,
      );
    case CreateIntent.flexWithDeadline:
      final dt = await pickDateTime(context, title: '截止到哪天？');
      if (dt == null) return;
      await controller.createTask(
        title: title,
        description: result.description,
        type: TaskType.flex,
        deadline: dt,
      );
    case CreateIntent.flexNoDeadline:
      await controller.createTask(
        title: title,
        description: result.description,
      );
    case null:
      return;
  }
  messenger.showSnackBar(
    const SnackBar(content: Text('已创建'), duration: Duration(seconds: 2)),
  );
}

class _CreateResult {
  final CreateIntent? intent;
  final String title;
  final String description;

  const _CreateResult(this.intent, this.title, this.description);
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
  final _optionsKey = GlobalKey();

  bool _active = false; // 长按进行中（档位升起）
  bool _stage2 = false; // 可推已二分（有截止 / 无截止）
  int? _hover; // 0 = 左目标，1 = 右目标

  @override
  void dispose() {
    _titleCtrl.dispose();
    _noteCtrl.dispose();
    _titleFocus.dispose();
    _noteFocus.dispose();
    super.dispose();
  }

  void _pop(CreateIntent? intent) {
    Navigator.of(context).pop(_CreateResult(
      intent,
      _titleCtrl.text,
      _noteCtrl.text,
    ));
  }

  void _onMoveUpdate(LongPressMoveUpdateDetails d) {
    final box =
        _optionsKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final local = box.globalToLocal(d.globalPosition);
    final size = box.size;
    int? hover;
    if (local.dy >= 0 && local.dy <= size.height) {
      hover = local.dx < size.width / 2 ? 0 : 1;
    } else {
      hover = null;
    }
    var stage2 = _stage2;
    if (!_stage2 && _active && hover == 1) stage2 = true; // 滑入"可推"→ 二分
    if (hover != _hover || stage2 != _stage2) {
      setState(() {
        _hover = hover;
        _stage2 = stage2;
      });
    }
  }

  void _onEnd(LongPressEndDetails d) {
    final intent = _resolve(_stage2, _hover);
    setState(() {
      _active = false;
      _stage2 = false;
      _hover = null;
    });
    if (intent != null) {
      _pop(intent);
    }
  }

  static CreateIntent? _resolve(bool stage2, int? hover) {
    if (hover == null) return null;
    if (!stage2) return hover == 0 ? CreateIntent.fixedAtTime : null;
    return hover == 0
        ? CreateIntent.flexWithDeadline
        : CreateIntent.flexNoDeadline;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
            Text('回车 = 跳到备注 · 长按确认滑档位 · 直接点按 = 三无',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
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
              onSubmitted: (_) => _pop(CreateIntent.flexNoDeadline),
              decoration: const InputDecoration(hintText: '备注…（选填）'),
            ),
            const SizedBox(height: 10),
            // 档位区：长按后原地升起，滑入"可推"再二分一次
            SizedBox(
              key: _optionsKey,
              height: 52,
              child: _active
                  ? Row(
                      children: [
                        Expanded(
                          child: _TargetPill(
                            label: _stage2 ? '有截止日' : '不可推',
                            icon: _stage2 ? Icons.event : Icons.push_pin,
                            hovered: _hover == 0,
                            emphasize: !_stage2,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _TargetPill(
                            label: _stage2 ? '无截止日' : '可推',
                            icon: _stage2 ? Icons.waves : Icons.schedule,
                            hovered: _hover == 1,
                            emphasize: false,
                          ),
                        ),
                      ],
                    )
                  : Center(
                      child: Text(
                        '长按确认，档位在这里升起',
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ),
            ),
            const SizedBox(height: 4),
            GestureDetector(
              onLongPressStart: (_) => setState(() => _active = true),
              onLongPressMoveUpdate: _onMoveUpdate,
              onLongPressEnd: _onEnd,
              onLongPressCancel: () => setState(() {
                _active = false;
                _stage2 = false;
                _hover = null;
              }),
              onTap: () => _pop(CreateIntent.flexNoDeadline),
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
                      letterSpacing: 2),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Center(
              child: Text(
                '点按 = 稍后整理（入池散件段）',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TargetPill extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool hovered;
  final bool emphasize;

  const _TargetPill({
    required this.label,
    required this.icon,
    required this.hovered,
    required this.emphasize,
  });

  @override
  Widget build(BuildContext context) {
    final color = hovered
        ? AppColors.accent
        : emphasize
            ? AppColors.accent.withValues(alpha: 0.85)
            : Theme.of(context).colorScheme.outline;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      height: 46,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: hovered
            ? AppColors.accent
            : AppColors.accent.withValues(alpha: 0.10),
        border: Border.all(color: color, width: hovered ? 0 : 1.2),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 16, color: hovered ? Colors.white : color),
          const SizedBox(width: 6),
          Text(label,
              style: TextStyle(
                color: hovered ? Colors.white : color,
                fontWeight: FontWeight.w600,
              )),
        ],
      ),
    );
  }
}

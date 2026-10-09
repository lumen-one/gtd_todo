import 'package:flutter/material.dart';

import '../../application/notes_reader.dart';
import '../app_controller.dart';
import '../theme.dart';

/// 第 2 页：疑问笔记（ui-interaction.md §6.2）。
/// 数据源 = 用户在 Obsidian 维护的指定 Markdown（路径在设置里配）。
/// App 只读，编辑去 Obsidian；frontmatter 一个字符都不动（零写入）。
/// 显示 frontmatter 闭合后到下一个 --- 之间的正文段；含 [[ 的整行屏蔽。
class NotesPanel extends StatefulWidget {
  final AppController controller;

  const NotesPanel({super.key, required this.controller});

  @override
  State<NotesPanel> createState() => _NotesPanelState();
}

class _NotesPanelState extends State<NotesPanel> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChange);
    _load();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    await widget.controller.refreshNotes();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final result = widget.controller.notes;

    if (result == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final body = switch (result.status) {
      NotesStatus.notConfigured => const _Empty(
          icon: Icons.menu_book_outlined,
          text: '未找到疑问笔记，去设置选择文件',
        ),
      NotesStatus.notFound => const _Empty(
          icon: Icons.file_present,
          text: '未找到疑问笔记，去设置选择文件',
        ),
      NotesStatus.empty => const _Empty(
          icon: Icons.filter_alt_off_outlined,
          text: '这一段没有可显示的内容',
        ),
      NotesStatus.ok => ListView(
          padding: const EdgeInsets.fromLTRB(18, 10, 18, 24),
          children: [
            Text(result.lines.join('\n'),
                style: theme.textTheme.bodyMedium?.copyWith(height: 1.6)),
          ],
        ),
    };

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 10, 18, 4),
          child: Row(
            children: [
              Icon(Icons.menu_book_outlined,
                  size: 16, color: AppColors.accent),
              const SizedBox(width: 6),
              Text('疑问笔记（只读）', style: theme.textTheme.labelMedium),
              const Spacer(),
              IconButton(
                tooltip: '重新读取',
                icon: const Icon(Icons.refresh, size: 18),
                onPressed: _load,
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(child: body),
      ],
    );
  }
}

class _Empty extends StatelessWidget {
  final IconData icon;
  final String text;

  const _Empty({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: Theme.of(context).colorScheme.onSurfaceVariant),
            const SizedBox(height: 8),
            Text(text),
          ],
        ),
      );
}

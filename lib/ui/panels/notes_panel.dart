import 'package:flutter/material.dart';

import '../../application/notes_reader.dart';
import '../app_controller.dart';
import '../theme.dart';

/// 灵感页（ui-interaction.md §6.2；页序见 `ui/panel_pages.dart`）。
/// 数据源 = 用户在 Obsidian 维护的指定 Markdown（路径在设置里配）。
/// **可就地编辑**：只替换正文段，frontmatter 与其他段落一个字符都不动（v1.29）。
/// 显示 frontmatter 闭合后到下一个 --- 之间的正文段；含 [[ 的整行屏蔽。
class NotesPanel extends StatefulWidget {
  final AppController controller;

  const NotesPanel({super.key, required this.controller});

  @override
  State<NotesPanel> createState() => _NotesPanelState();
}

class _NotesPanelState extends State<NotesPanel> {
  final _textCtrl = TextEditingController();
  bool _editing = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChange);
    // 读到**帧后**再读笔记：本页是第一页，面板展开时就是在这里首次挂载，
    // 直接在 initState 里读会同步 notifyListeners → 祖先宿主 setState，
    // 框架报 "setState() called during build"（v1.24 页序一换就撞上了）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  @override
  void dispose() {
    _textCtrl.dispose();
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

  /// 进编辑态：初值取正文段**完整**原文——只读态被 `[[` 屏蔽的行也要带进来，
  /// 否则保存一次就把那些行抹掉了（§6.2）。
  void _startEdit(NotesReadResult r) {
    _textCtrl.text = r.bodyLines.join('\n');
    setState(() => _editing = true);
  }

  void _cancelEdit() {
    setState(() => _editing = false);
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final ok = await widget.controller.saveNotes(_textCtrl.text);
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (ok) _editing = false;
    });
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('灵感没存上：文件不可写，或 frontmatter 未闭合')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final result = widget.controller.notes;

    if (result == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 10, 18, 4),
          child: Row(
            children: [
              Icon(Icons.menu_book_outlined,
                  size: 16, color: AppColors.accent),
              const SizedBox(width: 6),
              // 页名归面板头，这里不重复；只标"正在编辑"这个瞬时状态。
              if (_editing) Text('编辑中', style: theme.textTheme.labelMedium),
              const Spacer(),
              if (_editing) ...[
                IconButton(
                  tooltip: '取消',
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: _saving ? null : _cancelEdit,
                ),
                IconButton(
                  tooltip: '保存',
                  icon: _saving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.check, size: 18),
                  onPressed: _saving ? null : _save,
                ),
              ] else ...[
                if (result.canEdit)
                  IconButton(
                    tooltip: '编辑',
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    onPressed: () => _startEdit(result),
                  ),
                IconButton(
                  tooltip: '重新读取',
                  icon: const Icon(Icons.refresh, size: 18),
                  onPressed: _load,
                ),
              ],
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(child: _editing ? _editor(theme) : _viewer(theme, result)),
      ],
    );
  }

  Widget _editor(ThemeData theme) => Padding(
        padding: const EdgeInsets.fromLTRB(18, 10, 18, 12),
        child: TextField(
          controller: _textCtrl,
          expands: true,
          maxLines: null,
          minLines: null,
          textAlignVertical: TextAlignVertical.top,
          keyboardType: TextInputType.multiline,
          style: theme.textTheme.bodyMedium?.copyWith(height: 1.6),
          decoration: const InputDecoration(
            border: InputBorder.none,
            isDense: true,
            hintText: '写点什么…',
          ),
        ),
      );

  Widget _viewer(ThemeData theme, NotesReadResult result) =>
      switch (result.status) {
        NotesStatus.notConfigured => const _Empty(
            icon: Icons.menu_book_outlined,
            text: '未找到灵感，去设置选择文件',
          ),
        NotesStatus.notFound => const _Empty(
            icon: Icons.file_present,
            text: '未找到灵感，去设置选择文件',
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
}

class _Empty extends StatelessWidget {
  final IconData icon;
  final String text;

  const _Empty({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) => Center(
        child: FadeIn(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon,
                  size: 40,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
              const SizedBox(height: 8),
              Text(text),
            ],
          ),
        ),
      );
}

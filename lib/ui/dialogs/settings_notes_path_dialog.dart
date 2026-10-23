import 'package:flutter/material.dart';

import '../app_controller.dart';

/// 灵感文件路径编辑（设置页「灵感」区）：Obsidian 里那篇 Markdown；
/// App 就地改它的**正文段**，frontmatter 与其他段落不动（§6.2）。
Future<void> showSettingsNotesPathDialog(
    BuildContext context, AppController c) async {
  final ctrl = TextEditingController(text: c.settings.notesPath ?? '');
  // isScrollControlled + viewInsets：底部弹窗不会自己给键盘让位，少了这两样
  // 输入框正好落在键盘底下（跟编辑任务表单同一招，见 edit_task_sheet.dart）。
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
            16, 16, 16, 16 + MediaQuery.of(ctx).viewInsets.bottom),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('灵感文件路径', style: Theme.of(ctx).textTheme.titleSmall),
              const SizedBox(height: 4),
              Text('灵感页可就地编辑正文段，frontmatter 不动',
                  style: Theme.of(ctx).textTheme.bodySmall),
              const SizedBox(height: 10),
              TextField(
                controller: ctrl,
                decoration: const InputDecoration(
                    labelText: '文件路径', hintText: '/storage/…/灵感.md'),
              ),
              const SizedBox(height: 10),
              FilledButton.icon(
                icon: const Icon(Icons.file_open),
                label: const Text('用系统选择器挑一个文件'),
                onPressed: () async {
                  final picked = await c.pickNotesFile();
                  if (!ctx.mounted) return;
                  if (picked == null) {
                    ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(
                        content: Text('未选择文件（或缺少"所有文件访问"权限）')));
                    return;
                  }
                  ctrl.text = picked;
                },
              ),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: () async {
                  final path = ctrl.text.trim();
                  Navigator.of(ctx).pop();
                  await c.updateSettings(path.isEmpty
                      ? c.settings.copyWith(clearNotesPath: true)
                      : c.settings.copyWith(notesPath: path));
                  await c.refreshNotes();
                },
                child: const Text('保存'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

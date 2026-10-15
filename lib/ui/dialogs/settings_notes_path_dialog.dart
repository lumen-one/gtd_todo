import 'package:flutter/material.dart';

import '../app_controller.dart';

/// 疑问笔记路径编辑（设置页「疑问笔记」区）：Obsidian 里那篇笔记（Markdown）；
/// App 只读，编辑仍回 Obsidian。
Future<void> showSettingsNotesPathDialog(
    BuildContext context, AppController c) async {
  final ctrl = TextEditingController(text: c.settings.notesPath ?? '');
  await showModalBottomSheet<void>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('疑问笔记路径', style: Theme.of(ctx).textTheme.titleSmall),
            const SizedBox(height: 4),
            Text('App 只读，编辑仍回 Obsidian',
                style: Theme.of(ctx).textTheme.bodySmall),
            const SizedBox(height: 10),
            TextField(
              controller: ctrl,
              decoration: const InputDecoration(
                  labelText: '文件路径', hintText: '/storage/…/疑问笔记.md'),
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
  );
}

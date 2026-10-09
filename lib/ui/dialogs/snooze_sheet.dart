import 'package:flutter/material.dart';

import '../../domain/task.dart';
import '../app_controller.dart';
import '../theme.dart';

/// 推迟档位（ui-interaction.md §7.2 / 决议 16/26）：
/// 相对档位 30 分钟 / 1 小时 / 3 小时——落静默段由 NotificationWindowRule
/// 顺延到下一时段开头（只顺延、不吞掉）；
/// 绝对档位 明早 9 点 / 自选——原样响，不经静默段顺延；
/// 跨休息段显式选项"到下个工作窗"（architecture.md D8）。
class SnoozeSheet extends StatelessWidget {
  final AppController controller;
  final Task task;

  const SnoozeSheet({super.key, required this.controller, required this.task});

  Future<void> _pickCustom(BuildContext context) async {
    final now = DateTime.now();
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(now.add(const Duration(hours: 1))),
    );
    if (time == null) return;
    final until =
        DateTime(now.year, now.month, now.day, time.hour, time.minute);
    final target =
        until.isAfter(now) ? until : until.add(const Duration(days: 1));
    await controller.snoozeUntil(task.id, until: target);
  }

  @override
  Widget build(BuildContext context) {
    final tomorrow9 = DateTime(
      DateTime.now().year,
      DateTime.now().month,
      DateTime.now().day + 1,
      9,
    );
    final entries = <(String, IconData, Future<void> Function())>[
      ('30 分钟', Icons.schedule, () => controller.snooze(task.id, minutes: 30)),
      ('1 小时', Icons.schedule, () => controller.snooze(task.id, minutes: 60)),
      ('3 小时', Icons.schedule, () => controller.snooze(task.id, minutes: 180)),
      (
        '明早 9 点',
        Icons.wb_twilight,
        () => controller.snoozeUntil(task.id, until: tomorrow9)
      ),
      ('自选时间…', Icons.edit_calendar, () => _pickCustom(context)),
      (
        '到下个工作窗',
        Icons.skip_next,
        () => controller.snoozeToNextWindow(task.id)
      ),
    ];

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 12, 8, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text('推迟到什么时候？', style: Theme.of(context).textTheme.titleSmall),
            ),
            for (final (label, icon, action) in entries)
              ListTile(
                leading: Icon(icon, color: AppColors.accent),
                title: Text(label),
                onTap: () async {
                  Navigator.of(context).pop();
                  try {
                    await action();
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('操作失败：$e')),
                      );
                    }
                  }
                },
              ),
          ],
        ),
      ),
    );
  }
}

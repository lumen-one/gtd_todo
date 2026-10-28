import 'package:flutter/material.dart';

import '../../domain/task.dart';

/// 日期 + 时间的级联弹窗，任一步取消即返回 null。
///
/// 编辑表单的『选时间』、日历里改期两处问的是同一件事，所以形状只有这一种——
/// 别在各自的文件里再写一遍。
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

/// 该日的默认时刻，按任务类型分。
///
/// 截止型取 **18:00**——当日工作窗末尾，"今天做完"的安全上界；落在更早的钟点
/// 会把半天当成一天，下午建的任务一出生就逾期。
///
/// 开始型取 **12:00**——午前收尾、午后动手的常用起点。开始型不进调度，没有
/// 工期问题，这个时刻只是"到点响一次"的落点。
DateTime atDefaultHour(DateTime day, TaskType type) => DateTime(
    day.year, day.month, day.day, type == TaskType.fixed ? 12 : 18);

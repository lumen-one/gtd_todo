import 'package:flutter/material.dart';

/// 日期 + 时间的级联弹窗，任一步取消即返回 null。
///
/// 新建的『自选…』、编辑表单的『选时间』、日历里改期三处问的是同一件事，
/// 所以形状只有这一种——别在各自的文件里再写一遍。
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

/// 该日 18:00：当日工作窗末尾的常用截止点（『今天』『明天』两档的落点）。
DateTime dayAt18(DateTime base) =>
    DateTime(base.year, base.month, base.day, 18);

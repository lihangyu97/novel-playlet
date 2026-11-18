import 'package:flutter/material.dart';

/// 日志类页面（同步记录 / 运行日志）共用的日期分隔标题。
///
/// 两个页面都是「按时间倒序、按天分组」的结构，分组的留白与字重只在这里维护。
class LogDayHeader extends StatelessWidget {
  const LogDayHeader({super.key, required this.day});

  final DateTime day;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 6),
      child: Text(
        logDayLabel(day),
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: scheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// `14:05`：列表行首的时间，列宽固定，等宽数字在调用方设置。
String logTimeLabel(DateTime time) =>
    '${time.hour.toString().padLeft(2, '0')}:'
    '${time.minute.toString().padLeft(2, '0')}';

/// 今天 / 昨天 / `11 月 18 日`。[now] 只给测试用。
String logDayLabel(DateTime day, {DateTime? now}) {
  final reference = now ?? DateTime.now();
  if (isSameCalendarDay(day, reference)) return '今天';
  if (isSameCalendarDay(day, reference.subtract(const Duration(days: 1)))) {
    return '昨天';
  }
  return '${day.month} 月 ${day.day} 日';
}

bool isSameCalendarDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

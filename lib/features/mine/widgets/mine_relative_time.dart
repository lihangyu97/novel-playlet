/// 相对时间只做粗粒度提示：进度/观看记录精确到秒没有意义，反而制造噪音。
String mineRelativeTime(DateTime time) {
  final now = DateTime.now();
  final diff = now.difference(time);
  if (diff.isNegative || diff.inMinutes < 1) return '刚刚';
  if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
  if (diff.inHours < 24) return '${diff.inHours} 小时前';
  final days = DateTime(
    now.year,
    now.month,
    now.day,
  ).difference(DateTime(time.year, time.month, time.day)).inDays;
  if (days == 1) return '昨天';
  if (days < 7) return '$days 天前';
  if (time.year == now.year) return '${time.month} 月 ${time.day} 日';
  return '${time.year} 年 ${time.month} 月 ${time.day} 日';
}

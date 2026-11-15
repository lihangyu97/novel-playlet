/// 相对时间文案：列表/评论/我的页统一一套。
///
/// 粗粒度足够：1 分钟内「刚刚」，1 小时内按分钟、一天内按小时，昨天单独说，
/// 一周内按天；再早给日期（同年省略年份）。精确到秒只会制造噪音。
///
/// [now] 只给测试用，生产环境不传。
String relativeTime(DateTime? time, {DateTime? now}) {
  if (time == null) return '';
  final reference = now ?? DateTime.now();
  final diff = reference.difference(time);
  if (diff.isNegative || diff.inMinutes < 1) return '刚刚';
  if (diff.inMinutes < 60) return '${diff.inMinutes}分钟前';
  if (diff.inHours < 24) return '${diff.inHours}小时前';
  // 超过一天后按日历日算：「昨天」比「35小时前」更好读。
  final days = DateTime(
    reference.year,
    reference.month,
    reference.day,
  ).difference(DateTime(time.year, time.month, time.day)).inDays;
  if (days == 1) return '昨天';
  if (days < 7) return '$days天前';
  if (time.year == reference.year) return '${time.month}月${time.day}日';
  return '${time.year}年${time.month}月${time.day}日';
}

import '../../../core/relative_time.dart';

/// 兼容旧调用点：我的页统一走 App 同一套相对时间。
String mineRelativeTime(DateTime time) => relativeTime(time);

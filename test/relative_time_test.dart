import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/core/relative_time.dart';

/// 全 App 的统一相对时间：我的页、书评/剧评、段评回复都走这一份。
void main() {
  final now = DateTime(2026, 11, 15, 21, 30);

  test('空时间返回空串', () {
    expect(relativeTime(null, now: now), '');
  });

  test('一分钟内 / 分钟 / 小时', () {
    expect(
      relativeTime(now.subtract(const Duration(seconds: 20)), now: now),
      '刚刚',
    );
    expect(
      relativeTime(now.subtract(const Duration(minutes: 5)), now: now),
      '5分钟前',
    );
    expect(
      relativeTime(now.subtract(const Duration(hours: 3)), now: now),
      '3小时前',
    );
  });

  test('跨天按日历日算：昨天 / 几天前', () {
    // 一天内优先按小时/分钟：23:50 → 次日 00:10 仍是「20分钟前」。
    expect(
      relativeTime(
        DateTime(2026, 11, 14, 23, 50),
        now: DateTime(2026, 11, 15, 0, 10),
      ),
      '20分钟前',
    );
    // 超过一天、且日历日只差一天：昨天（而不是「35小时前」）。
    expect(relativeTime(DateTime(2026, 11, 14, 10), now: now), '昨天');
    expect(relativeTime(DateTime(2026, 11, 13, 12), now: now), '2天前');
    expect(relativeTime(DateTime(2026, 11, 9, 12), now: now), '6天前');
  });

  test('更早给日期：同年省略年份', () {
    expect(relativeTime(DateTime(2026, 10, 20, 12), now: now), '10月20日');
    expect(relativeTime(DateTime(2025, 12, 31, 12), now: now), '2025年12月31日');
  });

  test('未来时间当成刚刚（时钟偏差不显示负数）', () {
    expect(relativeTime(now.add(const Duration(minutes: 5)), now: now), '刚刚');
  });
}

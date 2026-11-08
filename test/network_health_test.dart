import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/features/video/network_health.dart';

void main() {
  test('网络类失败后 TTL 内视为疑似离线，成功后恢复', () {
    var now = DateTime(2026, 11, 8, 12);
    final health = NetworkHealth(now: () => now);

    expect(health.isSuspectedOffline, isFalse);
    health.recordFailure();
    expect(health.isSuspectedOffline, isTrue);

    now = now.add(const Duration(seconds: 89));
    expect(health.isSuspectedOffline, isTrue, reason: 'TTL 内继续快速失败');

    now = now.add(const Duration(seconds: 2));
    expect(
      health.isSuspectedOffline,
      isFalse,
      reason: 'TTL 过期后必须愿意再试一次网络，避免偶发超时把播放页钉死',
    );

    health.recordFailure();
    health.recordSuccess();
    expect(health.isSuspectedOffline, isFalse, reason: '取流成功清掉标记');

    health.recordFailure();
    health.clear();
    expect(health.isSuspectedOffline, isFalse, reason: '手动重试清掉标记');
  });
}

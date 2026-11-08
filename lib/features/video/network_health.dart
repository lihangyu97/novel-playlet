import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 会话级「网络大概不可用」信号。
///
/// 播放页在没有离线副本时，只能靠一次真实取流来确认网络是否可用；断网或
/// 黑洞网络下这次取流会先耗掉内核的重试预算（几十秒），用户切下一集时又要
/// 再付一次。这里记住「刚发生过网络类失败」，后续切集直接给可操作文案，
/// 不再重复等待；任一次取流成功、或用户手动重试都会清除标记。
///
/// 只做保守推断：TTL 到期后自动恢复成「愿意再试一次」，避免一次偶发超时把
/// 播放页永久钉在「未离线缓存」上。
class NetworkHealth {
  NetworkHealth({DateTime Function()? now, this.suspicionTtl = _defaultTtl})
    : _now = now ?? DateTime.now;

  static const Duration _defaultTtl = Duration(seconds: 90);

  /// 失败后多久内把后续取流当成「大概率没网」。取 90s 是因为它要盖住
  /// 「连点下一集/自动续播」这段连续操作，又不至于让网络恢复后一直不重试。
  final Duration suspicionTtl;

  final DateTime Function() _now;
  DateTime? _lastFailureAt;

  bool get isSuspectedOffline {
    final at = _lastFailureAt;
    return at != null && _now().difference(at) < suspicionTtl;
  }

  /// 一次取流以「网络不可达」特征失败（超时/连接类错误）。
  void recordFailure() => _lastFailureAt = _now();

  /// 一次取流真正成功：网络可用，清掉标记。
  void recordSuccess() => _lastFailureAt = null;

  /// 用户主动重试：无条件再给网络一次机会。
  void clear() => _lastFailureAt = null;
}

final networkHealthProvider = Provider<NetworkHealth>((ref) => NetworkHealth());

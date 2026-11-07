import 'dart:async';
import 'dart:io';

import '../../data/models/json_utils.dart';

/// 一集播放的取源方式。
///
/// 播放链路统一为：**离线 → 自动缓存 → 网络**。自动缓存（内核 `backend/src/`
/// 的密文临时缓存）对播放器不可见，所以这里只有「离线明文 mp4」和「在线
/// `/src` 流」两种来源；未命中且确认离线时不再做无谓的网络等待。
enum EpisodePlaybackSource {
  /// 离线命中：用本地明文 mp4 播放，不联网、无「准备播放」阶段。
  localFile,

  /// 未命中：走现有 `api.videoSource` → `/src` 在线流程（含失败原因/重试）。
  network,

  /// 确认离线且没有离线副本：直接给明确文案，不让用户等内核重试到超时。
  offlineMiss,
}

/// 一集播放的取源计划（[resolveOfflineEpisode] 的返回值）。
class EpisodePlaybackPlan {
  const EpisodePlaybackPlan(this.source, {this.file});

  final EpisodePlaybackSource source;

  /// 仅 [EpisodePlaybackSource.localFile] 时非空。
  final File? file;

  bool get isLocal => source == EpisodePlaybackSource.localFile;

  /// 「离线且未缓存」错误页的标题 / 说明。文案是产品要求，改动前先确认。
  static const String offlineMissTitle = '该集未离线缓存';
  static const String offlineMissReason =
      '该集未离线缓存，请联网后观看；也可以先在详情页用「离线缓存」把整剧下载下来。';
}

/// 纯决策：这一集该用本地文件还是网络。
///
/// - [cachedFile]：离线区命中结果。存储层已把 0 字节/损坏文件当成未命中
///   （返回 null），这里只做判断，不做 IO，方便单测。
/// - [offline]：是否**确认**离线。App 没有 connectivity 插件，「确认离线」
///   只能在取流失败后由 [isOfflineNetworkFailure] 推断；无法确认时传 false
///   —— 宁可让网络请求失败给出具体原因，也不要因为探测不到网络就拒绝播放。
///
/// 优先级：离线副本 > 网络。离线副本命中时完全不碰网络。
EpisodePlaybackPlan resolveOfflineEpisode({
  required File? cachedFile,
  required bool offline,
}) {
  if (cachedFile != null) {
    return EpisodePlaybackPlan(
      EpisodePlaybackSource.localFile,
      file: cachedFile,
    );
  }
  if (offline) {
    return const EpisodePlaybackPlan(EpisodePlaybackSource.offlineMiss);
  }
  return const EpisodePlaybackPlan(EpisodePlaybackSource.network);
}

/// 取流失败是否属于「网络不可达」（而不是上游/鉴权/解码错误）。
///
/// 播放页拿不到系统网络状态，只能从失败特征判断。命中这里、且这一集没有
/// 离线副本时，页面把泛化错误换成 [EpisodePlaybackPlan.offlineMissReason]，
/// 用户能直接照做，而不是对着内核的英文网络错误发呆。
///
/// 判定口径：
/// - 内核超时（`ApiException.kind == timeout`）—— 离线时最常见的形态；
/// - `ApiException.kind == unknown` 且消息带连接类关键字 —— 内核把 reqwest 的
///   Network 错误映射成 `unknown`（见 rust `endpoints/base.rs`）；
/// - 直接抛出的 [SocketException] / [HttpException] / [HandshakeException]。
///
/// 上游 5xx / 鉴权 / 体积超限等确定性错误不算离线，保留原来的错误页与重试。
bool isOfflineNetworkFailure(Object error) {
  if (error is ApiException) {
    return switch (error.kind) {
      ApiErrorKind.timeout => true,
      ApiErrorKind.unknown => _looksLikeConnectionError(error.message),
      _ => false,
    };
  }
  if (error is TimeoutException) {
    // 499「取消」也会以 TimeoutException 出现（用户切集/退出），取消不是离线，
    // 不能提示「请联网」。
    return error.message != 'backend cancelled';
  }
  return error is SocketException ||
      error is HttpException ||
      error is HandshakeException;
}

const _connectionErrorHints = <String>[
  'dns',
  'connect',
  'connection',
  'network',
  'unreachable',
  'offline',
  'socket',
  'timed out',
  'timeout',
  'failed to lookup',
];

bool _looksLikeConnectionError(String message) {
  final lower = message.toLowerCase();
  for (final hint in _connectionErrorHints) {
    if (lower.contains(hint)) return true;
  }
  return false;
}

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../../data/models/json_utils.dart';
import 'offline_playback.dart';

/// 一次播放失败的可展示信息。
class PlaybackFailure {
  const PlaybackFailure({
    required this.title,
    required this.reason,
    required this.detail,
  });

  /// 一句话标题（如「视频解码失败」）。
  final String title;

  /// 可能原因与建议动作。
  final String reason;

  /// 可复制的技术详情（集 id、地址、原始异常、堆栈前几行）。
  final String detail;
}

/// 生成失败文案所需的上下文：集信息 + 本次取源尝试。
///
/// 只放纯数据，不依赖 `State` / `BuildContext`。页面在 catch 里拼好上下文再
/// 交给 [describePlaybackFailure]，文案决策因此可以在纯 Dart 测试里覆盖。
class PlaybackFailureContext {
  const PlaybackFailureContext({
    required this.seriesTitle,
    required this.episodeTitle,
    required this.episodeId,
    required this.episodeNumber,
    this.sourceUrl = '',
    this.localPath = '',
    this.refreshed = false,
  });

  final String seriesTitle;
  final String episodeTitle;
  final String episodeId;

  /// 1-based 集号（详情里展示「第 N 集」）。
  final int episodeNumber;

  /// 本次失败时最后尝试的播放地址；本地播放时为空。
  final String sourceUrl;

  /// 本次失败时的离线文件路径；在线播放时为空。
  final String localPath;

  /// 本次是否为用户点「重新下载这一集」后的结果。
  final bool refreshed;
}

/// 把播放异常翻译成"人话原因 + 可复制的技术详情"。
///
/// 失败发生在两段：`videoSource`（内核取流/整集下载，抛 ApiException；
/// 504 超时已被 ApiClient 归一成 `ApiException(kind: timeout)`，只有 499 取消
/// 还走 TimeoutException）和 `controller.initialize()`（AVPlayer，抛
/// PlatformException，msg 里带 AVFoundation 的 `Code=-xxxxx`）。
///
/// 纯函数：相同输入必得相同文案，便于单测锁住既有分支（这些文案是产品口径，
/// 改动前先确认）。
PlaybackFailure describePlaybackFailure(
  Object error,
  StackTrace stack, {
  required PlaybackFailureContext context,
}) {
  final raw = error.toString();
  final rawLower = raw.toLowerCase();
  String title;
  String reason;

  // 504 超时（ApiException.kind == timeout）与 499 取消的 TimeoutException
  // 都按"取流超时"展示：超时不再落进通用"取流失败"。
  final timedOut =
      error is TimeoutException ||
      (error is ApiException && error.kind == ApiErrorKind.timeout);
  if (timedOut) {
    title = '取流超时';
    reason = '等内核下载/解密这一集超过 120 秒。常见于网络慢、上游限速，或这一集体积过大。';
  } else if (error is ApiException) {
    title = '取流失败';
    // 具体原因优先；技术兜底换 kind 短句（deviceFailed 会提示重启应用）。
    reason = apiErrorCopy(error, fallback: '取流失败，请重试');
  } else if (error is PlatformException) {
    final text = [
      error.code,
      error.message ?? '',
      error.details?.toString() ?? '',
    ].join(' | ');
    if (RegExp(r'-1022|App Transport Security').hasMatch(text)) {
      title = '本地视频流被 ATS 拦截';
      reason = 'iOS 拒绝了 http://127.0.0.1 的回环请求（Info.plist 的 ATS 例外没生效）。';
    } else if (RegExp(r'-1001|-1005|-1009|-1011|-1012|-1200|-1202')
        .hasMatch(text)) {
      title = '本地视频流连接中断';
      reason =
          'AVPlayer 读本地回环流时断开了：常见于内核下载被中断（App 切后台）、'
          '或回环服务被系统回收。点「重新下载这一集」重试。';
    } else if (RegExp(
      r'-1102|-11800|-11828|-11829|avfoundationerrordomain|decode|format',
      caseSensitive: false,
    ).hasMatch(text)) {
      title = '视频解码失败';
      reason = context.localPath.isNotEmpty
          ? '离线缓存文件可能损坏（下载不完整或被外部清理）。'
                '点「重新下载这一集」会删掉本地文件后重新联网取流。'
          : '这一集的文件可能损坏（半截缓存）或编码不受支持。'
                '可以点「重新下载这一集」清掉缓存重取。';
    } else if (RegExp(r'403|404|410').hasMatch(text)) {
      title = '本地视频地址失效';
      reason = '回环服务对 /src 返回了 4xx，多半是缓存被清理或内核重启过。重新下载这一集即可。';
    } else if (isLoopbackConnectRefused(error)) {
      title = '本地视频服务未响应';
      reason =
          '播放器连不上 App 内的本地视频服务（127.0.0.1）：App 长时间在后台后，'
          '系统回收了本机回环监听（iOS TN2277）。已尝试自动重启播放服务；'
          '如果仍然失败，请重启 App。';
    } else {
      title = 'AVPlayer 播放失败';
      reason = '播放器内部错误，具体信息见下方。';
    }
    // 兜底：有些插件版本把网络类错误包在 message 的英文描述里。
    if (title == 'AVPlayer 播放失败' && rawLower.contains('network')) {
      title = '本地视频流连接中断';
      reason = '播放器报告网络类错误，详情见下方。';
    }
  } else {
    title = '视频播放失败';
    reason = '未归类的错误，详情见下方。';
  }

  return PlaybackFailure(
    title: title,
    reason: reason,
    detail: buildPlaybackDetail(context: context, error: error, stack: stack),
  );
}

/// 「确认离线且这一集没有离线副本」的专用错误页。
///
/// 文案是产品要求（[EpisodePlaybackPlan.offlineMissTitle] / offlineMissReason），
/// 与普通播放失败区分：不提示"重试"，而是引导去联网或先用「离线缓存」。
PlaybackFailure offlineMissPlaybackFailure(
  Object error,
  StackTrace stack, {
  required PlaybackFailureContext context,
}) => PlaybackFailure(
  title: EpisodePlaybackPlan.offlineMissTitle,
  reason: EpisodePlaybackPlan.offlineMissReason,
  detail: buildPlaybackDetail(context: context, error: error, stack: stack),
);

/// 可复制的技术详情：集 id、地址、原始异常、堆栈前几行。
String buildPlaybackDetail({
  required PlaybackFailureContext context,
  required Object error,
  required StackTrace stack,
}) {
  final frames = stack.toString().split('\n').take(4).join('\n');
  return [
    '《${context.seriesTitle}》第 ${context.episodeNumber} 集 '
        '${context.episodeTitle}（id=${context.episodeId}）',
    if (context.sourceUrl.isNotEmpty) '播放地址: ${context.sourceUrl}',
    if (context.localPath.isNotEmpty) '离线文件: ${context.localPath}',
    if (context.refreshed) '本次为「重新下载这一集」后的结果',
    '错误类型: ${error.runtimeType}',
    '原始错误: $error',
    if (frames.isNotEmpty) '堆栈(前 4 行):\n$frames',
  ].join('\n');
}

/// 这次失败是不是「回环监听已死」——connect refused。
///
/// iOS 长时间挂起后会回收 listening socket（Apple TN2277），内核 FFI 照常
/// 可用，但 127.0.0.1 上已经没人 accept；AVPlayer 把它报成
/// NSURLErrorCannotConnectToHost(-1004, "Could not connect to the server")。
/// vendored video_player_avfoundation 只把 localizedDescription 传上来
/// （没有数字 code），所以以英文文案为主、数字 code 只作兜底。
bool isLoopbackConnectRefused(Object error) {
  if (error is SocketException) {
    final code = error.osError?.errorCode;
    return code == 61 || // Darwin ECONNREFUSED
        code == 111 || // Linux ECONNREFUSED
        error.message.toLowerCase().contains('connection refused');
  }
  if (error is! PlatformException) return false;
  final text = [
    error.code,
    error.message ?? '',
    error.details?.toString() ?? '',
  ].join(' ').toLowerCase();
  return text.contains('could not connect to the server') ||
      text.contains('cannot connect to host') ||
      text.contains('connection refused') ||
      text.contains('-1004');
}

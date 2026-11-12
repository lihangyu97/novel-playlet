import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/data/models/json_utils.dart';
import 'package:novel_playlet/features/video/episode_source_resolver.dart';
import 'package:novel_playlet/features/video/offline_playback.dart';
import 'package:novel_playlet/features/video/playback_failure.dart';

/// 播放失败文案决策的纯 Dart 测试。
///
/// 这些分支原先埋在 `video_player_page` 的 `_describePlaybackError` 里，只能靠
/// 1100 行 UI 测试间接覆盖；抽成纯函数后在这里锁住「什么错误 → 什么标题/建议」，
/// 防止改文案或调整回环判定时悄悄破坏错误页。
void main() {
  const context = PlaybackFailureContext(
    seriesTitle: '测试短剧',
    episodeTitle: '第 3 集',
    episodeId: 'e3',
    episodeNumber: 3,
    sourceUrl: 'http://127.0.0.1:18931/src/e3.mp4',
    localPath: '/tmp/e3.mp4',
    refreshed: true,
  );

  final stack = StackTrace.fromString(
    'frame-a\nframe-b\nframe-c\nframe-d\nframe-e',
  );

  group('isLoopbackConnectRefused', () {
    test('SocketException：Darwin/Linux ECONNREFUSED 错误码与文案都命中', () {
      expect(
        isLoopbackConnectRefused(
          const SocketException(
            'Connection refused',
            osError: OSError('Connection refused', 61),
          ),
        ),
        isTrue,
      );
      expect(
        isLoopbackConnectRefused(
          const SocketException(
            'Connection refused',
            osError: OSError('Connection refused', 111),
          ),
        ),
        isTrue,
      );
      expect(
        isLoopbackConnectRefused(
          const SocketException('Failed host lookup: connection refused'),
        ),
        isTrue,
      );
    });

    test('SocketException：其它错误码不算回环拒绝', () {
      expect(
        isLoopbackConnectRefused(
          const SocketException(
            'Network is unreachable',
            osError: OSError('Network is unreachable', 51),
          ),
        ),
        isFalse,
      );
    });

    test('PlatformException：vendored 插件只有英文文案时也能判定', () {
      expect(
        isLoopbackConnectRefused(
          PlatformException(
            code: 'VideoError',
            message: 'Failed to load video: Could not connect to the server.',
          ),
        ),
        isTrue,
      );
      expect(
        isLoopbackConnectRefused(
          PlatformException(code: 'VideoError', message: 'Code=-1004'),
        ),
        isTrue,
      );
      expect(
        isLoopbackConnectRefused(
          PlatformException(
            code: 'VideoError',
            message: 'cannot connect to host',
          ),
        ),
        isTrue,
      );
    });

    test('非回环错误不误判', () {
      expect(
        isLoopbackConnectRefused(
          PlatformException(code: 'VideoError', message: 'Code=-11800'),
        ),
        isFalse,
      );
      expect(isLoopbackConnectRefused(StateError('boom')), isFalse);
      expect(
        isLoopbackConnectRefused(const SuspectedOfflineException()),
        isFalse,
      );
    });
  });

  group('describePlaybackFailure：标题/原因分类', () {
    test('TimeoutException 与 ApiException.timeout 都归为取流超时', () {
      final fromTimeout = describePlaybackFailure(
        TimeoutException('timeout'),
        stack,
        context: context,
      );
      expect(fromTimeout.title, '取流超时');
      expect(fromTimeout.reason, contains('120 秒'));

      final fromApi = describePlaybackFailure(
        ApiException('请求超时', kind: ApiErrorKind.timeout),
        stack,
        context: context,
      );
      expect(fromApi.title, '取流超时');
    });

    test('其它 ApiException：取流失败 + 具体原因', () {
      final failure = describePlaybackFailure(
        ApiException('上游返回 500', kind: ApiErrorKind.upstream5xx),
        stack,
        context: context,
      );
      expect(failure.title, '取流失败');
      expect(failure.reason, contains('上游返回 500'));
    });

    test('PlatformException：ATS / 连接中断 / 解码 / 4xx / 回环 / 兜底', () {
      expect(
        describePlaybackFailure(
          PlatformException(code: 'VideoError', message: 'Code=-1022'),
          stack,
          context: context,
        ).title,
        '本地视频流被 ATS 拦截',
      );
      expect(
        describePlaybackFailure(
          PlatformException(code: 'VideoError', message: 'Code=-1001'),
          stack,
          context: context,
        ).title,
        '本地视频流连接中断',
      );
      expect(
        describePlaybackFailure(
          PlatformException(code: 'VideoError', message: 'Code=-11800'),
          stack,
          context: context,
        ).title,
        '视频解码失败',
      );
      expect(
        describePlaybackFailure(
          PlatformException(code: 'VideoError', message: 'HTTP 403'),
          stack,
          context: context,
        ).title,
        '本地视频地址失效',
      );
      expect(
        describePlaybackFailure(
          PlatformException(
            code: 'VideoError',
            message: 'Could not connect to the server.',
          ),
          stack,
          context: context,
        ).title,
        '本地视频服务未响应',
      );
      expect(
        describePlaybackFailure(
          PlatformException(code: 'VideoError', message: 'unknown failure'),
          stack,
          context: context,
        ).title,
        'AVPlayer 播放失败',
      );
      expect(
        describePlaybackFailure(
          PlatformException(code: 'VideoError', message: 'a network error'),
          stack,
          context: context,
        ).title,
        '本地视频流连接中断',
      );
    });

    test('解码失败的建议文案按「本地文件 / 在线」分流', () {
      final local = describePlaybackFailure(
        PlatformException(code: 'VideoError', message: 'Code=-11800'),
        stack,
        context: context,
      );
      expect(local.reason, contains('离线缓存文件可能损坏'));

      final online = describePlaybackFailure(
        PlatformException(code: 'VideoError', message: 'Code=-11800'),
        stack,
        context: const PlaybackFailureContext(
          seriesTitle: '测试短剧',
          episodeTitle: '第 3 集',
          episodeId: 'e3',
          episodeNumber: 3,
        ),
      );
      expect(online.reason, contains('半截缓存'));
    });

    test('未归类异常也给出可展示文案', () {
      final failure = describePlaybackFailure(
        StateError('boom'),
        stack,
        context: context,
      );
      expect(failure.title, '视频播放失败');
      expect(failure.reason, contains('详情见下方'));
    });
  });

  group('离线未缓存错误页', () {
    test('使用产品口径的标题与原因（不是普通播放失败）', () {
      final failure = offlineMissPlaybackFailure(
        const SuspectedOfflineException(),
        stack,
        context: context,
      );
      expect(failure.title, EpisodePlaybackPlan.offlineMissTitle);
      expect(failure.reason, EpisodePlaybackPlan.offlineMissReason);
      expect(failure.reason, contains('离线缓存'));
    });
  });

  group('buildPlaybackDetail', () {
    test('包含集信息、本次地址、刷新标记、错误类型与堆栈前 4 行', () {
      final detail = buildPlaybackDetail(
        context: context,
        error: PlatformException(code: 'VideoError', message: 'boom'),
        stack: stack,
      );
      expect(detail, contains('《测试短剧》第 3 集 第 3 集（id=e3）'));
      expect(detail, contains('播放地址: http://127.0.0.1:18931/src/e3.mp4'));
      expect(detail, contains('离线文件: /tmp/e3.mp4'));
      expect(detail, contains('本次为「重新下载这一集」后的结果'));
      expect(detail, contains('错误类型: PlatformException'));
      expect(detail, contains('原始错误:'));
      expect(detail, contains('frame-a'));
      expect(detail, contains('frame-d'));
      expect(detail, isNot(contains('frame-e')), reason: '堆栈只取前 4 行');
    });

    test('没有地址/离线文件/刷新标记时不输出对应行', () {
      final detail = buildPlaybackDetail(
        context: const PlaybackFailureContext(
          seriesTitle: '测试短剧',
          episodeTitle: '第 1 集',
          episodeId: 'e1',
          episodeNumber: 1,
        ),
        error: StateError('boom'),
        stack: StackTrace.empty,
      );
      expect(detail, isNot(contains('播放地址:')));
      expect(detail, isNot(contains('离线文件:')));
      expect(detail, isNot(contains('本次为')));
      expect(detail, isNot(contains('堆栈')));
      expect(detail, contains('《测试短剧》第 1 集 第 1 集（id=e1）'));
    });
  });
}

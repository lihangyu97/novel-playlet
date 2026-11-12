import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/app/providers.dart';
import 'package:novel_playlet/core/backend/backend_transport.dart';
import 'package:novel_playlet/data/api/api_client.dart';
import 'package:novel_playlet/data/models/json_utils.dart';
import 'package:novel_playlet/features/feed/feed_footer.dart';
import 'package:novel_playlet/features/feed/feed_state.dart';
import 'package:novel_playlet/features/recommend/recommend_category.dart';
import 'package:novel_playlet/features/recommend/recommend_controller.dart';
import 'package:novel_playlet/features/recommend/recommend_item.dart';

/// 错误 kind 的策略回归：语义表、中心化文案、B2 超时归一、翻页重试策略。
///
/// 原则：kind 只描述语义，Dart 不实现自动重试循环（Rust 侧已有重试/退避）。

void _noop() {}

class _StatusTransport extends BackendTransport {
  _StatusTransport(this.status) : super(port: 0);

  final int status;

  @override
  Future<BackendResponse> send(
    String method,
    String path, {
    String? query,
    Uint8List? body,
    Duration timeout = BackendTransport.defaultTimeout,
  }) async {
    return BackendResponse(status, Uint8List(0), 'application/json');
  }
}

class _ThrowingTransport extends BackendTransport {
  _ThrowingTransport(this.error) : super(port: 0);

  final Object error;

  @override
  Future<BackendResponse> send(
    String method,
    String path, {
    String? query,
    Uint8List? body,
    Duration timeout = BackendTransport.defaultTimeout,
  }) async {
    throw error;
  }
}

/// 首页第一页成功；翻页返回 400 + kind=bad_input（确定性失败）。
class _LoadMoreFailureFake extends BackendTransport {
  _LoadMoreFailureFake() : super(port: 0);

  final calls = <String>[];

  @override
  Future<BackendResponse> send(
    String method,
    String path, {
    String? query,
    Uint8List? body,
    Duration timeout = BackendTransport.defaultTimeout,
  }) async {
    final offset =
        int.tryParse(Uri.splitQueryString(query ?? '')['offset'] ?? '0') ?? 0;
    calls.add('$path@$offset');
    if (offset == 0) {
      return _json({
        'code': 0,
        'data': {
          'tab_index': 0,
          'tab_item': [
            {
              'tab_type': 2,
              'title': '推荐',
              'next_offset': 10,
              'session_id': 'sess',
              'cell_data': [
                {
                  'book_data': [
                    {'book_id': 'b1', 'book_name': '书1'},
                  ],
                },
              ],
            },
          ],
        },
      });
    }
    return _json({
      'success': false,
      'error': 'offset 不合法',
      'kind': 'bad_input',
    }, status: 400);
  }

  BackendResponse _json(Map<String, dynamic> payload, {int status = 200}) =>
      BackendResponse(
        status,
        Uint8List.fromList(utf8.encode(jsonEncode(payload))),
        'application/json',
      );
}

/// 图文/纯文本两条正文接口分别可编程的 transport（`chapter` 回退策略用例）。
class _ChapterTransport extends BackendTransport {
  _ChapterTransport(this.handler) : super(port: 0);

  final FutureOr<BackendResponse> Function(String path) handler;
  final List<String> calls = <String>[];

  @override
  Future<BackendResponse> send(
    String method,
    String path, {
    String? query,
    Uint8List? body,
    Duration timeout = BackendTransport.defaultTimeout,
  }) async {
    calls.add(path);
    return handler(path);
  }
}

BackendResponse _jsonResponse(
  Map<String, dynamic> payload, {
  int status = 200,
}) => BackendResponse(
  status,
  Uint8List.fromList(utf8.encode(jsonEncode(payload))),
  'application/json',
);

/// 一条能解析出段落的正文响应（形状同内核透传的上游响应）。
Map<String, dynamic> _chapterPayload({
  String content = '<p idx="1">正文第一段</p>',
}) => {
  'code': 0,
  'data': {'content_decrypted': true, 'title': '第1章', 'content': content},
};

Map<String, dynamic> _businessError(String message, String kind) => {
  'success': false,
  'error': message,
  'kind': kind,
};

void main() {
  group('kind 语义表', () {
    test('只有网络/上游瞬时失败算 isTransient', () {
      expect(ApiErrorKind.rateLimited.isTransient, isTrue);
      expect(ApiErrorKind.upstream5xx.isTransient, isTrue);
      expect(ApiErrorKind.timeout.isTransient, isTrue);
      for (final kind in [
        ApiErrorKind.badInput,
        ApiErrorKind.deviceFailed,
        ApiErrorKind.tooLarge,
        ApiErrorKind.unknown,
      ]) {
        expect(kind.isTransient, isFalse, reason: '${kind.wireName} 不该算可重试');
      }
    });

    test('deviceFailed 是"需要重启"类，与 isTransient 互斥', () {
      expect(ApiErrorKind.deviceFailed.needsRestart, isTrue);
      expect(ApiErrorKind.deviceFailed.isTransient, isFalse);
      for (final kind in [
        ApiErrorKind.badInput,
        ApiErrorKind.rateLimited,
        ApiErrorKind.upstream5xx,
        ApiErrorKind.timeout,
        ApiErrorKind.tooLarge,
        ApiErrorKind.unknown,
      ]) {
        expect(kind.needsRestart, isFalse);
      }
    });

    test('ApiException.isRetryable 与 isRetryableError 一致', () {
      expect(ApiException('x', kind: ApiErrorKind.timeout).isRetryable, isTrue);
      expect(
        ApiException('x', kind: ApiErrorKind.rateLimited).isRetryable,
        isTrue,
      );
      expect(
        ApiException('x', kind: ApiErrorKind.badInput).isRetryable,
        isFalse,
      );
      expect(
        isRetryableError(ApiException('x', kind: ApiErrorKind.tooLarge)),
        isFalse,
      );
      expect(
        isRetryableError(ApiException('x', kind: ApiErrorKind.deviceFailed)),
        isFalse,
        reason: '设备注册失效需要重启，不是重试能解决的',
      );
      // unknown 无法判断，保守给重试（保持旧的"失败可重试"行为）。
      expect(
        isRetryableError(ApiException('x', kind: ApiErrorKind.unknown)),
        isTrue,
      );
      // 非 ApiException 的意外（解析/IO）默认值得重试一次。
      expect(isRetryableError(StateError('boom')), isTrue);
    });
  });

  group('apiErrorCopy 文案策略', () {
    test('技术兜底 message 换成 kind 短句', () {
      const cases = {
        ApiErrorKind.rateLimited: '请求太频繁，稍后重试',
        ApiErrorKind.timeout: '网络超时，请重试',
        ApiErrorKind.upstream5xx: '上游服务异常，稍后重试',
        ApiErrorKind.deviceFailed: '设备注册失效，请重启应用',
        ApiErrorKind.tooLarge: '内容过大，暂时无法加载',
      };
      cases.forEach((kind, copy) {
        expect(
          apiErrorCopy(ApiException('HTTP 500', kind: kind), fallback: '兜底'),
          copy,
          reason: '${kind.wireName} 的技术 message 应换成短句',
        );
      });
      // 内核非 200 路径自己拼的兜底文案同样算"技术兜底"。
      expect(
        apiErrorCopy(
          ApiException('请求失败（HTTP 504）', kind: ApiErrorKind.timeout),
          fallback: '兜底',
        ),
        '网络超时，请重试',
      );
    });

    test('后端具体 message 优先，不被 kind 短句盖掉', () {
      expect(
        apiErrorCopy(
          ApiException('该书籍已被作者下架', kind: ApiErrorKind.badInput),
          fallback: '兜底',
        ),
        '该书籍已被作者下架',
      );
      expect(
        apiErrorCopy(
          ApiException('设备令牌已吊销，需要重新登录', kind: ApiErrorKind.deviceFailed),
          fallback: '兜底',
        ),
        '设备令牌已吊销，需要重新登录',
      );
    });

    test('badInput/unknown 保留 message，缺失才用 fallback', () {
      expect(
        apiErrorCopy(
          ApiException('书名不能为空', kind: ApiErrorKind.badInput),
          fallback: '兜底',
        ),
        '书名不能为空',
      );
      expect(
        apiErrorCopy(
          ApiException('', kind: ApiErrorKind.badInput),
          fallback: '兜底',
        ),
        '兜底',
      );
      expect(
        apiErrorCopy(
          ApiException('boom', kind: ApiErrorKind.unknown),
          fallback: '兜底',
        ),
        'boom',
      );
      // 非 ApiException 一律用兜底文案，不把异常 toString 抛给用户。
      expect(apiErrorCopy(StateError('boom'), fallback: '网络开小差了'), '网络开小差了');
    });
  });

  group('B2 超时归一', () {
    test('内核 504（raw status）→ ApiException(kind=timeout)', () async {
      final api = ApiClient(_StatusTransport(504));
      await expectLater(
        api.recommend(),
        throwsA(
          isA<ApiException>()
              .having((error) => error.kind, 'kind', ApiErrorKind.timeout)
              .having((error) => error.isRetryable, 'isRetryable', isTrue)
              .having((error) => error.message, 'message', '网络超时，请重试'),
        ),
      );
    });

    test(
      'transport 抛 BackendTimeoutException → ApiException(kind=timeout)',
      () async {
        final api = ApiClient(
          _ThrowingTransport(
            const BackendTimeoutException(Duration(milliseconds: 20)),
          ),
        );
        await expectLater(
          api.recommend(),
          throwsA(
            isA<ApiException>().having(
              (error) => error.kind,
              'kind',
              ApiErrorKind.timeout,
            ),
          ),
        );
      },
    );

    test('499 取消仍是 TimeoutException，不变成用户可见的 ApiException', () async {
      final api = ApiClient(
        _ThrowingTransport(TimeoutException('backend cancelled')),
      );
      await expectLater(
        api.recommend(),
        throwsA(
          isA<TimeoutException>().having(
            (error) => error.message,
            'message',
            'backend cancelled',
          ),
        ),
      );
    });
  });

  group('翻页失败策略', () {
    test('FeedState 记录 retryable 并随 with* 保留', () {
      final clear = FeedState<RecommendItem>(items: const <RecommendItem>[]);
      expect(clear.loadMoreRetryable, isTrue, reason: '没有错误时默认值不影响 UI');

      final failed = clear.withLoadMoreError('内容过大', retryable: false);
      expect(failed.loadMoreRetryable, isFalse);
      expect(
        failed.withLoadingMore(true).loadMoreRetryable,
        isFalse,
        reason: 'loading 状态切换不能把 retryable 清掉',
      );
      expect(failed.withLoadMoreError(null).loadMoreRetryable, isTrue);
    });

    testWidgets('非可重试失败：底部不给"重试"按钮', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: FeedFooter(
              loadingMore: false,
              error: '内容过大，暂时无法加载',
              hasMore: true,
              onRetry: _noop,
              retryable: false,
            ),
          ),
        ),
      );
      expect(find.text('内容过大，暂时无法加载'), findsOneWidget);
      expect(find.text('重试'), findsNothing, reason: '确定性失败重试同样会失败');
    });

    testWidgets('可重试失败：底部保留"重试"按钮', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: FeedFooter(
              loadingMore: false,
              error: '网络超时，请重试',
              hasMore: true,
              onRetry: _noop,
              retryable: true,
            ),
          ),
        ),
      );
      expect(find.text('重试'), findsOneWidget);
    });

    test('controller：badInput 翻页失败不再重复发请求', () async {
      final fake = _LoadMoreFailureFake();
      final container = ProviderContainer(
        overrides: [apiClientProvider.overrideWithValue(ApiClient(fake))],
      );
      addTearDown(container.dispose);
      final provider = recommendFeedProvider(RecommendCategory.novel);
      await container.read(provider.future);
      final notifier = container.read(provider.notifier);
      expect(container.read(provider).value!.hasMore, isTrue);

      await notifier.loadMore();
      final failed = container.read(provider).value!;
      expect(
        failed.loadMoreError,
        'offset 不合法',
        reason: 'badInput 的具体 message 保留',
      );
      expect(failed.loadMoreRetryable, isFalse);
      expect(failed.loadingMore, isFalse);

      final callsBeforeRetry = fake.calls.length;
      await notifier.retryLoadMore();
      expect(
        fake.calls.length,
        callsBeforeRetry,
        reason: '非瞬时失败重试同一个请求不会变好，不应再发请求',
      );
    });
  });

  group('chapter 回退策略（P1-7）', () {
    String novelPath(String id) => '/api/v1/chapters/$id/novel';
    String plainPath(String id) => '/api/v1/chapters/$id';

    test('图文接口超时：只发一次请求，抛 timeout（不回退）', () async {
      final transport = _ChapterTransport(
        (_) => throw const BackendTimeoutException(Duration(seconds: 1)),
      );
      await expectLater(
        ApiClient(transport).chapter('c1'),
        throwsA(
          isA<ApiException>()
              .having((error) => error.kind, 'kind', ApiErrorKind.timeout)
              .having((error) => error.message, 'message', '网络超时，请重试'),
        ),
      );
      expect(transport.calls, [
        novelPath('c1'),
      ], reason: '超时再打第二个接口只会把阅读页单章等待翻倍（P1-7）');
    });

    test('499 取消：只发一次请求，仍是 TimeoutException', () async {
      final transport = _ChapterTransport(
        (_) => throw TimeoutException('backend cancelled'),
      );
      await expectLater(
        ApiClient(transport).chapter('c1'),
        throwsA(isA<TimeoutException>()),
      );
      expect(transport.calls, [novelPath('c1')], reason: '取消不能触发回退重发');
    });

    test('限流 / 上游 5xx / 设备失效：都不回退', () async {
      const cases = [
        (ApiErrorKind.rateLimited, 429),
        (ApiErrorKind.upstream5xx, 500),
        (ApiErrorKind.deviceFailed, 503),
      ];
      for (final (kind, status) in cases) {
        final transport = _ChapterTransport(
          (_) => _jsonResponse(
            _businessError('upstream boom', kind.wireName),
            status: status,
          ),
        );
        await expectLater(
          ApiClient(transport).chapter('c1'),
          throwsA(
            isA<ApiException>().having((error) => error.kind, 'kind', kind),
          ),
          reason: '${kind.wireName} 是瞬时/需重启失败，换接口不会变好',
        );
        expect(transport.calls, [novelPath('c1')]);
      }
    });

    test('图文接口业务失败（badInput）：回退纯文本接口并成功', () async {
      final transport = _ChapterTransport(
        (path) => path.endsWith('/novel')
            ? _jsonResponse(_businessError('本书没有图文版', 'bad_input'))
            : _jsonResponse(_chapterPayload()),
      );
      final content = await ApiClient(transport).chapter('c1');
      expect(content.paragraphs, isNotEmpty);
      expect(transport.calls, [novelPath('c1'), plainPath('c1')]);
    });

    test('图文接口正文为空（解析失败）：回退纯文本接口', () async {
      final transport = _ChapterTransport(
        (path) => path.endsWith('/novel')
            ? _jsonResponse(_chapterPayload(content: ''))
            : _jsonResponse(_chapterPayload()),
      );
      final content = await ApiClient(transport).chapter('c1');
      expect(content.paragraphs, isNotEmpty);
      expect(transport.calls.length, 2, reason: '正文为空属于非瞬时失败，值得回退');
    });

    test('两条接口都失败：最终 message 与 kind 都取第二次（语义一致）', () async {
      final transport = _ChapterTransport(
        (path) => path.endsWith('/novel')
            ? _jsonResponse(_businessError('本书没有图文版', 'bad_input'))
            : _jsonResponse(_businessError('纯文本也取不到', 'bad_input')),
      );
      await expectLater(
        ApiClient(transport).chapter('c1'),
        throwsA(
          isA<ApiException>()
              .having((error) => error.message, 'message', '纯文本也取不到')
              .having((error) => error.kind, 'kind', ApiErrorKind.badInput),
        ),
      );
      expect(transport.calls.length, 2);
    });

    test('回退请求被取消：保持 TimeoutException，不包成 ApiException', () async {
      final transport = _ChapterTransport(
        (path) => path.endsWith('/novel')
            ? _jsonResponse(_businessError('本书没有图文版', 'bad_input'))
            : throw TimeoutException('backend cancelled'),
      );
      await expectLater(
        ApiClient(transport).chapter('c1'),
        throwsA(isA<TimeoutException>()),
      );
      expect(transport.calls.length, 2);
    });
  });
}

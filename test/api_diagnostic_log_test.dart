import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/core/backend/backend_transport.dart';
import 'package:novel_playlet/core/diagnostics/diagnostic_log.dart';
import 'package:novel_playlet/data/api/api_client.dart';
import 'package:novel_playlet/data/models/json_utils.dart';

/// 固定回包的传输层：只用来验证 ApiClient 把失败写进运行日志。
class _StubTransport extends BackendTransport {
  _StubTransport(this.status, this.payload) : super(port: 0);

  final int status;
  final String payload;

  @override
  Future<BackendResponse> send(
    String method,
    String path, {
    String? query,
    Uint8List? body,
    Duration timeout = BackendTransport.defaultTimeout,
  }) async {
    return BackendResponse(
      status,
      Uint8List.fromList(utf8.encode(payload)),
      'application/json',
    );
  }
}

class _ThrowingTransport extends BackendTransport {
  _ThrowingTransport() : super(port: 0);

  @override
  Future<BackendResponse> send(
    String method,
    String path, {
    String? query,
    Uint8List? body,
    Duration timeout = BackendTransport.defaultTimeout,
  }) async {
    throw StateError(
      '内核没起来 https://log.example.com/boot?token=secret&openudid=abc',
    );
  }
}

class _TimeoutTransport extends BackendTransport {
  _TimeoutTransport() : super(port: 0);

  @override
  Future<BackendResponse> send(
    String method,
    String path, {
    String? query,
    Uint8List? body,
    Duration timeout = BackendTransport.defaultTimeout,
  }) async {
    throw BackendTimeoutException(timeout);
  }
}

void main() {
  late Directory dir;
  late DiagnosticLogStore store;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('api-log-test');
    DiagnosticLogStore.overridePath = '${dir.path}/app-log.json';
    store = DiagnosticLogStore();
  });

  tearDown(() async {
    DiagnosticLogStore.overridePath = null;
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('HTTP 失败记一条 error，带路径 / 状态码 / kind', () async {
    final api = ApiClient(
      _StubTransport(
        500,
        jsonEncode({'success': false, 'error': '上游炸了', 'kind': 'upstream_5xx'}),
      ),
      logStore: store,
    );

    await expectLater(api.bookDetail('b1'), throwsA(isA<ApiException>()));
    await store.flush();

    final entries = await store.read();
    expect(entries, hasLength(1));
    final entry = entries.single;
    expect(entry.level, LogLevel.error);
    expect(entry.source, DiagnosticSource.api);
    expect(entry.message, contains('/api/v1/books/b1/detail'));
    expect(entry.message, contains('上游炸了'));
    expect(entry.detail, contains('HTTP 500'));
    expect(entry.detail, contains('kind=upstream_5xx'));
  });

  test('内核超时归一成 error 日志', () async {
    final api = ApiClient(_TimeoutTransport(), logStore: store);

    await expectLater(
      api.bookDetail('b1'),
      throwsA(
        isA<ApiException>().having(
          (error) => error.kind,
          'kind',
          ApiErrorKind.timeout,
        ),
      ),
    );
    await store.flush();

    final entries = await store.read();
    expect(entries.single.message, contains('网络超时'));
    expect(entries.single.detail, contains('kind=timeout'));
  });

  test('200 但 body 不是 JSON 记一条 unexpected', () async {
    final api = ApiClient(_StubTransport(200, 'not json'), logStore: store);

    await expectLater(api.bookDetail('b1'), throwsA(isA<FormatException>()));
    await store.flush();

    final entries = await store.read();
    expect(entries.single.level, LogLevel.unexpected);
    expect(entries.single.message, contains('响应不是合法 JSON'));
  });

  test('上游错误文案里的 URL 查询串不写进日志', () async {
    final api = ApiClient(
      _StubTransport(
        500,
        jsonEncode({
          'success': false,
          'error':
              'device_register: Network("error sending request for url '
              '(https://log.example.com/service/2/device_register'
              '?openudid=abc&_rticket=1)")',
          'kind': 'device_failed',
        }),
      ),
      logStore: store,
    );

    await expectLater(api.bookDetail('b1'), throwsA(isA<ApiException>()));
    await store.flush();

    final entry = (await store.read()).single;
    expect(
      entry.message,
      contains('https://log.example.com/service/2/device_register'),
      reason: '保留 host + path 便于定位',
    );
    expect(entry.message, isNot(contains('openudid')));
    expect(entry.message, isNot(contains('_rticket')));
  });

  test('传输层异常的 URL 查询串也不写进 detail', () async {
    final api = ApiClient(_ThrowingTransport(), logStore: store);

    await expectLater(api.bookDetail('b1'), throwsA(isA<StateError>()));
    await store.flush();

    final entry = (await store.read()).single;
    expect(entry.detail, contains('https://log.example.com/boot'));
    expect(entry.detail, isNot(contains('token')));
    expect(entry.detail, isNot(contains('openudid')));
  });

  test('200 + success:false 的失败信封记一条 error', () async {
    final api = ApiClient(
      _StubTransport(
        200,
        jsonEncode({'success': false, 'error': '没有权限', 'kind': 'bad_input'}),
      ),
      logStore: store,
    );

    try {
      await api.bookDetail('b1');
    } catch (_) {
      // 信封失败后解析层怎么抛不影响日志；这里只验证记录。
    }
    await store.flush();

    final entry = (await store.read()).single;
    expect(entry.level, LogLevel.error);
    expect(entry.message, contains('没有权限'));
    expect(entry.detail, contains('HTTP 200'));
  });

  test('200 但顶层不是对象记一条 unexpected', () async {
    final api = ApiClient(_StubTransport(200, '[]'), logStore: store);

    await expectLater(api.bookDetail('b1'), throwsA(isA<ApiException>()));
    await store.flush();

    final entry = (await store.read()).single;
    expect(entry.level, LogLevel.unexpected);
    expect(entry.message, contains('响应格式异常'));
  });

  test('不传 logStore 时不落盘', () async {
    final api = ApiClient(_TimeoutTransport());
    await expectLater(api.bookDetail('b1'), throwsA(isA<ApiException>()));
    expect(File(DiagnosticLogStore.overridePath!).existsSync(), isFalse);
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/core/backend/backend_transport.dart';

/// 回环探针的单测：用真实 [HttpServer] 验证「socket 还活着」的判定口径。
///
/// 这里必须起真实监听：探针的意义就是绕过 FFI 去打真实 socket。
class _ProbeTransport extends BackendTransport {
  _ProbeTransport(this._baseUrl);

  final String _baseUrl;

  @override
  bool get isRunning => true;

  @override
  String get baseUrl => _baseUrl;
}

Future<HttpServer> _serveJson(
  Object body, {
  int statusCode = HttpStatus.ok,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    request.response
      ..statusCode = statusCode
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    await request.response.close();
  });
  return server;
}

void main() {
  test('waitForLoopbackHealthy: /health 返回 200 + status ok -> true', () async {
    final server = await _serveJson({'status': 'ok', 'devices': 0});
    addTearDown(() => server.close(force: true));
    final transport = _ProbeTransport('http://127.0.0.1:${server.port}');

    expect(
      await transport.waitForLoopbackHealthy(
        timeout: const Duration(seconds: 2),
      ),
      isTrue,
    );
  });

  test('waitForLoopbackHealthy: 端口无人监听（模拟被系统回收）-> false', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;
    await server.close(force: true);
    final transport = _ProbeTransport('http://127.0.0.1:$port');

    expect(
      await transport.waitForLoopbackHealthy(
        timeout: const Duration(milliseconds: 600),
      ),
      isFalse,
    );
  });

  test('waitForLoopbackHealthy: 200 但 body 不是 status ok -> false', () async {
    final server = await _serveJson({'status': 'down'});
    addTearDown(() => server.close(force: true));
    final transport = _ProbeTransport('http://127.0.0.1:${server.port}');

    expect(
      await transport.waitForLoopbackHealthy(
        timeout: const Duration(milliseconds: 600),
      ),
      isFalse,
    );
  });

  test('waitForLoopbackHealthy: 非 200 -> false', () async {
    final server = await _serveJson({
      'status': 'ok',
    }, statusCode: HttpStatus.serviceUnavailable);
    addTearDown(() => server.close(force: true));
    final transport = _ProbeTransport('http://127.0.0.1:${server.port}');

    expect(
      await transport.waitForLoopbackHealthy(
        timeout: const Duration(milliseconds: 600),
      ),
      isFalse,
    );
  });

  test('waitForLoopbackHealthy: 内核未运行或 baseUrl 为空 -> false', () async {
    expect(
      await BackendTransport().waitForLoopbackHealthy(
        timeout: const Duration(milliseconds: 100),
      ),
      isFalse,
    );
    expect(
      await _ProbeTransport('')
          .waitForLoopbackHealthy(timeout: const Duration(milliseconds: 100)),
      isFalse,
    );
  });
}

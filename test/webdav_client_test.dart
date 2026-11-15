import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/features/sync/webdav_client.dart';
import 'package:novel_playlet/features/sync/webdav_config.dart';

void main() {
  late HttpServer server;
  late WebDavConfig config;
  final files = <String, String>{};
  final dirs = <String>{};
  const password = 'test-app-password';

  setUp(() async {
    files.clear();
    dirs.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final expected =
          'Basic ${base64Encode(utf8.encode('user@example.com:$password'))}';
      if (request.headers.value(HttpHeaders.authorizationHeader) != expected) {
        request.response.statusCode = 401;
        await request.response.close();
        return;
      }
      final path = request.uri.path;
      switch (request.method) {
        case 'MKCOL':
          if (dirs.add(path)) {
            request.response.statusCode = 201;
          } else {
            request.response.statusCode = 405;
          }
        case 'PUT':
          files[path] = await utf8.decoder.bind(request).join();
          request.response.statusCode = 201;
        case 'GET':
          final content = files[path];
          if (content == null) {
            request.response.statusCode = 404;
          } else {
            request.response.write(content);
          }
        case 'DELETE':
          request.response.statusCode = files.remove(path) != null ? 204 : 404;
        case 'PROPFIND':
          request.response.statusCode = 207;
        default:
          request.response.statusCode = 405;
      }
      await request.response.close();
    });
    config = WebDavConfig(
      baseUrl: 'http://127.0.0.1:${server.port}/dav/',
      username: 'user@example.com',
      password: password,
    );
  });

  tearDown(() async {
    await server.close(force: true);
  });

  test('测试连接会创建目录并完成读写探针', () async {
    final client = HttpWebDavClient(timeout: const Duration(seconds: 5));
    final result = await client.testConnection(config);
    expect(result.ok, isTrue, reason: result.message);
    expect(dirs, contains('/dav/novel-playlet/'));
    expect(files.keys.where((path) => path.contains('.probe-')), isEmpty);
  });

  test('密码错误返回可读错误而不是抛异常', () async {
    final client = HttpWebDavClient(timeout: const Duration(seconds: 5));
    final result = await client.testConnection(
      WebDavConfig(
        baseUrl: config.baseUrl,
        username: config.username,
        password: 'wrong',
      ),
    );
    expect(result.ok, isFalse);
    expect(result.message, contains('账号或应用密码错误'));
  });

  test('读写文本和 404 语义', () async {
    final client = HttpWebDavClient(timeout: const Duration(seconds: 5));
    final uri = config.resolve('novel-playlet/release/sync.json');
    expect(await client.readText(config, uri), isNull);
    await client.writeText(config, uri, '{"ok":true}');
    expect(await client.readText(config, uri), '{"ok":true}');
  });

  test('只允许 HTTPS，localhost 例外用于测试', () {
    expect(
      const WebDavConfig(
        baseUrl: 'http://example.com/dav/',
        username: 'u',
        password: 'p',
      ).validate(),
      contains('HTTPS'),
    );
    expect(
      WebDavConfig(
        baseUrl: 'http://127.0.0.1:8080/dav/',
        username: 'u',
        password: 'p',
      ).validate(),
      isNull,
    );
  });
}

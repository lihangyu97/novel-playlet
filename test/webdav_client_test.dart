import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/features/sync/webdav_client.dart';
import 'package:novel_playlet/features/sync/webdav_config.dart';

String _etagOf(String text) => '"${text.hashCode}"';

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
          final ifMatch = request.headers.value('if-match');
          if (ifMatch != null && ifMatch != _etagOf(files[path] ?? '')) {
            request.response.statusCode = 412;
            break;
          }
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
          final content = files[path] ?? '';
          request.response.statusCode = 207;
          request.response.headers.contentType = ContentType(
            'application',
            'xml',
            charset: 'utf-8',
          );
          request.response.write(
            '<?xml version="1.0" encoding="utf-8"?>'
            '<d:multistatus xmlns:d="DAV:"><d:response>'
            '<d:href>${request.uri.path}</d:href><d:propstat><d:prop>'
            '<d:getetag>${_etagOf(content)}</d:getetag>'
            '<d:getcontentlength>${utf8.encode(content).length}</d:getcontentlength>'
            '</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>'
            '</d:response></d:multistatus>',
          );
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
    expect((await client.readFile(config, uri)).text, isNull);
    await client.writeText(config, uri, '{"ok":true}');
    expect((await client.readFile(config, uri)).text, '{"ok":true}');
  });

  test('stat 解析 ETag；If-Match 不匹配返回 412，匹配才写入', () async {
    final client = HttpWebDavClient();
    final uri = config.resolve('novel-playlet/release/sync.json');
    await client.writeText(config, uri, '{"a":1}');

    final meta = await client.stat(config, uri);
    expect(meta, isNotNull);
    expect(meta!.etag, _etagOf('{"a":1}'));
    expect(meta.length, utf8.encode('{"a":1}').length);

    await expectLater(
      client.writeText(config, uri, '{}', ifMatch: '"stale"'),
      throwsA(isA<WebDavPreconditionFailed>()),
    );
    await client.writeText(config, uri, '{"a":2}', ifMatch: meta.etag);
    expect(files['/dav/novel-playlet/release/sync.json'], '{"a":2}');
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

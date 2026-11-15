import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'webdav_config.dart';

/// WebDAV 请求失败。不要把账号密码拼进 message。
class WebDavException implements Exception {
  WebDavException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

class WebDavTestResult {
  const WebDavTestResult.success() : ok = true, message = '连接成功';

  const WebDavTestResult.failure(this.message) : ok = false;

  final bool ok;
  final String message;
}

abstract interface class WebDavClient {
  /// 逐级创建目录；已存在视为成功。
  Future<void> ensureDirectory(WebDavConfig config, String relativePath);

  Future<String?> readText(WebDavConfig config, Uri uri);

  Future<void> writeText(WebDavConfig config, Uri uri, String text);

  /// 写一个探针再读回，确认账号可写、可读、目录存在。
  Future<WebDavTestResult> testConnection(WebDavConfig config);
}

class HttpWebDavClient implements WebDavClient {
  const HttpWebDavClient({this.timeout = const Duration(seconds: 20)});

  final Duration timeout;

  @override
  Future<void> ensureDirectory(WebDavConfig config, String relativePath) async {
    final segments = relativePath
        .split('/')
        .where((segment) => segment.isNotEmpty);
    var current = config.rootUri;
    for (final segment in segments) {
      current = current.resolve('$segment/');
      final response = await _send(config, 'MKCOL', current);
      // 201 新建；405 已存在；部分服务器对已有集合返回 301/302。
      if (response.statusCode != 201 &&
          response.statusCode != 405 &&
          response.statusCode != 301 &&
          response.statusCode != 302) {
        throw _statusError(response.statusCode, '创建同步目录失败');
      }
    }
  }

  @override
  Future<String?> readText(WebDavConfig config, Uri uri) async {
    final response = await _send(config, 'GET', uri);
    if (response.statusCode == 404) return null;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _statusError(response.statusCode, '下载同步文件失败');
    }
    return response.body;
  }

  @override
  Future<void> writeText(WebDavConfig config, Uri uri, String text) async {
    final response = await _send(config, 'PUT', uri, body: text);
    if (response.statusCode != 200 &&
        response.statusCode != 201 &&
        response.statusCode != 204) {
      throw _statusError(response.statusCode, '上传同步文件失败');
    }
  }

  @override
  Future<WebDavTestResult> testConnection(WebDavConfig config) async {
    final invalid = config.validate();
    if (invalid != null) return WebDavTestResult.failure(invalid);
    final probe = config.resolve(
      'novel-playlet/.probe-${DateTime.now().microsecondsSinceEpoch}.txt',
    );
    try {
      await ensureDirectory(config, 'novel-playlet');
      await writeText(config, probe, 'novel-playlet-webdav-probe');
      final echoed = await readText(config, probe);
      if (echoed != 'novel-playlet-webdav-probe') {
        return const WebDavTestResult.failure('写入成功但读回内容不一致');
      }
      return const WebDavTestResult.success();
    } on WebDavException catch (error) {
      return WebDavTestResult.failure(error.message);
    } catch (error) {
      return WebDavTestResult.failure('连接失败：$error');
    } finally {
      try {
        final delete = await _send(config, 'DELETE', probe);
        // 清理失败不影响“可读可写”的结论，但会留下一个探针文件。
        if (delete.statusCode == 401 || delete.statusCode == 403) {
          // 账号没有删除权限时，PUT/GET 已经通过，仍然算测试成功。
        }
      } catch (_) {
        // 忽略清理异常。
      }
    }
  }

  Future<_WebDavResponse> _send(
    WebDavConfig config,
    String method,
    Uri uri, {
    String? body,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = timeout
      ..idleTimeout = timeout;
    try {
      final request = await client.openUrl(method, uri).timeout(timeout);
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Basic ${base64Encode(utf8.encode('${config.username}:${config.password}'))}',
      );
      request.headers.set(HttpHeaders.userAgentHeader, 'novel-playlet/1.0');
      if (method == 'PROPFIND') {
        request.headers.set('Depth', '0');
      }
      if (body != null) {
        request.headers.contentType = ContentType(
          'application',
          'json',
          charset: 'utf-8',
        );
        request.add(utf8.encode(body));
      }
      final response = await request.close().timeout(timeout);
      final responseBody = await response
          .transform(utf8.decoder)
          .join()
          .timeout(timeout);
      return _WebDavResponse(response.statusCode, responseBody);
    } on WebDavException {
      rethrow;
    } on SocketException catch (error) {
      throw WebDavException('网络不可用：${error.message}');
    } on HandshakeException {
      throw WebDavException('HTTPS 证书校验失败');
    } on TimeoutException {
      throw WebDavException('连接超时，请检查地址和网络');
    } catch (error) {
      throw WebDavException('WebDAV 请求失败：$error');
    } finally {
      client.close(force: true);
    }
  }

  WebDavException _statusError(int statusCode, String action) {
    final reason = switch (statusCode) {
      401 => '账号或应用密码错误',
      403 => '没有权限访问该目录',
      404 => '目录不存在',
      409 => '上级目录不存在',
      507 => '网盘空间或流量不足',
      _ => 'HTTP $statusCode',
    };
    return WebDavException('$action：$reason', statusCode: statusCode);
  }
}

class _WebDavResponse {
  const _WebDavResponse(this.statusCode, this.body);

  final int statusCode;
  final String body;
}

final webDavClientProvider = Provider<WebDavClient>(
  (ref) => const HttpWebDavClient(),
);

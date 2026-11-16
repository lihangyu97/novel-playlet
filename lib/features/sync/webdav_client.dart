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

/// 412 / 409：云端文件在读取之后被另一台设备改过，需要重读重合并。
class WebDavPreconditionFailed extends WebDavException {
  WebDavPreconditionFailed(super.message, {super.statusCode});
}

/// 云端文件元信息（条件请求用）；字段取不到时为 null。
class WebDavFileMeta {
  const WebDavFileMeta({this.etag, this.length});

  final String? etag;
  final int? length;
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

  /// 读文件元信息（PROPFIND Depth:0）。
  ///
  /// 服务器不支持 PROPFIND、或返回里没有 ETag 时返回 null：调用方要走
  /// 无条件 GET 的旧路径，不能因此让同步失败。
  Future<WebDavFileMeta?> stat(WebDavConfig config, Uri uri);

  /// 写文件。[ifMatch] 非空时带 `If-Match`，命中 412/409 抛
  /// [WebDavPreconditionFailed]，由同步层重读重合并。
  Future<void> writeText(
    WebDavConfig config,
    Uri uri,
    String text, {
    String? ifMatch,
  });

  /// 写一个探针再读回，确认账号可写、可读、目录存在。
  Future<WebDavTestResult> testConnection(WebDavConfig config);
}

class HttpWebDavClient implements WebDavClient {
  HttpWebDavClient({this.timeout = const Duration(seconds: 20)});

  final Duration timeout;

  /// 已经建好的目录。同步一次要 MKCOL 两层，失败重试 / 配置保存后再次同步
  /// 都会重复这两次往返；建成功过就按 `baseUrl + 账号 + 路径` 记住。
  final Set<String> _readyDirs = {};

  @override
  Future<void> ensureDirectory(WebDavConfig config, String relativePath) async {
    final cacheKey = '${config.baseUrl}\n${config.username}\n$relativePath';
    if (_readyDirs.contains(cacheKey)) return;

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
    _readyDirs.add(cacheKey);
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
  Future<WebDavFileMeta?> stat(WebDavConfig config, Uri uri) async {
    final response = await _send(
      config,
      'PROPFIND',
      uri,
      body:
          '<?xml version="1.0" encoding="utf-8"?>'
          '<d:propfind xmlns:d="DAV:"><d:prop>'
          '<d:getetag/><d:getcontentlength/>'
          '</d:prop></d:propfind>',
      contentType: 'application/xml; charset=utf-8',
    );
    // 404 = 还没有文件；405/501 = 服务器不支持 PROPFIND；都回退到 GET。
    if (response.statusCode != 207 && response.statusCode != 200) return null;
    final etag = _xmlTag(response.body, 'getetag');
    final length = int.tryParse(
      _xmlTag(response.body, 'getcontentlength') ?? '',
    );
    if (etag == null && length == null) return null;
    return WebDavFileMeta(etag: etag, length: length);
  }

  @override
  Future<void> writeText(
    WebDavConfig config,
    Uri uri,
    String text, {
    String? ifMatch,
  }) async {
    final response = await _send(
      config,
      'PUT',
      uri,
      body: text,
      ifMatch: ifMatch,
    );
    if (ifMatch != null &&
        (response.statusCode == 412 || response.statusCode == 409)) {
      throw WebDavPreconditionFailed(
        '云端同步文件已被其他设备修改，将重读后重试',
        statusCode: response.statusCode,
      );
    }
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
    String? ifMatch,
    String? contentType,
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
      if (ifMatch != null) {
        request.headers.set('If-Match', ifMatch);
      }
      if (body != null) {
        request.headers.set(
          HttpHeaders.contentTypeHeader,
          contentType ?? 'application/json; charset=utf-8',
        );
        request.add(utf8.encode(body));
      }
      final response = await request.close().timeout(timeout);
      final responseBody = await response
          .transform(utf8.decoder)
          .join()
          .timeout(timeout);
      final headers = <String, String>{};
      response.headers.forEach((name, values) {
        if (values.isNotEmpty) headers[name.toLowerCase()] = values.first;
      });
      return _WebDavResponse(response.statusCode, responseBody, headers);
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
  const _WebDavResponse(this.statusCode, this.body, [this.headers = const {}]);

  final int statusCode;
  final String body;

  /// 小写 header 名 → 第一个值（`etag`、`content-length` 等）。
  final Map<String, String> headers;

  String? get etag => headers['etag'];
}

/// 从 WebDAV 的 XML 里抠一个标签值（不为了这点东西引 XML 依赖）。
String? _xmlTag(String xml, String tag) {
  final match = RegExp('<(?:[\\w-]+:)?$tag[^>]*>([^<]*)</(?:[\\w-]+:)?$tag>')
      .firstMatch(xml);
  final value = match?.group(1)?.trim();
  return value == null || value.isEmpty ? null : value;
}

final webDavClientProvider = Provider<WebDavClient>(
  (ref) => HttpWebDavClient(),
);

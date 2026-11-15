import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// WebDAV 同步配置。
///
/// 密码只进 Keychain / Keystore（[FlutterSecureStorage]），不进
/// SharedPreferences、日志或同步 JSON。`toString` 也刻意不带密码。
@immutable
class WebDavConfig {
  const WebDavConfig({
    required this.baseUrl,
    required this.username,
    required this.password,
  });

  final String baseUrl;
  final String username;
  final String password;

  bool get isComplete =>
      baseUrl.trim().isNotEmpty &&
      username.trim().isNotEmpty &&
      password.isNotEmpty;

  Uri get rootUri {
    final trimmed = baseUrl.trim();
    final withSlash = trimmed.endsWith('/') ? trimmed : '$trimmed/';
    return Uri.parse(withSlash);
  }

  /// 解析一个相对于 WebDAV 根的子路径。
  Uri resolve(String relative) => rootUri.resolve(relative);

  /// 表单里的校验；返回 null 表示可用。
  ///
  /// 只允许 HTTPS：应用密码走 Basic Auth，明文 HTTP 等于把密码交给中间人。
  String? validate() {
    if (baseUrl.trim().isEmpty) return '请填写 WebDAV 地址';
    if (username.trim().isEmpty) return '请填写账号';
    if (password.isEmpty) return '请填写应用密码';
    final uri = Uri.tryParse(baseUrl.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      return 'WebDAV 地址格式不正确';
    }
    final localhost = uri.host == '127.0.0.1' || uri.host == 'localhost';
    if (uri.scheme != 'https' && !(uri.scheme == 'http' && localhost)) {
      return 'WebDAV 地址必须使用 HTTPS';
    }
    if (uri.hasQuery || uri.hasFragment) {
      return 'WebDAV 地址不要带查询参数或锚点';
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
    'baseUrl': baseUrl,
    'username': username,
    'password': password,
  };

  static WebDavConfig? fromJson(Object? raw) {
    final map = raw is String
        ? _tryDecode(raw)
        : raw is Map
        ? Map<String, dynamic>.from(raw)
        : null;
    if (map == null) return null;
    final baseUrl = map['baseUrl']?.toString() ?? '';
    final username = map['username']?.toString() ?? '';
    final password = map['password']?.toString() ?? '';
    if (baseUrl.isEmpty || username.isEmpty || password.isEmpty) return null;
    return WebDavConfig(
      baseUrl: baseUrl,
      username: username,
      password: password,
    );
  }

  static Map<String, dynamic>? _tryDecode(String raw) {
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  @override
  String toString() =>
      'WebDavConfig(baseUrl: $baseUrl, username: $username, password: ***)';
}

/// 配置的安全读写面。测试用内存实现，生产走系统安全存储。
abstract interface class WebDavConfigStore {
  Future<WebDavConfig?> read();
  Future<void> write(WebDavConfig config);
  Future<void> clear();
}

class SecureWebDavConfigStore implements WebDavConfigStore {
  const SecureWebDavConfigStore([this._storage = const FlutterSecureStorage()]);

  final FlutterSecureStorage _storage;

  static const storageKey = 'webdav_config_v1';

  @override
  Future<WebDavConfig?> read() async {
    try {
      final raw = await _storage.read(key: storageKey);
      return WebDavConfig.fromJson(raw);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(WebDavConfig config) =>
      _storage.write(key: storageKey, value: jsonEncode(config.toJson()));

  @override
  Future<void> clear() => _storage.delete(key: storageKey);
}

/// 测试/无平台通道环境用。
class InMemoryWebDavConfigStore implements WebDavConfigStore {
  InMemoryWebDavConfigStore([this.config]);

  WebDavConfig? config;

  @override
  Future<WebDavConfig?> read() async => config;

  @override
  Future<void> write(WebDavConfig next) async => config = next;

  @override
  Future<void> clear() async => config = null;
}

final webDavConfigStoreProvider = Provider<WebDavConfigStore>(
  (ref) => const SecureWebDavConfigStore(),
);

/// 当前已保存的配置；保存/清除后 invalidate。
final webDavConfigProvider = FutureProvider<WebDavConfig?>(
  (ref) => ref.watch(webDavConfigStoreProvider).read(),
);

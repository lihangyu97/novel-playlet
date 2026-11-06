import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 可替换的安全存储读写面，测试用内存实现代替 MethodChannel。
abstract interface class SecureKeyStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

/// 生产实现：iOS Keychain（Android 侧为 Keystore/EncryptedSharedPreferences）。
class FlutterSecureKeyStorage implements SecureKeyStorage {
  const FlutterSecureKeyStorage([this._storage = const FlutterSecureStorage()]);

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
}

/// 测试与无平台通道环境用的内存实现。
class InMemorySecureKeyStorage implements SecureKeyStorage {
  final Map<String, String> _values = {};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }
}

/// 只负责一件事：生成并保管 Rust 设备池文件的 32 字节加密密钥。
///
/// 与旧项目一致的分工——密钥进 Keychain，设备池密文进应用目录；两者分离，
/// 拿到池文件也解不开。密钥丢失（Keychain 被清 / 换机）时 Rust 会把池视为
/// 空池并重新注册，不会静默降级成明文。
class SecureKeyProvider {
  SecureKeyProvider({
    SecureKeyStorage? storage,
    this.storageTimeout = const Duration(seconds: 10),
  }) : _storage = storage ?? const FlutterSecureKeyStorage();

  static final SecureKeyProvider instance = SecureKeyProvider();

  /// Rust 设备池文件密钥（base64 of 32 random bytes）。
  static const devicePoolKeyName = 'novel_playlet_device_pool_key_v1';

  final Duration storageTimeout;
  final SecureKeyStorage _storage;

  Uint8List? _cached;
  Future<Uint8List?>? _pending;
  DateTime? _failedAt;

  /// 读取（首次则生成并持久化）设备池密钥。
  ///
  /// 安全存储不可用时返回 null：启动流程照常继续，Rust 侧退化为明文池并
  /// 打日志，而不是把 App 卡死。
  Future<Uint8List?> devicePoolKey() {
    final cached = _cached;
    if (cached != null) return Future.value(cached);
    final failedAt = _failedAt;
    if (failedAt != null &&
        DateTime.now().difference(failedAt) < const Duration(seconds: 30)) {
      return Future.value(null);
    }
    return _pending ??= _loadOrCreate().whenComplete(() => _pending = null);
  }

  Future<Uint8List?> _loadOrCreate() async {
    try {
      final stored = await _storage
          .read(devicePoolKeyName)
          .timeout(storageTimeout);
      if (stored != null) {
        try {
          final decoded = base64Decode(stored);
          if (decoded.length == 32) {
            return _cached = Uint8List.fromList(decoded);
          }
        } catch (_) {
          // 损坏条目按丢失处理，下面重新生成。
        }
      }
      final fresh = Uint8List.fromList(
        List<int>.generate(32, (_) => _random.nextInt(256)),
      );
      await _storage
          .write(devicePoolKeyName, base64Encode(fresh))
          .timeout(storageTimeout);
      return _cached = fresh;
    } catch (_) {
      _failedAt = DateTime.now();
      return null;
    }
  }

  static final Random _random = Random.secure();
}

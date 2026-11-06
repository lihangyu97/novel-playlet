import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../src/rust/api.dart' as rust;
import '../../src/rust/frb_generated.dart';
import '../storage/secure_key_provider.dart';
import 'rust_bootstrap.dart';

/// 一次后端响应的原始形态。
///
/// 保持 status + bytes 的 HTTP 形状：Rust 核把所有业务结果都表达成
/// "HTTP 200 + 业务 code" 这种信封，客户端在上层再解。
class BackendResponse {
  const BackendResponse(this.statusCode, this.body, this.contentType);

  final int statusCode;
  final Uint8List body;
  final String contentType;

  String get text => utf8.decode(body, allowMalformed: true);
}

/// Rust 核传输层。
///
/// 职责只有三件事：加载 FRB 运行时、按参数 init 内核、把一次
/// （method, path, query, body）转发给内核的 `request`。签名、设备池、
/// 重试、限流全在 Rust 侧，Dart 不重复实现。
class BackendTransport {
  BackendTransport({this.port = defaultPort});

  /// 与 `assets/config/config.json` 的 port 保持一致。
  static const defaultPort = 18931;

  /// 单次请求默认超时：后端在本机进程内，正常远小于此值；挂死不能永久转圈。
  static const defaultTimeout = Duration(seconds: 20);

  final int port;

  bool _running = false;
  String _baseUrl = '';
  String _capability = '';
  int _nextRequestId = 1;

  bool get isRunning => _running;
  String get baseUrl => _baseUrl;

  /// 环回会话能力值。FFI 调用不过 socket，用不到；保留给资源 URL 拼接。
  String get capability => _capability;

  // FRB 的运行时是进程级单例，重复 init 会抛错，所以只初始化一次。
  static Future<void>? _runtimeReady;

  static Future<void> ensureRuntime() {
    final cached = _runtimeReady;
    if (cached != null) return cached;
    if (RustLib.instance.initialized) {
      return _runtimeReady = Future<void>.value();
    }
    return _runtimeReady = Future<void>.sync(initRustRuntime)
        .catchError((Object error, StackTrace stack) {
          // 失败的加载不缓存，否则一次坏初始化会让整个进程再也连不上内核。
          if (RustLib.instance.initialized) {
            RustLib.dispose();
          }
          _runtimeReady = null;
          Error.throwWithStackTrace(error, stack);
        });
  }

  /// 部署完成后启动内核。重复调用返回 "running"。
  Future<String> start({
    required String configPath,
    required String poolPath,
    required String runtimeDir,
    int? listenPort,
  }) async {
    if (_running) return 'running';
    await ensureRuntime();

    // 设备池密钥必须在 init 之前交给内核：内核第一次读池时才用得上。
    final poolKey = await SecureKeyProvider.instance.devicePoolKey();
    if (poolKey != null) {
      try {
        await rust.setDevicePoolKey(key: poolKey);
      } catch (error) {
        // 密钥交给内核失败不阻断启动：池退化为明文并告警。
        debugPrint('[backend] set_device_pool_key failed: $error');
      }
    }

    final result = await rust.init(
      configPath: configPath,
      poolPath: poolPath,
      runtimeDir: runtimeDir,
      port: listenPort ?? port,
      lanShare: false,
      mockUpstreamOrigin: '',
    );
    if (result != 'running') {
      throw StateError('Rust core failed to start: $result');
    }
    _baseUrl = await rust.baseUrl();
    _capability = await rust.sessionCapability();
    _running = true;
    return result;
  }

  /// 转发一次业务请求。
  Future<BackendResponse> send(
    String method,
    String path, {
    String? query,
    Uint8List? body,
    Duration timeout = defaultTimeout,
  }) async {
    if (!_running) {
      throw StateError('backend not started');
    }
    final response = await rust.request(
      requestId: 'r${_nextRequestId++}',
      method: method,
      path: path,
      query: query ?? '',
      body: body ?? Uint8List(0),
      timeoutMs: timeout.inMilliseconds,
    );
    if (response.status == 499) {
      throw TimeoutException('backend cancelled', timeout);
    }
    if (response.status == 504) {
      throw TimeoutException('backend timeout', timeout);
    }
    return BackendResponse(
      response.status,
      response.body,
      response.contentType,
    );
  }

  /// 测试专用：进程全局运行时已被外部 `RustLib.init` 装好。
  @visibleForTesting
  static void markRuntimeReady() {
    _runtimeReady = Future<void>.value();
  }

  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _baseUrl = '';
    _capability = '';
    await rust.shutdown();
  }
}

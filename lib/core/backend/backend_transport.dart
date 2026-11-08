import 'dart:async';
import 'dart:convert';
import 'dart:io';

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

/// 内核 504：这次请求耗尽了内核的时间预算（真实超时）。
///
/// 这是一个"可以归一成用户可见错误"的失败：`ApiClient` 会把它转成
/// `ApiException(kind: timeout)`，让上层拿到 `timeout` 语义与统一文案。
/// 与 499 取消区分开：499 仍抛 [TimeoutException]（取消不是错误，不能变成
/// 用户可见错误），由调用方像以前一样静默处理。
class BackendTimeoutException implements Exception {
  const BackendTimeoutException(this.timeout);

  /// 本次请求允许的时长。
  final Duration timeout;

  @override
  String toString() =>
      'BackendTimeoutException(after ${timeout.inMilliseconds}ms)';
}

/// Rust 核传输层。
///
/// 职责只有三件事：加载 FRB 运行时、按参数 init 内核、把一次
/// （method, path, query, body）转发给内核的 `request`。签名、设备池、
/// 重试、限流全在 Rust 侧，Dart 不重复实现。
class BackendTransport {
  BackendTransport({this.port = defaultPort});

  /// 端口唯一来源是 `assets/config/config.json`（部署后由 BackendService 读它）；
  /// 这里的缺省值与 config.json、`rust/src/config.rs` 三处对齐，改端口只改
  /// config.json。
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
      // 客户端主动取消：保持原有语义，不归一成 ApiException。
      throw TimeoutException('backend cancelled', timeout);
    }
    if (response.status == 504) {
      // 真实超时：抛可区分的异常，由 data 层的 ApiClient 归一成
      // ApiException(kind: timeout)（core 不依赖 data）。
      throw BackendTimeoutException(timeout);
    }
    return BackendResponse(
      response.status,
      response.body,
      response.contentType,
    );
  }

  /// 用**真实 socket** 探一次回环监听是否还活着。
  ///
  /// iOS 会在 App 长时间挂起后回收 listening socket 的底层资源（Apple TN2277
  /// "Networking and Multitasking"）；进程恢复后内核的 tokio listener 还在内存
  /// 里、FFI 调用照常成功，但 127.0.0.1 上已经没人 accept。任何 HTTP 客户端
  /// （AVPlayer 拉 `/src`）都会立刻得到 NSURLErrorCannotConnectToHost(-1004,
  /// "Could not connect to the server")，只有重启进程才会重新 bind。
  ///
  /// 这里**必须走 `dart:io`**：FFI 传输（[send]）不经过回环适配器，内核活着时
  /// 它永远成功，发现不了 listener 已死。所以探针是唯一能从 Dart 侧判断
  /// 「回环服务还在不在」的手段。
  ///
  /// 每次尝试单独建 [HttpClient]（连接/读 ~400ms 超时），在 [timeout] 预算内
  /// 重试；只有 HTTP 200 且 body 的 `status == "ok"` 才算健康。默认预算 5s：
  /// 内核 supervisor 的探活间隔上限是 2s（iOS 熄屏休眠会暂停单调时钟，
  /// 恢复后计时器不一定立刻到期），播放页的一次性恢复重试要覆盖这个窗口。
  Future<bool> waitForLoopbackHealthy({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    if (!isRunning) return false;
    final base = baseUrl;
    if (base.isEmpty) return false;
    final uri = Uri.tryParse('$base/health');
    if (uri == null || uri.host.isEmpty) return false;
    final deadline = DateTime.now().add(timeout);
    const attemptBudget = Duration(milliseconds: 400);
    const retryGap = Duration(milliseconds: 100);
    while (true) {
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) return false;
      final attemptTimeout = remaining < attemptBudget
          ? remaining
          : attemptBudget;
      if (await _probeLoopbackOnce(uri, attemptTimeout)) return true;
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) return false;
      await Future<void>.delayed(left < retryGap ? left : retryGap);
    }
  }

  Future<bool> _probeLoopbackOnce(Uri uri, Duration attemptTimeout) async {
    final client = HttpClient()..connectionTimeout = attemptTimeout;
    // 回环探针不该经过系统代理：代理回一个 200 会掩盖 listener 已死。
    client.findProxy = (_) => 'DIRECT';
    try {
      final request = await client.getUrl(uri).timeout(attemptTimeout);
      request.headers.set(HttpHeaders.connectionHeader, 'close');
      final response = await request.close().timeout(attemptTimeout);
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(attemptTimeout);
      if (response.statusCode != HttpStatus.ok) return false;
      final decoded = jsonDecode(body);
      return decoded is Map && decoded['status'] == 'ok';
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
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

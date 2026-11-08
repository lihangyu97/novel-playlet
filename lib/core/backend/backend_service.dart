import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'backend_transport.dart';

/// 内核启动状态机：部署运行时文件 → 启动 Rust 核。
///
/// 运行时文件全部来自 assets：`config.json`（端口等）与
/// `device_pool.example.json`（只作首次模板，之后保留内核注册出来的真实设备池）。
///
/// 响应 filter 子系统已整体删除（配置全是 disabled、永远 no-op），旧的
/// `filter.json` 不再部署；内核也不会去读它。
class BackendService {
  BackendService({
    AssetBundle? assets,
    Future<Directory> Function()? supportDirectory,
    BackendTransport? transport,
  }) : _assets = assets ?? rootBundle,
       _supportDirectory = supportDirectory ?? getApplicationSupportDirectory,
       _transport = transport ?? BackendTransport();

  static final BackendService instance = BackendService();

  final AssetBundle _assets;
  final Future<Directory> Function() _supportDirectory;
  final BackendTransport _transport;

  BackendTransport get transport => _transport;
  bool get isRunning => _transport.isRunning;

  Future<Directory>? _dirFuture;
  Future<String>? _startFuture;
  Future<bool>? _ensureLoopbackFuture;
  File? _configFile;

  /// 后端运行时目录：`<AppSupport>/backend`，内含 config/ 与内核的 src/、日志。
  Future<Directory> backendDir() => _dirFuture ??= _resolveBackendDir();

  Future<Directory> _resolveBackendDir() async {
    final support = await _supportDirectory();
    final dir = Directory('${support.path}/backend');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 启动内核（幂等：并发/重复调用共用同一次启动）。
  ///
  /// 失败不进 memo：内核起不来时「重试」必须能重新部署资源、重新 init；
  /// 早先的 `??=` 写法会把失败的 Future 永久缓存，导致启动页的重试按钮
  /// 每次都拿到同一个旧异常、永远起不来。
  Future<String> start() async {
    final cached = _startFuture;
    if (cached != null) return cached;
    final future = _start();
    _startFuture = future;
    try {
      return await future;
    } catch (_) {
      // 只清掉自己这一次失败的 memo（并发调用可能已经换上新的）。
      if (identical(_startFuture, future)) _startFuture = null;
      rethrow;
    }
  }

  /// 确保回环适配器还在监听；必要时整核重启（同端口重绑）。
  ///
  /// iOS 会在 App 长时间挂起后回收 listening socket 的资源（Apple TN2277），
  /// 内核 FFI 还活着但 127.0.0.1 上已经没人 accept，播放器报 -1004。这里探活
  /// 失败就 `shutdown` 旧内核再 `init`：Rust 侧的 supervisor 已经在自愈，
  /// 这一层是防御性兜底；重绑仍是同一端口，baseUrl 不变，`/src` 又免
  /// capability，所以已经发给播放器的 URL 继续有效。
  ///
  /// 并发调用共用同一次修复；memo 只覆盖这一次，finally 里清掉，不做永久缓存。
  Future<bool> ensureLoopback() {
    final existing = _ensureLoopbackFuture;
    if (existing != null) return existing;
    final future = _ensureLoopback();
    _ensureLoopbackFuture = future;
    return future;
  }

  Future<bool> _ensureLoopback() async {
    try {
      if (!isRunning) await start();
      if (await _transport.waitForLoopbackHealthy()) return true;
      debugPrint('[backend] loopback probe failed, restarting kernel');
      await stop();
      await start();
      return await _transport.waitForLoopbackHealthy();
    } catch (error) {
      debugPrint('[backend] loopback self-heal failed: $error');
      return false;
    } finally {
      _ensureLoopbackFuture = null;
    }
  }

  Future<String> _start() async {
    final dir = await backendDir();
    final configDir = Directory('${dir.path}/config');
    if (!await configDir.exists()) {
      await configDir.create(recursive: true);
    }

    await _deployAsset(
      'assets/config/config.json',
      '${configDir.path}/config.json',
    );
    // 设备池：只在缺失时用示例初始化，之后完全由内核维护。
    final poolFile = File('${configDir.path}/device_pool.json');
    if (!await poolFile.exists()) {
      await _deployAsset(
        'assets/config/device_pool.example.json',
        poolFile.path,
      );
    }
    _configFile = File('${configDir.path}/config.json');

    return _transport.start(
      configPath: _configFile!.path,
      poolPath: poolFile.path,
      runtimeDir: dir.path,
    );
  }

  Future<void> _deployAsset(
    String assetPath,
    String destination, {
    bool overwrite = true,
  }) async {
    final file = File(destination);
    if (!overwrite && await file.exists()) return;
    final data = await _assets.load(assetPath);
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    final current = await file.exists() ? await file.readAsBytes() : null;
    if (current != null && _sameBytes(current, bytes)) return;
    final tmp = File('$destination.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(destination);
  }

  bool _sameBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// 从部署后的 config.json 读端口，让"端口"只有一个来源。
  Future<int> configuredPort() async {
    final file = _configFile;
    if (file != null && await file.exists()) {
      try {
        final json = jsonDecode(await file.readAsString());
        if (json is Map && json['port'] is int) {
          final port = json['port'] as int;
          if (port > 0) return port;
        }
      } catch (error) {
        debugPrint('[backend] read config.json port failed: $error');
      }
    }
    return BackendTransport.defaultPort;
  }

  Future<void> stop() async {
    _startFuture = null;
    await _transport.stop();
  }
}

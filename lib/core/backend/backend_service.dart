import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'backend_transport.dart';

/// 内核启动状态机：部署运行时文件 → 启动 Rust 核。
///
/// 运行时文件全部来自 assets：`config.json`（端口等）、`filter.json`（当前
/// 全禁用，缺失即 no-op）、`device_pool.example.json`（只作首次模板，之后
/// 保留内核注册出来的真实设备池）。
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
  Future<String> start() => _startFuture ??= _start();

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
    await _deployAsset(
      'assets/config/filter.json',
      '${configDir.path}/filter.json',
      overwrite: false,
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
      filterPath: '${configDir.path}/filter.json',
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

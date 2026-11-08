import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/core/backend/backend_service.dart';
import 'package:novel_playlet/core/backend/backend_transport.dart';

/// 回环自愈（Apple TN2277）与启动重试的服务层单测。
///
/// 内核本身用 [_FakeTransport] 替身：这里锁的是「探活失败 -> 重启 -> 再探活」
/// 的状态机，不碰真 FFI / 回环。
class _FakeAssets extends AssetBundle {
  @override
  Future<ByteData> load(String key) async =>
      ByteData.sublistView(Uint8List.fromList(utf8.encode('{"port": 18931}')));
}

class _FakeTransport extends BackendTransport {
  _FakeTransport({
    this.running = true,
    List<bool> probes = const <bool>[],
    this.failStarts = 0,
    this.probeDelay = Duration.zero,
  }) : _probes = List<bool>.of(probes);

  final bool running;
  final List<bool> _probes;
  final int failStarts;
  final Duration probeDelay;

  int startCalls = 0;
  int stopCalls = 0;

  @override
  bool get isRunning => running;

  @override
  Future<String> start({
    required String configPath,
    required String poolPath,
    required String runtimeDir,
    int? listenPort,
  }) async {
    startCalls += 1;
    if (startCalls <= failStarts) {
      throw StateError('kernel start failed (test)');
    }
    return 'running';
  }

  @override
  Future<void> stop() async {
    stopCalls += 1;
  }

  @override
  Future<bool> waitForLoopbackHealthy({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    if (probeDelay > Duration.zero) {
      await Future<void>.delayed(probeDelay);
    }
    if (_probes.isEmpty) return false;
    return _probes.removeAt(0);
  }
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('novel_playlet_service_');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  BackendService serviceFor(_FakeTransport transport) => BackendService(
    assets: _FakeAssets(),
    supportDirectory: () async => tempDir,
    transport: transport,
  );

  test('ensureLoopback: 探针健康时不重启内核', () async {
    final transport = _FakeTransport(probes: [true]);
    final service = serviceFor(transport);

    expect(await service.ensureLoopback(), isTrue);
    expect(transport.startCalls, 0);
    expect(transport.stopCalls, 0);
  });

  test('ensureLoopback: 探活失败 -> stop + start 后再次探活成功', () async {
    final transport = _FakeTransport(probes: [false, true]);
    final service = serviceFor(transport);

    expect(await service.ensureLoopback(), isTrue);
    expect(transport.stopCalls, 1, reason: '探活失败要整核重启才能重新 bind');
    expect(transport.startCalls, 1);
  });

  test('ensureLoopback: 重启后仍探活失败 -> false，且不永久缓存失败', () async {
    final transport = _FakeTransport(probes: [false, false, true]);
    final service = serviceFor(transport);

    expect(await service.ensureLoopback(), isFalse);
    expect(await service.ensureLoopback(), isTrue, reason: 'memo 必须是一次性的');
    expect(transport.stopCalls, 1);
    expect(transport.startCalls, 1);
  });

  test('ensureLoopback: 并发调用共用同一次修复', () async {
    final transport = _FakeTransport(
      probes: [false, true],
      probeDelay: const Duration(milliseconds: 10),
    );
    final service = serviceFor(transport);

    final first = service.ensureLoopback();
    final second = service.ensureLoopback();
    expect(identical(first, second), isTrue);

    expect(await Future.wait([first, second]), [true, true]);
    expect(transport.stopCalls, 1);
    expect(transport.startCalls, 1);
  });

  test('ensureLoopback: 内核未运行 -> 先 start 再探活', () async {
    final transport = _FakeTransport(running: false, probes: [true]);
    final service = serviceFor(transport);

    expect(await service.ensureLoopback(), isTrue);
    expect(transport.startCalls, 1);
    expect(transport.stopCalls, 0);
  });

  test('start: 失败的启动不永久缓存，重试会重新拉起内核', () async {
    final transport = _FakeTransport(running: false, failStarts: 1);
    final service = serviceFor(transport);

    await expectLater(service.start(), throwsA(isA<StateError>()));
    expect(transport.startCalls, 1);

    expect(await service.start(), 'running');
    expect(transport.startCalls, 2, reason: '启动页「重试」必须真的重新启动');
  });
}

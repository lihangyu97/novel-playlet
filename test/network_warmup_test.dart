import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/core/backend/backend_transport.dart';
import 'package:novel_playlet/data/api/api_client.dart';

/// 只记录请求路径、回固定响应的传输层：锁 [ApiClient.warmUpNetwork] 的调用
/// 路径与失败处理，不碰真实内核。
class _StubTransport extends BackendTransport {
  _StubTransport({this.statusCode = 200, this.payload = '{"code":0}'});

  final int statusCode;
  final String payload;

  final calls = <String>[];

  @override
  Future<BackendResponse> send(
    String method,
    String path, {
    String? query,
    Uint8List? body,
    Duration timeout = BackendTransport.defaultTimeout,
  }) async {
    calls.add(path);
    return BackendResponse(
      statusCode,
      Uint8List.fromList(utf8.encode(payload)),
      'application/json',
    );
  }
}

/// 首次安装时系统联网权限弹窗要等 App 第一次真实联网才出现：启动期先打
/// 一发最小请求，把弹窗提前到启动页（见 `bootstrapProvider`）。
void main() {
  test('warmUpNetwork 发一次轻量请求（触发系统联网权限弹窗）', () async {
    final transport = _StubTransport();
    await ApiClient(transport).warmUpNetwork();
    expect(transport.calls, ['/api/v1/search/cue']);
  });

  test('warmUpNetwork 吞掉失败，不影响启动', () async {
    final transport = _StubTransport(
      statusCode: 500,
      payload: '{"message":"boom"}',
    );
    await expectLater(ApiClient(transport).warmUpNetwork(), completes);
    expect(transport.calls, hasLength(1));
  });
}

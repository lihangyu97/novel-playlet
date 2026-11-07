import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/core/backend/backend_transport.dart';
import 'package:novel_playlet/data/api/api_client.dart';

/// `mode=cached` / `variants=0` 的接口契约（S2）：缓存探测不打上游、返回
/// `/src` 绝对地址；正常取流不再索要 variants。
class _FakeTransport extends BackendTransport {
  _FakeTransport(this.payload) : super(port: 18931);

  final Map<String, dynamic> payload;
  final List<String> calls = <String>[];

  @override
  String get baseUrl => 'http://127.0.0.1:18931';

  @override
  Future<BackendResponse> send(
    String method,
    String path, {
    String? query,
    Uint8List? body,
    Duration timeout = BackendTransport.defaultTimeout,
  }) async {
    calls.add('$method $path?${query ?? ''}');
    return BackendResponse(
      200,
      Uint8List.fromList(utf8.encode(jsonEncode(payload))),
      'application/json',
    );
  }
}

void main() {
  test('cached 命中：返回 /src 绝对地址，且只带 mode=cached', () async {
    final transport = _FakeTransport({
      'code': 0,
      'data': {'cached': true, 'video_url': '/src/e1.mp4'},
    });
    final api = ApiClient(transport);
    expect(await api.cachedVideoUrl('e1'), 'http://127.0.0.1:18931/src/e1.mp4');
    expect(transport.calls, hasLength(1));
    expect(transport.calls.single, contains('mode=cached'));
    expect(transport.calls.single, contains('/api/v1/videos/e1'));
  });

  test('cached 未命中返回 null（调用方回退正常取流）', () async {
    final transport = _FakeTransport({
      'code': 0,
      'data': {'cached': false},
    });
    expect(await ApiClient(transport).cachedVideoUrl('e1'), isNull);
  });

  test('cached 返回空地址当 miss，不让播放器拼出空 URL', () async {
    final transport = _FakeTransport({
      'code': 0,
      'data': {'cached': true, 'video_url': ''},
    });
    expect(await ApiClient(transport).cachedVideoUrl('e1'), isNull);
  });

  test('正常取流带 variants=0：播放页不需要清晰度列表', () async {
    final transport = _FakeTransport({
      'code': 0,
      'data': {'video_url': '/src/e1.mp4', 'key_hex': ''},
    });
    final source = await ApiClient(transport).videoSource('e1');
    expect(source.url, 'http://127.0.0.1:18931/src/e1.mp4');
    expect(transport.calls.single, contains('variants=0'));
  });

  test('refresh=1 与 variants=0 同时出现', () async {
    final transport = _FakeTransport({
      'code': 0,
      'data': {'video_url': '/src/e1.mp4', 'key_hex': ''},
    });
    await ApiClient(transport).videoSource('e1', refresh: true);
    expect(transport.calls.single, contains('refresh=1'));
    expect(transport.calls.single, contains('variants=0'));
  });
}

import 'json_utils.dart';

/// 一集的可播放源。
///
/// `/api/v1/videos/{id}` 默认模式会先把整集下载进内核缓存（密文），返回
/// `video_url: "/src/xxx.mp4"`；`?mode=stream` 则返回上游 CDN 地址 + 内容
/// 密钥（需要客户端边读边解密，暂未接入）。两种形态共用这个模型，
/// [url] 由 ApiClient 负责拼成绝对地址。
class VideoSource {
  const VideoSource({
    required this.url,
    this.keyHex = '',
    this.variants = const [],
  });

  final String url;

  /// CENC 内容密钥（hex）。下载模式下由 `/src` 服务端解密，播放器不需要它。
  final String keyHex;

  /// 全部清晰度档（高→低）。本轮不支持切换，保留给后续。
  final List<VideoVariant> variants;

  bool get isValid => url.isNotEmpty;

  factory VideoSource.fromPayload(Map<String, dynamic> payload) {
    final data = unwrapEnvelope(payload);
    final raw = firstString(data, ['video_url', 'main_url', 'url']);
    final variants = <VideoVariant>[];
    for (final entry in asList(data['variants'])) {
      final row = asMap(entry);
      if (row == null) continue;
      final url = firstString(row, ['url']);
      if (url.isEmpty) continue;
      variants.add(
        VideoVariant(
          name: firstString(row, ['name']),
          url: url,
          height: asInt(row['height']),
        ),
      );
    }
    return VideoSource(
      url: raw,
      keyHex: firstString(data, ['key_hex']),
      variants: variants,
    );
  }
}

class VideoVariant {
  const VideoVariant({required this.name, required this.url, this.height = 0});

  final String name;
  final String url;
  final int height;
}

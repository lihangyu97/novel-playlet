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
    this.appliedVariant,
    this.qualityFallback = false,
  });

  final String url;

  /// CENC 内容密钥（hex）。下载模式下由 `/src` 服务端解密，播放器不需要它。
  final String keyHex;

  /// 全部清晰度档（高→低）。播放页暂未消费，留给后续清晰度面板。
  final List<VideoVariant> variants;

  /// 本次实际选中的档位（请求了 `max_height` 时由内核返回）。
  final VideoVariant? appliedVariant;

  /// 请求档不可用、回退到了别的档（如要 480P 只有 720P）。
  final bool qualityFallback;

  bool get isValid => url.isNotEmpty;

  factory VideoSource.fromPayload(Map<String, dynamic> payload) {
    final data = unwrapEnvelope(payload);
    final raw = firstString(data, ['video_url', 'main_url', 'url']);
    final variants = <VideoVariant>[];
    for (final entry in asList(data['variants'])) {
      final row = asMap(entry);
      if (row == null) continue;
      final variant = VideoVariant.tryFromRow(row);
      if (variant != null && variant.url.isNotEmpty) variants.add(variant);
    }
    return VideoSource(
      url: raw,
      keyHex: firstString(data, ['key_hex']),
      variants: variants,
      appliedVariant: VideoVariant.tryFromRow(asMap(data['variant'])),
      qualityFallback: data['quality_fallback'] == true,
    );
  }
}

class VideoVariant {
  const VideoVariant({
    required this.name,
    required this.url,
    this.width = 0,
    this.height = 0,
    this.shortEdge = 0,
  });

  final String name;
  final String url;
  final int width;
  final int height;

  /// 清晰度语义按短边：竖屏 720×1280 是 720P（不是 2K）。
  final int shortEdge;

  static VideoVariant? tryFromRow(Map<String, dynamic>? row) {
    if (row == null) return null;
    final name = firstString(row, ['name']);
    final url = firstString(row, ['url']);
    final width = asInt(row['width']);
    final height = asInt(row['height']);
    var shortEdge = asInt(row['short_edge']);
    if (shortEdge <= 0) {
      if (width > 0 && height > 0) {
        shortEdge = width < height ? width : height;
      } else {
        shortEdge = width > height ? width : height;
      }
    }
    if (name.isEmpty && url.isEmpty) return null;
    return VideoVariant(
      name: name,
      url: url,
      width: width,
      height: height,
      shortEdge: shortEdge,
    );
  }
}

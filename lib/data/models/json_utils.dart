/// 上游 JSON 的防御性读取工具。
///
/// Rust 核把上游响应原样透传（只做正文解密），字段类型不稳定：数值经常是
/// 字符串、列表经常是单对象、id 有时是数字会被截断。所有解析只信赖这两条
/// 规则：能转成字符串就用字符串；转不出就给默认值，绝不抛。
library;

String asString(Object? value, [String fallback = '']) {
  if (value == null) return fallback;
  if (value is String) return value;
  if (value is num || value is bool) return value.toString();
  return fallback;
}

int asInt(Object? value, [int fallback = 0]) {
  if (value == null) return fallback;
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) {
    final parsed = int.tryParse(value.trim());
    if (parsed != null) return parsed;
    return double.tryParse(value.trim())?.toInt() ?? fallback;
  }
  return fallback;
}

double? asDouble(Object? value) {
  if (value == null) return null;
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value.trim());
  return null;
}

Map<String, dynamic>? asMap(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) {
    return value.map((key, val) => MapEntry(key.toString(), val));
  }
  return null;
}

List<dynamic> asList(Object? value) {
  if (value is List) return value;
  if (value == null) return const [];
  return [value];
}

/// 封面字段优先级：缩略图 > 详情页缩略图 > 疑似原图。
///
/// 上游同一本书会同时给 `thumb_url`（列表小图）、`detail_page_thumb_url`
/// （详情页图，尺寸大得多）和 `cover`/`cover_url`（原图，1080~1440 宽、
/// 单张 1~3 MB）。全 App 的封面位最大也就 108pt 宽，一律取最小的那张。
const coverKeys = ['thumb_url', 'detail_page_thumb_url', 'cover_url', 'cover'];

/// 取第一个非空字符串字段。
String firstString(Map<String, dynamic> map, List<String> keys) {
  for (final key in keys) {
    final value = asString(map[key]).trim();
    if (value.isNotEmpty) return value;
  }
  return '';
}

/// 展开 `{code, data}` 信封，兼容 Rust 的 200 信封与上游的 0 信封。
///
/// 业务失败抛 [ApiException]；成功返回 `data`（可能不存在）。
Map<String, dynamic> unwrapEnvelope(Map<String, dynamic> payload) {
  final code = payload['code'];
  final success = payload['success'];
  final explicitFailure = success == false;
  final badCode =
      code != null && asInt(code, -1) != 0 && asInt(code, -1) != 200;
  if (explicitFailure || badCode) {
    final message = firstString(payload, ['message', 'msg', 'error', 'errmsg']);
    throw ApiException(message.isEmpty ? '请求失败（code=$code）' : message);
  }
  final data = payload['data'];
  return asMap(data) ?? payload;
}

/// 业务/网络错误，页面只负责展示 [message]。
class ApiException implements Exception {
  ApiException(this.message, {this.code});

  final String message;
  final String? code;

  @override
  String toString() => 'ApiException($message)';
}

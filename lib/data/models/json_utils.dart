/// 上游 JSON 的防御性读取工具。
///
/// Rust 核把上游响应原样透传（只做正文解密），字段类型不稳定：数值经常是
/// 字符串、列表经常是单对象、id 有时是数字会被截断。所有解析只信赖这两条
/// 规则：能转成字符串就用字符串；转不出就给默认值，绝不抛。
library;

import 'dart:convert';

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

/// 从上游「推荐理由」字段里取第一条可展示文案。
///
/// 同名字段在两条链路里形状不同（实测 2026-11-08）：
/// - 小说推荐：`recommend_reason_list` 是数组，元素是对象，如
///   `[{content: "巅峰榜No.3", can_click: true, ...}]`；
/// - 短剧/漫剧推荐：`recommend_reason_list` 是 **JSON 字符串**，常见形态
///   `{"tag_info":{"text":"上新"},"rec_tags":[{"content":"系列剧·40万人在追"}],
///     "sub_title_list":[{"content":"剧情"}]}`。
///
/// 统一规则：数组取第一个有文案的元素；对象优先 `rec_tags[]`（真正的推荐
/// 理由，按顺序取第一个），其次 `tag_info.text`（「上新/热门/爆款」角标），
/// 再次 `sub_title_list[]` / `secondary_info_list[]`；字符串先当 JSON 解析，
/// 解析失败原样返回。空串 / `0` 一律视为没有理由。
String firstReasonText(Object? raw) => _reasonTextOf(raw, 0);

String _reasonTextOf(Object? raw, int depth) {
  if (raw == null || depth > 4) return '';
  if (raw is String) {
    final text = raw.trim();
    if (text.isEmpty) return '';
    if (!text.startsWith('{') && !text.startsWith('[')) return _cleanText(text);
    try {
      return _reasonTextOf(jsonDecode(text), depth + 1);
    } catch (_) {
      // 不是合法 JSON（或半截字符串）：按原始文案展示。
      return _cleanText(text);
    }
  }
  if (raw is List) {
    for (final item in raw) {
      final text = _reasonTextOf(item, depth + 1);
      if (text.isNotEmpty) return text;
    }
    return '';
  }
  if (raw is Map) {
    final map = asMap(raw)!;
    // 数组元素自身的文案字段（小说 reason 数组就是这个形状）。
    for (final key in const ['content', 'text', 'recommend_reason']) {
      final text = _cleanText(asString(map[key]));
      if (text.isNotEmpty) return text;
    }
    // 真正的推荐理由优先；「上新/热门/爆款」角标次之（漫剧只有角标时，
    // sub_title_list 里是「剧情/149集」这类和卡片信息重复的分类，放最后）。
    final recTags = _reasonTextOf(map['rec_tags'], depth + 1);
    if (recTags.isNotEmpty) return recTags;
    final tagInfo = asMap(map['tag_info']);
    if (tagInfo != null) {
      final text = _cleanText(asString(tagInfo['text']));
      if (text.isNotEmpty) return text;
    }
    for (final key in const ['sub_title_list', 'secondary_info_list']) {
      final text = _reasonTextOf(map[key], depth + 1);
      if (text.isNotEmpty) return text;
    }
    return '';
  }
  return _cleanText(asString(raw));
}

String _cleanText(String value) {
  final text = value.trim();
  return text == '0' || text == '0.0' ? '' : text;
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
    throw ApiException(
      message.isEmpty ? '请求失败（code=$code）' : message,
      kind: ApiErrorKind.fromWire(payload['kind']),
    );
  }
  final data = payload['data'];
  return asMap(data) ?? payload;
}

/// 业务错误的语义分类，与 Rust 核的 `kind` wire 值一一对应。
///
/// 契约（与内核并行开发）：错误 JSON 为
/// `{"success":false,"error":"...","kind":"<wire 值>"}`；缺失或不认识的
/// `kind` 一律算 [unknown]。这里只暴露语义，重试/退避策略仍在 Rust 侧，
/// Dart 不新增重试逻辑。
enum ApiErrorKind {
  badInput('bad_input'),
  deviceFailed('device_failed'),
  rateLimited('rate_limited'),
  upstream5xx('upstream_5xx'),
  timeout('timeout'),
  tooLarge('too_large'),
  unknown('unknown');

  const ApiErrorKind(this.wireName);

  /// 内核 JSON 里的 `kind` 取值。
  final String wireName;

  /// 是否值得"稍后再试一次"：只有上游/网络侧的瞬时失败算可重试。
  ///
  /// 这里只描述语义，Dart 不实现重试循环（Rust 核已有重试/退避，Dart 再循环
  /// 只会放大请求）。[badInput] 是确定性错误，同一请求重试不会变好；
  /// [tooLarge] 是体积上限；[unknown] 无法判断；[deviceFailed] 见
  /// [needsRestart]。因此它们都不算 transient。
  bool get isTransient => switch (this) {
    ApiErrorKind.rateLimited ||
    ApiErrorKind.upstream5xx ||
    ApiErrorKind.timeout => true,
    ApiErrorKind.badInput ||
    ApiErrorKind.deviceFailed ||
    ApiErrorKind.tooLarge ||
    ApiErrorKind.unknown => false,
  };

  /// 需要用户重启应用/重新注册设备才能恢复。
  ///
  /// 和 [isTransient] 互斥：这不是"再请求一次"能解决的，UI 应给"重启应用"
  /// 类提示，而不是普通重试。
  bool get needsRestart => this == ApiErrorKind.deviceFailed;

  /// kind 的兜底人话短句。
  ///
  /// 只在后端 message 是 "HTTP 500" 这类技术兜底时使用（见 [apiErrorCopy]）；
  /// 后端给出具体原因时优先展示具体原因。[badInput]/[unknown] 没有可靠的
  /// 通用短句，返回空串。
  String get userCopy => switch (this) {
    ApiErrorKind.rateLimited => '请求太频繁，稍后重试',
    ApiErrorKind.timeout => '网络超时，请重试',
    ApiErrorKind.upstream5xx => '上游服务异常，稍后重试',
    ApiErrorKind.deviceFailed => '设备注册失效，请重启应用',
    ApiErrorKind.tooLarge => '内容过大，暂时无法加载',
    ApiErrorKind.badInput => '',
    ApiErrorKind.unknown => '',
  };

  /// 从 `kind` 字段解析；null / 空 / 未知值都退回 [unknown]。
  static ApiErrorKind fromWire(Object? value) {
    final wire = asString(value).trim();
    for (final kind in values) {
      if (kind.wireName == wire) return kind;
    }
    return unknown;
  }
}

/// 业务/网络错误，页面只负责展示 [message]。
class ApiException implements Exception {
  ApiException(this.message, {this.code, this.kind = ApiErrorKind.unknown});

  final String message;
  final String? code;

  /// 错误语义分类；本地构造、HTTP 非 200 无 JSON、格式异常等一律 unknown。
  final ApiErrorKind kind;

  /// 是否值得"再点一次重试"。
  ///
  /// [ApiErrorKind.isTransient] 的瞬时失败肯定可重试；[ApiErrorKind.unknown]
  /// 无法判断，保守给重试（保持"失败可重试"的旧行为）；[badInput] /
  /// [tooLarge] 是确定性失败、[deviceFailed] 需要重启，都不给重试。
  bool get isRetryable => kind.isTransient || kind == ApiErrorKind.unknown;

  /// 是否需要重启应用（设备注册失效）；语义见 [ApiErrorKind.needsRestart]。
  bool get needsRestart => kind.needsRestart;

  @override
  String toString() => 'ApiException($message)';
}

/// 后端 message 是不是"技术兜底"，而不是一句给人看的具体原因。
///
/// 内核把上游错误压成 `{"error":"HTTP 500","kind":"upstream_5xx"}` 这种形态；
/// 这类 message 展示给用户没有信息量，应换成 kind 的短句。
bool _isGenericApiMessage(String message) {
  if (message.isEmpty) return true;
  return RegExp(r'^(HTTP \d{3}|请求失败（HTTP \d{3}）|请求失败（code=[^）]*）)$')
      .hasMatch(message);
}

/// 把任意异常翻译成一句给用户看的文案（错误页/底部提示/播放页共用）。
///
/// 策略（错误页结构、重试按钮由页面决定，这里只管文案）：
/// 1. 非 [ApiException]（本地解析/IO 等意外）→ [fallback]；
/// 2. [ApiErrorKind.badInput] / [ApiErrorKind.unknown] 没有可靠短句 → 优先
///    后端 message（badInput 的 message 说明"到底哪里错了"，比任何通用短句
///    都有用），缺失才 [fallback]；
/// 3. 其余 known kind：后端 message 具体就保留（不把细节盖掉），只有它是
///    "HTTP 500" 这类技术兜底时才换成 [ApiErrorKind.userCopy]。
String apiErrorCopy(Object error, {required String fallback}) {
  if (error is! ApiException) return fallback;
  final message = error.message.trim();
  switch (error.kind) {
    case ApiErrorKind.badInput:
    case ApiErrorKind.unknown:
      return message.isEmpty ? fallback : message;
    case ApiErrorKind.rateLimited:
    case ApiErrorKind.upstream5xx:
    case ApiErrorKind.timeout:
    case ApiErrorKind.deviceFailed:
    case ApiErrorKind.tooLarge:
      return _isGenericApiMessage(message) ? error.kind.userCopy : message;
  }
}

/// "再点一次重试"是否有意义：类型化的 [ApiException] 按 kind 判断；其它异常
/// （解析/IO 等意外）按可重试处理。
bool isRetryableError(Object error) =>
    error is! ApiException || error.isRetryable;

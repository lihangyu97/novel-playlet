import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../storage/offline/offline_paths.dart';

/// 日志级别：`error` 是明确失败的报错；`unexpected` 是没按预期走、但可能已经
/// 兜底恢复的事件（响应形状不对、回退备用接口等）。
enum LogLevel {
  error('error'),
  unexpected('unexpected');

  const LogLevel(this.wire);

  final String wire;

  static LogLevel parse(Object? value) {
    final wire = _text(value);
    for (final level in values) {
      if (level.wire == wire) return level;
    }
    return LogLevel.error;
  }
}

/// 日志来源：接口层、App 运行时（Flutter 未捕获异常）或 WebDAV 同步。
enum DiagnosticSource {
  api('api'),
  app('app'),
  sync('sync');

  const DiagnosticSource(this.wire);

  final String wire;

  static DiagnosticSource parse(Object? value) {
    final wire = _text(value);
    for (final source in values) {
      if (source.wire == wire) return source;
    }
    return DiagnosticSource.app;
  }
}

/// 一条诊断日志。
///
/// [message] 是列表行上的一行摘要（接口失败已带 method + path）；[detail] 是
/// 展开后的上下文（HTTP 状态、错误 kind、耗时或异常堆栈）。两者都不放查询
/// 参数/凭据：搜索词、阅读记录这类用户数据不进诊断日志。
class DiagnosticEntry {
  const DiagnosticEntry({
    required this.at,
    required this.level,
    required this.source,
    required this.message,
    this.detail,
    this.count = 1,
  });

  final int at;
  final LogLevel level;
  final DiagnosticSource source;
  final String message;
  final String? detail;

  /// 窗口内重复出现的次数。同一接口连续报错时合并成一行，避免刷屏。
  final int count;

  DateTime get atTime => DateTime.fromMillisecondsSinceEpoch(at);

  DiagnosticEntry repeated() => DiagnosticEntry(
    at: at,
    level: level,
    source: source,
    message: message,
    detail: detail,
    count: count + 1,
  );

  Map<String, dynamic> toJson() => {
    'at': at,
    'lv': level.wire,
    'src': source.wire,
    'msg': message,
    if (detail != null && detail!.isNotEmpty) 'det': detail,
    if (count > 1) 'n': count,
  };

  static DiagnosticEntry? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final json = Map<String, dynamic>.from(raw);
    final message = _text(json['msg']);
    if (message.isEmpty) return null;
    final detail = _text(json['det']);
    final count = _int(json['n']);
    return DiagnosticEntry(
      at: _int(json['at']),
      level: LogLevel.parse(json['lv']),
      source: DiagnosticSource.parse(json['src']),
      message: message,
      detail: detail.isEmpty ? null : detail,
      count: count < 1 ? 1 : count,
    );
  }
}

/// 本地运行日志：`<AppSupport>/app-log.json`，只留最近 [maxEntries] 条。
///
/// 和同步记录一样是**本机诊断数据**：不进 `library.db`、不进同步载荷。
/// 写入全是 best-effort——日志写失败绝不能反过来影响业务。
class DiagnosticLogStore {
  static const int maxEntries = 300;

  /// 同一级别 + 来源 + 摘要在这个窗口内重复出现时合并计数，而不是新增一行。
  static const int duplicateWindowMs = 8000;

  /// 单条摘要/上下文的长度上限：日志是排障用的，别让一段巨型堆栈把文件撑爆。
  static const int maxMessageChars = 500;
  static const int maxDetailChars = 4000;

  /// 全局唯一实例：ApiClient 与全局错误捕获共用同一份写队列，避免并发写坏文件。
  static final DiagnosticLogStore instance = DiagnosticLogStore();

  /// 测试注入用；为 null 时落到 `<AppSupport>/app-log.json`。
  static String? overridePath;

  Future<void> _tail = Future<void>.value();

  Future<File> _file() async {
    final path =
        overridePath ??
        '${(await getApplicationSupportDirectory()).path}/app-log.json';
    return File(path);
  }

  Future<List<DiagnosticEntry>> read() async {
    try {
      final file = await _file();
      if (!await file.exists()) return <DiagnosticEntry>[];
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return <DiagnosticEntry>[];
      final entries = [
        for (final raw in _list(decoded['entries']))
          ?DiagnosticEntry.tryFromJson(raw),
      ];
      // 文件可能被旧版本/手工改成乱序或超长，读的时候统一整理，页面只按
      // 倒序假设渲染；下一次写入也会把整理后的结果落盘。
      entries.sort((a, b) => b.at.compareTo(a.at));
      return entries.take(maxEntries).toList(growable: false);
    } catch (_) {
      // 坏文件按空日志处理；下一次写入会覆盖它。
      return <DiagnosticEntry>[];
    }
  }

  /// 记一条（不等待落盘）。调用点都在错误路径上，不能为此拖慢请求。
  void record({
    required LogLevel level,
    required DiagnosticSource source,
    required String message,
    String? detail,
  }) {
    final text = message.trim();
    if (text.isEmpty) return;
    final trimmedDetail = detail?.trim() ?? '';
    unawaited(
      append(
        DiagnosticEntry(
          at: DateTime.now().millisecondsSinceEpoch,
          level: level,
          source: source,
          message: _clip(text, maxMessageChars),
          detail: trimmedDetail.isEmpty
              ? null
              : _clip(trimmedDetail, maxDetailChars),
        ),
      ),
    );
  }

  /// 追加一条，超出上限的旧记录丢掉。
  ///
  /// 串行化所有写入：多条日志同时触发时，读-改-写不会互相覆盖。
  Future<void> append(DiagnosticEntry entry) {
    final next = _tail.then((_) => _append(entry));
    _tail = next.catchError((Object _) {});
    return next;
  }

  /// 等待已排队的写入完成；测试与退出前用。
  Future<void> flush() => _tail;

  Future<void> _append(DiagnosticEntry entry) async {
    try {
      final entries = List<DiagnosticEntry>.of(await read());
      if (entries.isNotEmpty && _isRepeat(entries.first, entry)) {
        entries[0] = entries.first.repeated();
      } else {
        entries.insert(0, entry);
      }
      final kept = entries.take(maxEntries).toList(growable: false);
      await writeJsonAtomically(await _file(), {
        'v': 1,
        'entries': [for (final item in kept) item.toJson()],
      });
    } catch (error) {
      // 诊断日志不能反过来制造故障：写不进去就只在控制台留一句。
      debugPrint('[diagnostics] append failed: $error');
    }
  }

  /// 清空日志。同样排进写队列，避免和正在落盘的日志抢同一个文件。
  Future<void> clear() {
    final next = _tail.then((_) => _clearFile());
    _tail = next.catchError((Object _) {});
    return next;
  }

  Future<void> _clearFile() async {
    try {
      final file = await _file();
      if (await file.exists()) await file.delete();
    } catch (error) {
      debugPrint('[diagnostics] clear failed: $error');
    }
  }
}

bool _isRepeat(DiagnosticEntry previous, DiagnosticEntry entry) {
  final delta = entry.at - previous.at;
  return delta >= 0 &&
      delta <= DiagnosticLogStore.duplicateWindowMs &&
      previous.level == entry.level &&
      previous.source == entry.source &&
      previous.message == entry.message;
}

final diagnosticLogStoreProvider = Provider<DiagnosticLogStore>(
  (ref) => DiagnosticLogStore.instance,
);

/// 运行日志页的数据源。
///
/// 用 autoDispose：每次打开页面重新读一次文件，避免停留在一个旧快照上；
/// 清空后页面自己 invalidate 即可。
final diagnosticLogEntriesProvider =
    FutureProvider.autoDispose<List<DiagnosticEntry>>((ref) async {
      final store = ref.watch(diagnosticLogStoreProvider);
      // 先等排队中的写入落盘，否则刚发生的错误可能在打开页面时还读不到。
      await store.flush();
      return store.read();
    });

/// 日志文本脱敏：URL 只保留 `scheme://host/path`，去掉可能含设备标识/
/// 凭据的查询串。
String redactLogUrlQueries(String text) {
  return text.replaceAllMapped(RegExp(r'https?://[^\s)<>"]+'), (match) {
    final uri = Uri.tryParse(match[0]!);
    if (uri == null || uri.host.isEmpty) return '<url>';
    return '${uri.scheme}://${uri.host}${uri.path}';
  });
}

String _text(Object? value) => value == null ? '' : '$value';

int _int(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(_text(value)) ?? 0;
}

List<dynamic> _list(Object? value) => value is List ? value : const [];

String _clip(String value, int max) =>
    value.length <= max ? value : '${value.substring(0, max)}…';

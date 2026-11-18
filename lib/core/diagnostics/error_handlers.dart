import 'dart:ui';

import 'package:flutter/foundation.dart';

import 'diagnostic_log.dart';

/// 安装全局错误捕获：Flutter 框架错误与未捕获的异步错误都落一条运行日志。
///
/// 只做记录，不改变原来的错误处理：框架错误继续交给原来的
/// [FlutterError.onError]（默认 [FlutterError.presentError]，debug 下打印、
/// release 下打到系统日志）；异步错误返回 false，让默认处理器接手。
void installDiagnosticErrorHandlers([DiagnosticLogStore? store]) {
  final log = store ?? DiagnosticLogStore.instance;

  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    log.record(
      level: DiagnosticLevel.error,
      source: DiagnosticSource.app,
      message: _firstLine(details.exceptionAsString()),
      detail: details.stack?.toString() ?? details.toString(),
    );
    if (previous != null) {
      previous(details);
    } else {
      FlutterError.presentError(details);
    }
  };

  PlatformDispatcher.instance.onError = (error, stack) {
    log.record(
      level: DiagnosticLevel.error,
      source: DiagnosticSource.app,
      message: _firstLine('$error'),
      detail: stack.toString(),
    );
    // false = 继续走默认处理（release 下仍会进系统日志），不要悄悄吞掉错误。
    return false;
  };
}

String _firstLine(String text) {
  final line = text.split('\n').first.trim();
  return line.isEmpty ? '未知异常' : line;
}

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/core/diagnostics/diagnostic_log.dart';
import 'package:novel_playlet/core/diagnostics/error_handlers.dart';

void main() {
  late Directory dir;
  late FlutterExceptionHandler? previousFramework;
  late bool Function(Object, StackTrace)? previousPlatform;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('app-log-handler-test');
    DiagnosticLogStore.overridePath = '${dir.path}/app-log.json';
    previousFramework = FlutterError.onError;
    previousPlatform = PlatformDispatcher.instance.onError;
  });

  tearDown(() async {
    FlutterError.onError = previousFramework;
    PlatformDispatcher.instance.onError = previousPlatform;
    DiagnosticLogStore.overridePath = null;
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('silent 错误只透传不落日志，普通错误记录并透传', () async {
    final forwarded = <FlutterErrorDetails>[];
    FlutterError.onError = forwarded.add;
    final store = DiagnosticLogStore();
    installDiagnosticErrorHandlers(store);

    FlutterError.reportError(
      FlutterErrorDetails(
        exception: StateError('封面图加载失败'),
        stack: StackTrace.current,
        silent: true,
      ),
    );
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: StateError('真正的框架错误'),
        stack: StackTrace.current,
      ),
    );
    await store.flush();

    expect(forwarded, hasLength(2), reason: 'silent 也要交给原处理器');
    final entries = await store.read();
    expect(entries, hasLength(1));
    expect(entries.single.message, contains('真正的框架错误'));
    expect(entries.single.source, DiagnosticSource.app);
  });

  test('未捕获异步错误记录后返回 false，交回默认处理', () async {
    final store = DiagnosticLogStore();
    installDiagnosticErrorHandlers(store);

    final handled = PlatformDispatcher.instance.onError!(
      StateError('异步炸了'),
      StackTrace.current,
    );
    await store.flush();

    expect(handled, isFalse);
    final entry = (await store.read()).single;
    expect(entry.message, contains('异步炸了'));
    expect(entry.level, LogLevel.error);
  });
}

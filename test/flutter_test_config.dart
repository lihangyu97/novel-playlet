import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/features/sync/sync_log.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/library_test_db.dart';

/// 全局测试引导（`flutter test` 会先跑这里再跑各文件的 `main`）。
///
/// 1. sqflite 切成桌面 FFI + 内存库；
/// 2. 准备一个空的 prefs mock；
/// 3. 每个用例前重置内存库，替代旧的 `setMockInitialValues` 语义。
///
/// **不要在这里 `TestWidgetsFlutterBinding.ensureInitialized()`**：绑定一旦在
/// 全局引导里初始化，会给所有测试（包括 `webdav_client_test` 这类纯 Dart 用例）
/// 装上返回 400 的 HttpOverrides，真实 loopback 请求全部失败。需要绑定的
/// `testWidgets` 自己会初始化，`setMockInitialValues` 不依赖绑定。
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  setupLibraryTestDb();
  // 同步日志落到系统临时目录：测试里没有 path_provider 平台通道。
  // 每个测试文件是独立进程：路径带 pid，避免并行跑时互相踩日志文件。
  SyncLogStore.overridePath = File(
    '${Directory.systemTemp.path}/novel-playlet-test-sync-log-$pid.json',
  ).path;
  setUp(() async {
    // 每个用例都从空 prefs 开始：同步元数据（revision / ETag）不跨用例泄漏。
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await resetLibraryTestDb();
    final log = File(SyncLogStore.overridePath!);
    if (await log.exists()) await log.delete();
  });
  await testMain();
}

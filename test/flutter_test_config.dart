import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/library_test_db.dart';

/// 全局测试引导（`flutter test` 会先跑这里再跑各文件的 `main`）。
///
/// 1. sqflite 切成桌面 FFI + 内存库；
/// 2. 准备一个空的 prefs mock（`LibraryDb` 首次开库会读它做一次性迁移，
///    没有 mock 会抛 `MissingPluginException`）；
/// 3. 每个用例前重置内存库，替代旧的 `setMockInitialValues` 语义。
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues(<String, Object>{});
  setupLibraryTestDb();
  setUp(resetLibraryTestDb);
  await testMain();
}

import 'package:novel_playlet/core/storage/library_db.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 把 sqflite 切到桌面 FFI + 内存库，供 `flutter test` 使用。
///
/// 生产走 `sqflite` 原生实现；测试里没有平台通道，必须换成
/// `sqflite_common_ffi`，否则第一次开库就会 `MissingPluginException`。
/// 入口在 `test/flutter_test_config.dart`，所有用例自动生效。
///
/// 必须用 `databaseFactoryFfiNoIsolate`：默认的 `databaseFactoryFfi` 把库
/// 跑在独立 isolate 里，而 `testWidgets` 的 FakeAsync 不会驱动真实事件循环，
/// 页面里 `await store.xxx()` 永远不返回，`pumpAndSettle` 会一直转圈到超时。
void setupLibraryTestDb() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfiNoIsolate;
  LibraryDb.overridePath = inMemoryDatabasePath;
}

/// 重置内存库：`inMemoryDatabasePath` 关掉即销毁，下次 open 是全新的空库。
///
/// 等价于 shared_preferences 时代的 `setMockInitialValues({})`。
Future<void> resetLibraryTestDb() => LibraryDb.close();

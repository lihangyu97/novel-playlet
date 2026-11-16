import 'package:novel_playlet/core/storage/library_db.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 把 sqflite 切到桌面 FFI + 内存库，供 `flutter test` 使用。
///
/// 生产走 `sqflite` 原生实现；测试里没有平台通道，必须换成
/// `sqflite_common_ffi`，否则第一次开库就会 `MissingPluginException`。
/// 入口在 `test/flutter_test_config.dart`，所有用例自动生效。
void setupLibraryTestDb() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  LibraryDb.overridePath = inMemoryDatabasePath;
}

/// 重置内存库：`inMemoryDatabasePath` 关掉即销毁，下次 open 是全新的空库。
///
/// 等价于 shared_preferences 时代的 `setMockInitialValues({})`。
Future<void> resetLibraryTestDb() => LibraryDb.close();

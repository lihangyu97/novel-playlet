import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart';

import '../../src/rust/frb_generated.dart';

/// 初始化 flutter_rust_bridge 运行时（原生平台）。
///
/// iOS / macOS 上 Rust 核心都以**静态库**形式整体链进 App 主二进制（见
/// `ios/Flutter/*.xcconfig`、`macos/Runner/Configs/*.xcconfig` 里的
/// `-force_load`），没有可 `DynamicLibrary.open()` 的文件，必须走
/// `ExternalLibrary.process()` 从进程自身导出符号里查 Rust 入口。
///
/// 只有 host 测试（`flutter test`）才按文件名加载 dylib：那些用例自己调
/// `RustLib.init(externalLibrary: ExternalLibrary.open(...))`，不经过这里。
Future<void> initRustRuntime() {
  if (Platform.isIOS || Platform.isMacOS) {
    return RustLib.init(
      externalLibrary: ExternalLibrary.process(iKnowHowToUseIt: true),
    );
  }
  return RustLib.init();
}

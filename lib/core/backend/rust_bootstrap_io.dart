import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart';

import '../../src/rust/frb_generated.dart';

/// 初始化 flutter_rust_bridge 运行时（原生平台）。
///
/// iOS 上 Rust 核心以**静态库**形式整体链进 App 主二进制（iOS 不允许从包内
/// dlopen 共享库，见 `ios/Flutter/*.xcconfig` 里的 `-force_load`），没有可
/// `DynamicLibrary.open()` 的文件，必须走 `ExternalLibrary.process()` 从进程
/// 自身导出符号里查 Rust 入口。
///
/// macOS 只用于 host 测试：`flutter test` 下 FRB 默认按文件名加载
/// `rust/target/debug/libfqapi_core.dylib`，与测试里的 `ExternalLibrary.open`
/// 是同一份产物。
Future<void> initRustRuntime() {
  if (Platform.isIOS) {
    return RustLib.init(
      externalLibrary: ExternalLibrary.process(iKnowHowToUseIt: true),
    );
  }
  return RustLib.init();
}

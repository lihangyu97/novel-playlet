import '../../src/rust/frb_generated.dart';

/// 初始化 flutter_rust_bridge 运行时（Web 平台，无原生库）。
///
/// 当前只发 iOS，保留该入口是为了让调用方不必做平台分支。
Future<void> initRustRuntime() => RustLib.init();

// 平台相关的 Rust 运行时初始化入口。
//
// 原生平台（含 iOS）用 rust_bootstrap_io.dart，Web 用 rust_bootstrap_stub.dart。
library;

export 'rust_bootstrap_stub.dart' if (dart.library.io) 'rust_bootstrap_io.dart';

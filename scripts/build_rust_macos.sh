#!/usr/bin/env bash
# 编译 Rust 核心（fqapi_core）的 macOS universal 静态库并放进 macos/Frameworks/。
#
# 为什么和 iOS 一样用静态库：整库 `-force_load` 链进 Runner 主二进制后，
# flutter_rust_bridge 走 `ExternalLibrary.process()` 从进程自身符号里找入口，
# 不用管 dylib 的 @rpath / 签名 / 沙盒里 dyld 的查找路径（见
# lib/core/backend/rust_bootstrap_io.dart）。
#
# 两个架构各编一次再 lipo 合并：Apple Silicon 出 arm64，Intel Mac 出 x86_64，
# 合并后同一个 .app 两边都能跑。
#
# 用法：
#   ./scripts/build_rust_macos.sh     # 编 universal（arm64 + x86_64）
#
# 约定：codegen 与编译本机版本钉死（flutter_rust_bridge 两端同为 2.13.0），
# 缺依赖就硬错，不静默降级。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(dirname "$SCRIPT_DIR")"
MANIFEST="$APP_DIR/rust/Cargo.toml"
OUT_DIR="$APP_DIR/macos/Frameworks"

if ! command -v cargo >/dev/null 2>&1; then
  echo "错误：未找到 cargo，请先安装 Rust 工具链。" >&2
  exit 1
fi
if [ ! -f "$MANIFEST" ]; then
  echo "错误：找不到 Rust 清单 $MANIFEST" >&2
  exit 1
fi
if ! command -v flutter_rust_bridge_codegen >/dev/null 2>&1; then
  echo "错误：未找到 flutter_rust_bridge_codegen（需与 Cargo.toml 同版本：cargo install flutter_rust_bridge_codegen --version 2.13.0）。" >&2
  exit 1
fi

# 绑定必须先于内核产物刷新：`rust/src/api/*` 的函数签名变了却没重新生成，
# Dart 侧要到编译期（甚至运行期）才会炸。这里把 codegen 钉进构建流程，
# 保证入库的 lib/src/rust 与 rust/src/frb_generated.rs 永远跟当前 api 一致。
echo "==> flutter_rust_bridge_codegen generate"
( cd "$APP_DIR" && flutter_rust_bridge_codegen generate --config-file flutter_rust_bridge.yaml )

# release profile 里 `strip = true` 会把符号表一起裁掉，静态库链接会因此找不到导出符号。
# 产物统一用 debuginfo 级别：只去调试信息，保留符号。
export CARGO_PROFILE_RELEASE_STRIP=debuginfo

build_target() {
  local target="$1"
  echo "==> cargo rustc --target $target (staticlib)"
  ( cd "$APP_DIR" && cargo rustc --locked --release \
      --manifest-path "$MANIFEST" \
      --target "$target" \
      --crate-type staticlib )
  local lib="$APP_DIR/rust/target/$target/release/libfqapi_core.a"
  if [ ! -s "$lib" ]; then
    echo "错误：未产出 $lib" >&2
    exit 1
  fi
  echo "    $(ls -lh "$lib" | awk '{print $5}')  $lib"
}

build_target aarch64-apple-darwin
build_target x86_64-apple-darwin

mkdir -p "$OUT_DIR"
echo "==> lipo 合并为 universal"
lipo -create \
  "$APP_DIR/rust/target/aarch64-apple-darwin/release/libfqapi_core.a" \
  "$APP_DIR/rust/target/x86_64-apple-darwin/release/libfqapi_core.a" \
  -output "$OUT_DIR/libfqapi_core.a"
echo "==> 已放置：$OUT_DIR/libfqapi_core.a"
lipo -info "$OUT_DIR/libfqapi_core.a"

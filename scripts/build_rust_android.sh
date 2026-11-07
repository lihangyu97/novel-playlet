#!/usr/bin/env bash
# 编译 Rust 内核（fqapi_core）的 Android 共享库并放进 android/app/src/main/jniLibs/。
#
# 为什么 Android 用 .so：内核 crate 已经是 cdylib，flutter_rust_bridge 在 Android 上
# 按库名从 APK 里 dlopen（libfqapi_core.so），Gradle 会把 jniLibs 打进 APK。
# iOS 则是静态库 + ExternalLibrary.process()，两条加载路径在 Dart 侧不需要分支，
# 见 lib/core/backend/rust_bootstrap_io.dart。
#
# 用法：
#   ./scripts/build_rust_android.sh                 # 只编 arm64-v8a（现代手机 / Apple Silicon 模拟器）
#   ./scripts/build_rust_android.sh --abis all      # arm64-v8a + armeabi-v7a
#   ./scripts/build_rust_android.sh --skip-codegen  # 跳过 FRB codegen（绑定已是最新时）
#
# 约定：NDK 固定 28.2.13676358（与 Flutter 3.47 的默认 ndkVersion 一致），
# 缺依赖就硬错，不静默降级。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(dirname "$SCRIPT_DIR")"
MANIFEST="$APP_DIR/rust/Cargo.toml"
PINNED_NDK_VERSION="28.2.13676358"
FRB_VERSION="2.13.0"
# 与 android/app/build.gradle.kts 的 minSdk 一致（Flutter 3.47 默认 24）。
API_LEVEL=24

SKIP_CODEGEN=0
ABIS="arm64-v8a"
usage() {
  echo "Usage: $0 [--skip-codegen] [--abis arm64-v8a|armeabi-v7a|all]" >&2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --skip-codegen) SKIP_CODEGEN=1 ;;
    --abis)
      if [ "$#" -lt 2 ]; then
        echo "错误：--abis 需要一个取值（arm64-v8a|armeabi-v7a|all）。" >&2
        usage
        exit 2
      fi
      case "$2" in
        arm64-v8a|armeabi-v7a|all) ABIS="$2" ;;
        *) echo "错误：--abis 取值无效：$2" >&2; usage; exit 2 ;;
      esac
      shift ;;
    --abis=*)
      case "${1#--abis=}" in
        arm64-v8a|armeabi-v7a|all) ABIS="${1#--abis=}" ;;
        *) echo "错误：--abis 取值无效：${1#--abis=}" >&2; usage; exit 2 ;;
      esac ;;
    -h|--help) usage; exit 0 ;;
    *) echo "错误：未知参数：$1" >&2; usage; exit 2 ;;
  esac
  shift
done

if ! command -v cargo >/dev/null 2>&1; then
  echo "错误：未找到 cargo，请先安装 Rust 工具链（本机在 ~/.cargo/bin，确认它在 PATH 里）。" >&2
  exit 1
fi
if [ ! -f "$MANIFEST" ]; then
  echo "错误：找不到 Rust 清单 $MANIFEST" >&2
  exit 1
fi

if [ "$SKIP_CODEGEN" -eq 0 ]; then
  if ! command -v flutter_rust_bridge_codegen >/dev/null 2>&1; then
    echo "错误：未找到 flutter_rust_bridge_codegen（需与 Cargo.toml 同版本：$FRB_VERSION）。" >&2
    echo "安装：cargo install flutter_rust_bridge_codegen --version $FRB_VERSION --locked" >&2
    exit 1
  fi
  actual_frb="$(flutter_rust_bridge_codegen --version | awk '{print $2}')"
  if [ "$actual_frb" != "$FRB_VERSION" ]; then
    echo "错误：flutter_rust_bridge_codegen 版本是 $actual_frb，需要 $FRB_VERSION。" >&2
    exit 1
  fi
  echo "==> flutter_rust_bridge_codegen generate"
  ( cd "$APP_DIR" && flutter_rust_bridge_codegen generate --config-file flutter_rust_bridge.yaml )
fi

# 定位 pinned NDK：优先显式环境变量，其次 Android SDK 下的 ndk/<版本>。
NDK_ROOT="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"
if [ -z "$NDK_ROOT" ]; then
  SDK_ROOT="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
  if [ -z "$SDK_ROOT" ] && [ -f "$APP_DIR/android/local.properties" ]; then
    SDK_ROOT="$(sed -n 's/^sdk\.dir=//p' "$APP_DIR/android/local.properties" | head -n 1)"
  fi
  if [ -n "$SDK_ROOT" ]; then
    NDK_ROOT="$SDK_ROOT/ndk/$PINNED_NDK_VERSION"
  fi
fi
if [ -z "$NDK_ROOT" ] || [ ! -d "$NDK_ROOT" ]; then
  echo "错误：找不到 Android NDK $PINNED_NDK_VERSION。" >&2
  echo "安装：sdkmanager \"ndk;$PINNED_NDK_VERSION\"，或设置 ANDROID_NDK_HOME 指向它。" >&2
  exit 1
fi
if [ "$(basename "$NDK_ROOT")" != "$PINNED_NDK_VERSION" ]; then
  echo "错误：解析到的 NDK 不是 pinned 版本 $PINNED_NDK_VERSION（解析到 $NDK_ROOT）。" >&2
  exit 1
fi
echo "==> NDK: $NDK_ROOT"

case "$(uname -s)" in
  Darwin) HOST_TAG="darwin-x86_64" ;;
  Linux)  HOST_TAG="linux-x86_64" ;;
  MINGW*|MSYS*|CYGWIN*) HOST_TAG="windows-x86_64" ;;
  *) echo "错误：不支持当前 NDK 主机平台。" >&2; exit 1 ;;
esac
TOOLCHAIN="$NDK_ROOT/toolchains/llvm/prebuilt/$HOST_TAG/bin"
if [ ! -d "$TOOLCHAIN" ]; then
  echo "错误：NDK 里找不到主机工具链 $TOOLCHAIN。" >&2
  exit 1
fi

build_android_target() {
  local rust_target="$1" clang_triple="$2" abi="$3"
  local cc_path="$TOOLCHAIN/${clang_triple}${API_LEVEL}-clang"
  if [ "$HOST_TAG" = "windows-x86_64" ] && [ -f "$cc_path.cmd" ]; then
    cc_path="$cc_path.cmd"
  fi
  if [ ! -f "$cc_path" ]; then
    echo "错误：在 $TOOLCHAIN 下找不到 $(basename "$cc_path")。" >&2
    exit 1
  fi

  # cc-rs 按 <target 里的 - 换成 _> 查环境变量；Cargo 的 linker 变量用全大写。
  export "CC_${rust_target//-/_}=$cc_path"
  export "AR_${rust_target//-/_}=$TOOLCHAIN/llvm-ar"
  export "RANLIB_${rust_target//-/_}=$TOOLCHAIN/llvm-ranlib"
  local linker_var
  linker_var="$(printf 'CARGO_TARGET_%s_LINKER' "${rust_target//-/_}" | tr 'a-z' 'A-Z')"
  export "$linker_var=$cc_path"

  # 现代 Android 要求 ELF LOAD 段按 16 KiB 对齐（Android 15+ / Play 上架），
  # arm64 显式补上；armv7 不涉及 16 KiB 页。
  local rustflags=""
  if [ "$abi" = "arm64-v8a" ]; then
    rustflags="-C link-arg=-Wl,-z,max-page-size=16384"
  fi

  local jni_dir="$APP_DIR/android/app/src/main/jniLibs/$abi"
  mkdir -p "$jni_dir"

  echo "==> cargo build --release --target $rust_target"
  if [ -n "$rustflags" ]; then
    ( cd "$APP_DIR" && RUSTFLAGS="$rustflags" cargo build --locked --manifest-path "$MANIFEST" --target "$rust_target" --release )
  else
    ( cd "$APP_DIR" && cargo build --locked --manifest-path "$MANIFEST" --target "$rust_target" --release )
  fi

  local built_so="$APP_DIR/rust/target/$rust_target/release/libfqapi_core.so"
  if [ ! -s "$built_so" ]; then
    echo "错误：Rust 交叉编译未产出 $built_so" >&2
    exit 1
  fi
  cp -f "$built_so" "$jni_dir/libfqapi_core.so"
  echo "==> jniLibs: $jni_dir/libfqapi_core.so"

  # flutter_rust_bridge 靠这两个动态符号找到入口；strip 后必须仍在。
  local symbols
  symbols="$("$TOOLCHAIN/llvm-nm" --dynamic --defined-only "$jni_dir/libfqapi_core.so")"
  for symbol in store_dart_post_cobject frb_get_rust_content_hash; do
    if ! printf '%s\n' "$symbols" | grep -Eq "[[:space:]]${symbol}$"; then
      echo "错误：$abi 的 libfqapi_core.so 缺少 FRB 入口符号：$symbol" >&2
      exit 1
    fi
  done

  # 16 KiB 对齐自检：只报告，不因为 NDK/链接器行为差异把首次构建卡死。
  local loads
  loads="$("$TOOLCHAIN/llvm-readelf" -l "$jni_dir/libfqapi_core.so" | grep '^  LOAD' || true)"
  echo "    ELF LOAD 对齐："
  printf '%s\n' "$loads" | sed 's/^/      /'
  if printf '%s\n' "$loads" | grep -qv '0x4000\|0x10000'; then
    if [ "$abi" = "arm64-v8a" ]; then
      echo "    警告：存在 LOAD 段对齐 < 16 KiB，Android 15+ 的 16 KiB 页设备可能装不上/跑不起来。" >&2
    fi
  fi
}

if [ "$ABIS" = "all" ]; then
  build_android_target aarch64-linux-android aarch64-linux-android arm64-v8a
  build_android_target armv7-linux-androideabi armv7a-linux-androideabi armeabi-v7a
else
  case "$ABIS" in
    arm64-v8a) build_android_target aarch64-linux-android aarch64-linux-android arm64-v8a ;;
    armeabi-v7a) build_android_target armv7-linux-androideabi armv7a-linux-androideabi armeabi-v7a ;;
  esac
fi

echo "==> 完成。打包命令：flutter build apk --release --target-platform android-arm64"

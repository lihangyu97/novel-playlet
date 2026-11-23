#!/usr/bin/env bash
# 构建 Android 双版本（release / beta）的 release APK。
#
# 为什么双版本：和 iOS 同一个理由（见 scripts/build_ios_app.sh 顶部）——beta 包用
# 独立 applicationId 与显示名，两个包能同时装在一台机器上，数据容器互不覆盖；
# 日常开发只覆盖 beta，正式包的书架/离线/进度不会被误覆盖带走。
#
#   release : com.lihangyu.novel_playlet      「摆烂盒子」      端口读 config.json（18931）
#   beta    : com.lihangyu.novel_playlet.beta 「摆烂盒子 Beta」 端口 --dart-define=BACKEND_PORT=18932
#
# 用法:
#   ./scripts/build_android_app.sh --flavor release          # 建议在 main 上跑
#   ./scripts/build_android_app.sh --flavor beta             # 开发分支的包
#   ./scripts/build_android_app.sh --flavor beta --skip-rust # 内核 .so 已构建过
#   ./scripts/build_android_app.sh --flavor release --abis all
#   ./scripts/build_android_app.sh --flavor release --out /tmp/apk
#
# 产物：output/apk/novel_playlet_<flavor>_<git短哈希>.apk（output/ 已 git 忽略）
# Gradle 里的渠道名是 prod / beta（release 与 build type 重名，Gradle 不允许），
# 脚本对外仍叫 --flavor release，内部映射到 prod。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(dirname "$SCRIPT_DIR")"
# 产物统一落在仓库根的 output/（已 git 忽略），构建中间物仍留在 Flutter 的 build/。
OUT_DIR="$APP_DIR/output/apk"
FLAVOR=""
SKIP_RUST=0
ABIS="arm64-v8a"

usage() { awk 'NR > 1 && /^set -euo/{exit} NR > 1{print}' "$0"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --flavor)    FLAVOR="${2:-}"; shift 2 ;;
    --skip-rust) SKIP_RUST=1; shift ;;
    --out)       OUT_DIR="${2:-}"; shift 2 ;;
    --abis)
      if [[ $# -lt 2 ]]; then
        echo "错误：--abis 需要一个取值（arm64-v8a|armeabi-v7a|all）。" >&2
        usage >&2
        exit 2
      fi
      case "$2" in
        arm64-v8a|armeabi-v7a|all) ABIS="$2" ;;
        *) echo "错误：--abis 取值无效：$2" >&2; usage >&2; exit 2 ;;
      esac
      shift 2 ;;
    --abis=*)
      case "${1#--abis=}" in
        arm64-v8a|armeabi-v7a|all) ABIS="${1#--abis=}" ;;
        *) echo "错误：--abis 取值无效：${1#--abis=}" >&2; usage >&2; exit 2 ;;
      esac
      shift ;;
    -h|--help)   usage; exit 0 ;;
    *) echo "错误：未知参数：$1" >&2; exit 2 ;;
  esac
done

case "$FLAVOR" in
  release)
    GRADLE_FLAVOR="prod"
    APP_ID="com.lihangyu.novel_playlet"
    DISPLAY_NAME="摆烂盒子"
    PORT="" # 读 config.json
    ;;
  beta)
    GRADLE_FLAVOR="beta"
    APP_ID="com.lihangyu.novel_playlet.beta"
    DISPLAY_NAME="摆烂盒子 Beta"
    PORT="18932"
    ;;
  "")
    echo "错误：必须指定 --flavor release|beta" >&2
    exit 2
    ;;
  *)
    echo "错误：未知 flavor：${FLAVOR}（只支持 release / beta）" >&2
    exit 2
    ;;
esac

case "$ABIS" in
  arm64-v8a)   TARGET_PLATFORMS="android-arm64" ;;
  armeabi-v7a) TARGET_PLATFORMS="android-arm" ;;
  all)         TARGET_PLATFORMS="android-arm,android-arm64" ;;
esac

command -v flutter >/dev/null 2>&1 || { echo "错误：未找到 flutter。" >&2; exit 1; }

BRANCH="$(git -C "$APP_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
SHA="$(git -C "$APP_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
VERSION="$(sed -n 's/^version:[[:space:]]*//p' "$APP_DIR/pubspec.yaml" | head -n 1)"
if [[ "$FLAVOR" == "release" && "$BRANCH" != "main" ]]; then
  echo "提示：release 建议从 main 构建（当前分支 ${BRANCH}）；开发分支的产物请用 --flavor beta。" >&2
fi
if [[ "$FLAVOR" == "beta" && "$BRANCH" == "main" ]]; then
  echo "提示：beta 通常从开发分支构建（当前是 main），两个版本会暂时同源。" >&2
fi

if (( SKIP_RUST == 0 )); then
  echo "==> 构建 Rust 内核 .so（abis=${ABIS}）"
  "$SCRIPT_DIR/build_rust_android.sh" --abis "$ABIS"
fi

echo "==> flutter build apk --release --flavor ${GRADLE_FLAVOR} --target-platform ${TARGET_PLATFORMS}（flavor=${FLAVOR}）"
# macOS 自带 bash 3.2 在 `set -u` 下展开空数组会报 unbound variable，
# 所以按 flavor 分两条命令，而不是拼 DART_ARGS 数组。
if [[ -n "$PORT" ]]; then
  ( cd "$APP_DIR" && flutter build apk --release --flavor "$GRADLE_FLAVOR" --target-platform "$TARGET_PLATFORMS" --dart-define="BACKEND_PORT=$PORT" --dart-define=APP_FLAVOR=beta )
else
  ( cd "$APP_DIR" && flutter build apk --release --flavor "$GRADLE_FLAVOR" --target-platform "$TARGET_PLATFORMS" )
fi

# 带 flavor 后产物名是 app-<flavor>-release.apk（不再是 app-release.apk）。
APK="$APP_DIR/build/app/outputs/flutter-apk/app-${GRADLE_FLAVOR}-release.apk"
if [[ ! -f "$APK" ]]; then
  echo "错误：没有找到构建产物 $APK" >&2
  echo "      当前 flutter-apk 目录内容：" >&2
  ls -1 "$APP_DIR/build/app/outputs/flutter-apk" >&2 2>/dev/null || echo "      （目录不存在）" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
DEST="$OUT_DIR/novel_playlet_${FLAVOR}_${SHA}.apk"
cp -f "$APK" "$DEST"

echo ""
echo "==> 完成"
echo "    APK       : $DEST"
echo "    大小      : $(du -h "$DEST" | awk '{print $1}')"
echo "    sha256    : $(shasum -a 256 "$DEST" | awk '{print $1}')"
echo "    package   : $APP_ID"
echo "    显示名    : $DISPLAY_NAME"
echo "    版本      : ${VERSION:-未知}"
echo "    后端端口  : ${PORT:-config.json（18931）}"
echo "    来源分支  : $BRANCH @ $SHA"
echo ""
echo "下一步（adb 安装，覆盖安装是升级、保留数据）："
echo "  adb install -r \"$DEST\""
if [[ "$FLAVOR" == "beta" ]]; then
  echo ""
  echo "  beta 与正式包 applicationId 不同，可以同时安装；卸载只影响 beta 自己的数据："
  echo "  adb uninstall $APP_ID"
fi

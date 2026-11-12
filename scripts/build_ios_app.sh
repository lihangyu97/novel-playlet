#!/usr/bin/env bash
# 构建 iOS 双版本（release / beta）的未签名 IPA。
#
# 为什么要双版本：开发分支的包如果覆盖正式包（同一个 bundle id），出问题要
# 卸载重装时会连 App 数据（书架/离线/进度）一起丢。拆成两个 App ID 后两个
# App 可以同时装在手机上，数据容器/keychain 天然隔离，日常开发只覆盖 beta。
#
#   release : com.lihangyu.novelPlaylet      「摆烂盒子」      端口读 config.json（18931）
#   beta    : com.lihangyu.novelPlaylet.beta 「摆烂盒子 Beta」 端口 --dart-define=BACKEND_PORT=18932
#
# 用法:
#   ./scripts/build_ios_app.sh --flavor release   # 建议在 main 上跑
#   ./scripts/build_ios_app.sh --flavor beta      # 开发分支的包
#   ./scripts/build_ios_app.sh --flavor beta --skip-rust   # 内核静态库已构建过
#   ./scripts/build_ios_app.sh --flavor release --out /tmp/ipa
#
# 产物：build/ios/ipa/novel_playlet_<flavor>_<git短哈希>_unsigned.ipa
# 签名/安装走 ios-sideload（bundle id 要与构建时一致），见 docs/implementation.md §7.2。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(dirname "$SCRIPT_DIR")"
OUT_DIR="$APP_DIR/build/ios/ipa"
FLAVOR=""
SKIP_RUST=0

usage() { sed -n '2,22p' "$0"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --flavor)    FLAVOR="${2:-}"; shift 2 ;;
    --skip-rust) SKIP_RUST=1; shift ;;
    --out)       OUT_DIR="${2:-}"; shift 2 ;;
    -h|--help)   usage; exit 0 ;;
    *) echo "错误：未知参数：$1" >&2; exit 2 ;;
  esac
done

case "$FLAVOR" in
  release)
    BUNDLE_ID="com.lihangyu.novelPlaylet"
    DISPLAY_NAME="摆烂盒子"
    PORT="" # 读 config.json
    ;;
  beta)
    BUNDLE_ID="com.lihangyu.novelPlaylet.beta"
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

command -v flutter >/dev/null 2>&1 || { echo "错误：未找到 flutter。" >&2; exit 1; }
command -v xcrun >/dev/null 2>&1 || { echo "错误：未找到 xcrun（需要完整 Xcode）。" >&2; exit 1; }

BRANCH="$(git -C "$APP_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
SHA="$(git -C "$APP_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
if [[ "$FLAVOR" == "release" && "$BRANCH" != "main" ]]; then
  echo "提示：release 建议从 main 构建（当前分支 ${BRANCH}）；开发分支的产物请用 --flavor beta。" >&2
fi
if [[ "$FLAVOR" == "beta" && "$BRANCH" == "main" ]]; then
  echo "提示：beta 通常从开发分支构建（当前是 main），两个版本会暂时同源。" >&2
fi

if (( SKIP_RUST == 0 )); then
  echo "==> 构建 Rust 内核静态库"
  "$SCRIPT_DIR/build_rust_ios.sh"
fi

echo "==> flutter build ios --release --no-codesign（flavor=${FLAVOR}）"
# macOS 自带 bash 3.2 在 `set -u` 下展开空数组会报 unbound variable，
# 所以按 flavor 分两条命令，而不是拼 DART_ARGS 数组。
if [[ -n "$PORT" ]]; then
  ( cd "$APP_DIR" && flutter build ios --release --no-codesign --dart-define="BACKEND_PORT=$PORT" )
else
  ( cd "$APP_DIR" && flutter build ios --release --no-codesign )
fi

APP="$APP_DIR/build/ios/iphoneos/Runner.app"
if [[ ! -d "$APP" ]]; then
  echo "错误：没有找到构建产物 $APP" >&2
  exit 1
fi

# 未签名包直接改 Info.plist 的 bundle id/显示名：随后 ios-sideload 会按
# 目标 bundle id 重签名，两个 App 才能共存（数据隔离由 bundle id 决定）。
mkdir -p "$OUT_DIR"
STAGE="$OUT_DIR/.stage-$FLAVOR"
rm -rf "$STAGE"
mkdir -p "$STAGE/Payload"
cp -R "$APP" "$STAGE/Payload/Runner.app"
TARGET_APP="$STAGE/Payload/Runner.app"
PB=/usr/libexec/PlistBuddy
"$PB" -c "Set :CFBundleIdentifier $BUNDLE_ID" "$TARGET_APP/Info.plist"
"$PB" -c "Set :CFBundleDisplayName $DISPLAY_NAME" "$TARGET_APP/Info.plist"
if [[ "$FLAVOR" == "beta" ]]; then
  # 系统内部名也带后缀：便于 Devicectl/日志区分两个进程。
  "$PB" -c "Set :CFBundleName novel_playlet_beta" "$TARGET_APP/Info.plist"
fi

IPA="$OUT_DIR/novel_playlet_${FLAVOR}_${SHA}_unsigned.ipa"
rm -f "$IPA"
( cd "$STAGE" && zip -qry "$IPA" Payload )
rm -rf "$STAGE"

echo ""
echo "==> 完成"
echo "    IPA       : $IPA"
echo "    bundle id : $BUNDLE_ID"
echo "    显示名    : $DISPLAY_NAME"
echo "    后端端口  : ${PORT:-config.json（18931）}"
echo "    来源分支  : $BRANCH @ $SHA"
echo ""
echo "下一步（自签安装）："
echo "  cd ~/workspace/ios-sideload"
echo "  BUNDLE_ID=$BUNDLE_ID ./profile.sh --mint   # 首次/描述文件过期或 App ID 不匹配时"
echo "  ./sign.sh -i \"$IPA\" -b $BUNDLE_ID"
echo "  ./install.sh -d <iPhone 名称或 UDID>"

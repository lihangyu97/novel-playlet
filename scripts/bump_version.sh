#!/usr/bin/env bash
# 递增版本号（发 release 用）：`pubspec.yaml` 的 `version: X.Y.Z+N` 是唯一来源。
#
# 规则（从 1.0.0 起）：
#   - release 只从 main 构建；每次发版版本名 patch +1（1.0.0 → 1.0.1 → 1.0.2 …）
#   - 构建号 +N 每次都 +1（覆盖安装 / App Store 都要求它递增）
#   - beta / 开发包不单独改版本，沿用当前 pubspec
#
# 用法:
#   ./scripts/bump_version.sh             # 1.0.0+15 → 1.0.1+16（默认 patch）
#   ./scripts/bump_version.sh --dry-run   # 只打印，不改文件
#   ./scripts/bump_version.sh --minor     # 需要时手动抬中版本：1.0.1 → 1.1.0
#   ./scripts/bump_version.sh --major     # 需要时手动抬大版本：1.1.0 → 2.0.0
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(dirname "$SCRIPT_DIR")"
PUBSPEC="$APP_DIR/pubspec.yaml"
MODE="patch"
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --patch)   MODE="patch"; shift ;;
    --minor)   MODE="minor"; shift ;;
    --major)   MODE="major"; shift ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "错误：未知参数：$1" >&2; exit 2 ;;
  esac
done

[[ -f "$PUBSPEC" ]] || { echo "错误：找不到 $PUBSPEC" >&2; exit 1; }

CURRENT="$(awk '/^version:/{print $2; exit}' "$PUBSPEC")"
[[ -n "$CURRENT" ]] || { echo "错误：pubspec.yaml 里没有 version:" >&2; exit 1; }
[[ "$CURRENT" == *+* ]] || { echo "错误：version 需要带构建号（形如 1.0.0+15）：$CURRENT" >&2; exit 1; }

NAME="${CURRENT%%+*}"
BUILD="${CURRENT##*+}"
IFS=. read -r MAJOR MINOR PATCH <<< "$NAME"
if ! [[ "$MAJOR" =~ ^[0-9]+$ && "$MINOR" =~ ^[0-9]+$ && "$PATCH" =~ ^[0-9]+$ && "$BUILD" =~ ^[0-9]+$ ]]; then
  echo "错误：version 不是 x.y.z+n 形式：$CURRENT" >&2
  exit 1
fi

case "$MODE" in
  patch) PATCH=$((PATCH + 1)) ;;
  minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
  major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
esac
NEW_NAME="$MAJOR.$MINOR.$PATCH"
NEW_BUILD=$((BUILD + 1))
NEW="$NEW_NAME+$NEW_BUILD"

echo "$CURRENT → $NEW"
if (( DRY_RUN == 1 )); then
  echo "（--dry-run，未修改文件）"
  exit 0
fi

sed -i '' "s/^version: .*/version: $NEW/" "$PUBSPEC"
echo "已更新 $PUBSPEC"
echo "提醒：release 只从 main 构建；beta/开发包不需要单独改版本。"

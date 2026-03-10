#!/usr/bin/env bash
# release.sh — GitHub Release 发布 + 完整性验证
# 用法: ./release.sh [version]
# 示例: ./release.sh v2.1.3
# Copyright (c) 2026 urDAO Investment

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# ─── 颜色输出 ────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[✅]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[❌]${NC} $*"; exit 1; }

# ─── 版本号 ──────────────────────────────────────────────────────────────────
VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    # 从 Info.plist 读取版本号
    VERSION="v$(grep -A1 CFBundleShortVersionString Info.plist | grep string | sed 's/.*<string>//' | sed 's/<\/string>.*//')"
fi
# 确保有 v 前缀
[[ "$VERSION" == v* ]] || VERSION="v$VERSION"

DMG_NAME="VoiceInput-${VERSION}-macos-arm64.dmg"
DMG_PATH="dist/$DMG_NAME"

echo "============================================"
echo "  VoiceInput Release — $VERSION"
echo "============================================"
echo ""

# ─── 步骤 1: 验证 DMG 存在 ──────────────────────────────────────────────────
info "步骤 1/5: 验证本地 DMG..."
[ -f "$DMG_PATH" ] || error "DMG 不存在: $DMG_PATH（先运行 build_app.sh）"

LOCAL_SIZE=$(stat -f%z "$DMG_PATH" 2>/dev/null || stat --printf='%s' "$DMG_PATH")
LOCAL_SIZE_MB=$((LOCAL_SIZE / 1024 / 1024))

if [ "$LOCAL_SIZE" -lt 50000000 ]; then
    error "DMG 太小 (${LOCAL_SIZE_MB}MB)，可能构建失败"
fi
success "DMG 验证通过: $DMG_PATH (${LOCAL_SIZE_MB}MB)"

# ─── 步骤 2: Git tag ────────────────────────────────────────────────────────
info "步骤 2/5: 检查 Git tag..."
if git rev-parse "$VERSION" >/dev/null 2>&1; then
    info "Tag $VERSION 已存在，跳过创建"
else
    git tag "$VERSION"
    git push origin "$VERSION"
    success "Tag $VERSION 已创建并推送"
fi

# ─── 步骤 3: 创建 Release（不带文件）───────────────────────────────────────
info "步骤 3/5: 创建 GitHub Release..."

# 删除旧 release（如果存在）
if gh release view "$VERSION" >/dev/null 2>&1; then
    warn "Release $VERSION 已存在，删除重建..."
    gh release delete "$VERSION" --yes 2>/dev/null || true
fi

# 生成 changelog（最近 tag 到当前的 commit messages）
PREV_TAG=$(git tag --sort=-version:refname | grep -v "^${VERSION}$" | head -1)
if [ -n "$PREV_TAG" ]; then
    CHANGELOG=$(git log --oneline "${PREV_TAG}..${VERSION}" 2>/dev/null | head -20 || echo "")
else
    CHANGELOG=""
fi

gh release create "$VERSION" \
    --title "$VERSION" \
    --notes "## Changes

${CHANGELOG:-No changelog available.}

---
**安装**: 下载 DMG → 拖入 Applications → 首次运行 \`sudo xattr -r -d com.apple.quarantine /Applications/VoiceInput.app\`" \
    --latest

success "Release $VERSION 创建完成"

# ─── 步骤 4: 单独上传 DMG（用 curl 直传，避免 gh cli 截断 bug）──────────
info "步骤 4/5: 上传 DMG 到 Release..."
info "  本地大小: ${LOCAL_SIZE_MB}MB (${LOCAL_SIZE} bytes)"

RELEASE_ID=$(gh api "repos/dennyandwu/VoiceInput/releases/tags/$VERSION" --jq '.id')
TOKEN=$(gh auth token)

HTTP_CODE=$(curl --retry 3 --retry-delay 5 \
    -X POST \
    -H "Authorization: token $TOKEN" \
    -H "Content-Type: application/octet-stream" \
    -H "Content-Length: $LOCAL_SIZE" \
    --data-binary @"$DMG_PATH" \
    "https://uploads.github.com/repos/dennyandwu/VoiceInput/releases/$RELEASE_ID/assets?name=$DMG_NAME" \
    -o /tmp/release_upload_result.json -w "%{http_code}" 2>/dev/null)

if [ "$HTTP_CODE" != "201" ]; then
    cat /tmp/release_upload_result.json 2>/dev/null
    error "上传失败 (HTTP $HTTP_CODE)"
fi

success "DMG 上传完成 (HTTP $HTTP_CODE)"

# ─── 步骤 5: 验证上传完整性 ─────────────────────────────────────────────────
info "步骤 5/5: 验证 GitHub Release 完整性..."
info "  等待 GitHub 处理（15s）..."
sleep 15

# 用 gh api 直接查（避免 gh release view 缓存）
REMOTE_SIZE=$(gh api "repos/dennyandwu/VoiceInput/releases/tags/$VERSION" --jq '.assets[0].size' 2>/dev/null || echo "0")
REMOTE_SIZE_MB=$((REMOTE_SIZE / 1024 / 1024))

echo ""
echo "  本地 DMG:  ${LOCAL_SIZE_MB}MB (${LOCAL_SIZE} bytes)"
echo "  远端 Asset: ${REMOTE_SIZE_MB}MB (${REMOTE_SIZE} bytes)"
echo ""

# 允许 1% 误差（GitHub API 报告的大小可能有微小差异）
DIFF=$((LOCAL_SIZE - REMOTE_SIZE))
DIFF=${DIFF#-}  # 取绝对值
THRESHOLD=$((LOCAL_SIZE / 100))  # 1%

if [ "$DIFF" -gt "$THRESHOLD" ]; then
    error "❌ 大小不匹配！本地 ${LOCAL_SIZE} vs 远端 ${REMOTE_SIZE}（差异 ${DIFF} bytes）
    请手动删除 Release 并重试:
      gh release delete $VERSION --yes
      ./release.sh $VERSION"
fi

success "完整性验证通过 ✅"
echo ""

# ─── 同步到 HTTP 服务器 ─────────────────────────────────────────────────────
if [ -d "/tmp/openclaw/uploads" ]; then
    cp "$DMG_PATH" "/tmp/openclaw/uploads/"
    info "已同步到 LAN HTTP: http://100.71.176.10:9998/$DMG_NAME"
fi

echo "============================================"
echo -e "${GREEN}  🎉 Release $VERSION 发布完成！${NC}"
echo "============================================"
echo ""
echo "GitHub: https://github.com/dennyandwu/VoiceInput/releases/tag/$VERSION"
echo "LAN:    http://100.71.176.10:9998/$DMG_NAME"
echo ""

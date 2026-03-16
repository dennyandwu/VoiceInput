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

# ─── 步骤 0: 发布流水线检查（PMO 门禁）──────────────────────────────────────
PIPELINE_FILE="/Users/0xfg_bot/.openclaw/workspace/release-pipeline.json"
SKIP_PIPELINE="${SKIP_PIPELINE:-false}"

if [ "$SKIP_PIPELINE" != "true" ]; then
    info "步骤 0/6: 检查发布流水线状态..."
    if [ -f "$PIPELINE_FILE" ]; then
        # 检查该版本是否在 pipeline 中且审核通过
        PIPELINE_STATUS=$(python3 -c "
import json, sys
with open('$PIPELINE_FILE') as f:
    data = json.load(f)
for p in data.get('pipelines', []):
    if p.get('version') == '$VERSION':
        review = p.get('reviewResult', 'NONE')
        test = p.get('testResult', 'NONE')
        status = p.get('status', 'unknown')
        if review in ('PASSED', 'CONDITIONAL_PASS') and test in ('PASSED', 'CONDITIONAL_PASS', 'PENDING'):
            print('APPROVED')
        elif status == 'released':
            print('ALREADY_RELEASED')
        else:
            print(f'BLOCKED:{review}/{test}')
        sys.exit(0)
print('NOT_REGISTERED')
" 2>/dev/null || echo "CHECK_FAILED")

        case "$PIPELINE_STATUS" in
            APPROVED)
                success "流水线已审核通过，继续发布"
                ;;
            ALREADY_RELEASED)
                warn "$VERSION 已发布过，跳过流水线检查"
                ;;
            BLOCKED:*)
                error "❌ 发布被阻止！审核状态: ${PIPELINE_STATUS#BLOCKED:}

请先提交 RELEASE REQUEST 到 Discord #开发中心，等待 PMO 审核通过后再发布。
格式：
📦 RELEASE REQUEST: VoiceInput $VERSION
PR: [链接]
变更: [简述]
DMG: $(pwd)/$DMG_PATH"
                ;;
            NOT_REGISTERED)
                error "❌ 版本 $VERSION 未在发布流水线中登记！

请先提交 RELEASE REQUEST 到 Discord #开发中心，等待 PMO 登记后再发布。
格式：
📦 RELEASE REQUEST: VoiceInput $VERSION
PR: [链接]
变更: [简述]
DMG: $(pwd)/$DMG_PATH"
                ;;
            *)
                warn "流水线检查异常，继续发布（需人工确认）"
                ;;
        esac
    else
        warn "流水线文件不存在，跳过检查"
    fi
else
    warn "SKIP_PIPELINE=true，跳过流水线检查（仅限 PMO/紧急 Hotfix）"
fi

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

# ─── 步骤 4: 单独上传 DMG（curl 直传 + 重试 + 同名资产清理）──────────────
info "步骤 4/5: 上传 DMG 到 Release..."
info "  本地大小: ${LOCAL_SIZE_MB}MB (${LOCAL_SIZE} bytes)"

RELEASE_ID=$(gh api "repos/dennyandwu/VoiceInput/releases/tags/$VERSION" --jq '.id')
TOKEN=$(gh auth token)

# 删除同名旧资产，避免缓存/索引混淆
OLD_ASSET_ID=$(gh api "repos/dennyandwu/VoiceInput/releases/tags/$VERSION" --jq ".assets[] | select(.name==\"$DMG_NAME\") | .id" 2>/dev/null || true)
if [ -n "${OLD_ASSET_ID:-}" ]; then
    warn "发现同名旧资产（id=$OLD_ASSET_ID），先删除..."
    gh api -X DELETE "repos/dennyandwu/VoiceInput/releases/assets/$OLD_ASSET_ID" >/dev/null
    success "旧资产已删除"
fi

UPLOAD_URL="https://uploads.github.com/repos/dennyandwu/VoiceInput/releases/$RELEASE_ID/assets?name=$DMG_NAME"
MAX_UPLOAD_RETRIES=3
UPLOAD_OK=false

for ATTEMPT in $(seq 1 $MAX_UPLOAD_RETRIES); do
    info "  上传尝试 ${ATTEMPT}/${MAX_UPLOAD_RETRIES}..."
    HTTP_CODE=$(curl --fail --retry 3 --retry-delay 5 --retry-all-errors \
        -X POST \
        -H "Authorization: token $TOKEN" \
        -H "Content-Type: application/octet-stream" \
        -H "Content-Length: $LOCAL_SIZE" \
        --data-binary @"$DMG_PATH" \
        "$UPLOAD_URL" \
        -o /tmp/release_upload_result.json -w "%{http_code}" 2>/tmp/release_upload_error.log || true)

    if [ "$HTTP_CODE" = "201" ]; then
        UPLOAD_OK=true
        success "DMG 上传完成 (HTTP $HTTP_CODE)"
        break
    fi

    warn "上传失败 (HTTP ${HTTP_CODE:-N/A})"
    tail -n 20 /tmp/release_upload_error.log 2>/dev/null || true
    cat /tmp/release_upload_result.json 2>/dev/null || true

    # 失败后清理同名资产再重试（处理半上传/脏状态）
    RETRY_ASSET_ID=$(gh api "repos/dennyandwu/VoiceInput/releases/tags/$VERSION" --jq ".assets[] | select(.name==\"$DMG_NAME\") | .id" 2>/dev/null || true)
    if [ -n "${RETRY_ASSET_ID:-}" ]; then
        warn "清理重试前资产（id=$RETRY_ASSET_ID）"
        gh api -X DELETE "repos/dennyandwu/VoiceInput/releases/assets/$RETRY_ASSET_ID" >/dev/null || true
    fi
    sleep 5
done

$UPLOAD_OK || error "上传失败：重试 ${MAX_UPLOAD_RETRIES} 次后仍未成功"

# ─── 步骤 5: 验证上传完整性（API + CDN HEAD 双校验，带等待轮询）─────────
info "步骤 5/5: 验证 GitHub Release 完整性..."

MAX_VERIFY_ROUNDS=12   # 最多等 2 分钟
VERIFY_INTERVAL=10
VERIFY_OK=false
REMOTE_SIZE=0
CDN_SIZE=0
DOWNLOAD_URL=""

for ROUND in $(seq 1 $MAX_VERIFY_ROUNDS); do
    info "  验证轮询 ${ROUND}/${MAX_VERIFY_ROUNDS}..."

    REMOTE_SIZE=$(gh api "repos/dennyandwu/VoiceInput/releases/tags/$VERSION" --jq ".assets[] | select(.name==\"$DMG_NAME\") | .size" 2>/dev/null || echo "0")
    DOWNLOAD_URL=$(gh api "repos/dennyandwu/VoiceInput/releases/tags/$VERSION" --jq ".assets[] | select(.name==\"$DMG_NAME\") | .browser_download_url" 2>/dev/null || echo "")

    if [ -n "$DOWNLOAD_URL" ] && [ "$DOWNLOAD_URL" != "null" ]; then
        CDN_SIZE=$(curl -sSIL -L "$DOWNLOAD_URL" | awk 'BEGIN{IGNORECASE=1} /^content-length:/ {gsub("\r", "", $2); v=$2} END{if(v=="") v=0; print v}' || echo "0")
        CDN_SIZE=${CDN_SIZE:-0}
    else
        CDN_SIZE=0
    fi

    echo "    API size: ${REMOTE_SIZE} bytes"
    echo "    CDN size: ${CDN_SIZE} bytes"

    if [ "$REMOTE_SIZE" = "$LOCAL_SIZE" ] && [ "$CDN_SIZE" = "$LOCAL_SIZE" ]; then
        VERIFY_OK=true
        break
    fi

    sleep "$VERIFY_INTERVAL"
done

echo ""
echo "  本地 DMG: ${LOCAL_SIZE_MB}MB (${LOCAL_SIZE} bytes)"
echo "  API 资产:  $((REMOTE_SIZE / 1024 / 1024))MB (${REMOTE_SIZE} bytes)"
echo "  CDN HEAD:  $((CDN_SIZE / 1024 / 1024))MB (${CDN_SIZE} bytes)"
echo ""

if [ "$VERIFY_OK" != "true" ]; then
    error "❌ 上传验证失败：API/CDN 大小与本地不一致（本地 ${LOCAL_SIZE}, API ${REMOTE_SIZE}, CDN ${CDN_SIZE}）"
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

#!/usr/bin/env bash
# build_app.sh - VoiceInput .app Bundle 打包脚本
# Phase 5: .app Bundle + DMG 制作
# Copyright (c) 2026 urDAO Investment

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# ─── 配置 ───────────────────────────────────────────────────────────────────
APP_NAME="VoiceInput"
APP_VERSION="3.0.6"
BUNDLE_ID="com.urdao.voiceinput"

SHERPA_DIR="$SCRIPT_DIR/sherpa-onnx-v1.12.28-osx-universal2-shared"
LIB_DIR="$SHERPA_DIR/lib"
MODELS_DIR="$SCRIPT_DIR/Resources/models"

DIST_DIR="$SCRIPT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_FRAMEWORKS="$APP_CONTENTS/Frameworks"
APP_RESOURCES="$APP_CONTENTS/Resources"

DMG_NAME="$APP_NAME-v$APP_VERSION-macos-arm64.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"

# ─── 颜色输出 ────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[✅]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[❌]${NC} $*"; exit 1; }

echo "============================================"
echo "  VoiceInput .app Bundle Builder v$APP_VERSION"
echo "============================================"
echo ""

# ─── 步骤 1: 编译 Swift 源码 ─────────────────────────────────────────────────
info "步骤 1/7: 编译 Swift 源码..."
bash "$SCRIPT_DIR/build.sh" || error "编译失败"
BINARY="$SCRIPT_DIR/$APP_NAME"
[ -f "$BINARY" ] || error "编译产物不存在: $BINARY"
success "编译完成: $BINARY"
echo ""

# ─── 步骤 2: 创建 .app bundle 目录结构 ──────────────────────────────────────
info "步骤 2/7: 创建 .app bundle 目录结构..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS"
mkdir -p "$APP_FRAMEWORKS"
mkdir -p "$APP_RESOURCES/models/sense-voice"
mkdir -p "$APP_RESOURCES/models/silero-vad"
success "目录结构创建完成"
echo ""

# ─── 步骤 3: 复制文件 ────────────────────────────────────────────────────────
info "步骤 3/7: 复制文件..."

# 3a. 主二进制
info "  复制主二进制..."
cp "$BINARY" "$APP_MACOS/$APP_NAME"
chmod +x "$APP_MACOS/$APP_NAME"

# 3b. Info.plist
info "  复制 Info.plist..."
cp "$SCRIPT_DIR/Info.plist" "$APP_CONTENTS/Info.plist"

# 3c. dylib（只复制真正的 dylib，不复制 symlink）
info "  复制 dylib..."
cp "$LIB_DIR/libsherpa-onnx-c-api.dylib" "$APP_FRAMEWORKS/"
cp "$LIB_DIR/libonnxruntime.1.23.2.dylib" "$APP_FRAMEWORKS/"

# 3d. 应用图标
if [ -f "$SCRIPT_DIR/Resources/AppIcon.icns" ]; then
    info "  复制应用图标..."
    cp "$SCRIPT_DIR/Resources/AppIcon.icns" "$APP_RESOURCES/AppIcon.icns"
elif [ -f "/tmp/AppIcon.icns" ]; then
    info "  复制应用图标..."
    cp "/tmp/AppIcon.icns" "$APP_RESOURCES/AppIcon.icns"
else
    warn "  AppIcon.icns 不存在，跳过（使用系统默认图标）"
fi

# 3e. 默认配置文件
if [ -f "$SCRIPT_DIR/Resources/default-config.json" ]; then
    info "  复制默认配置..."
    cp "$SCRIPT_DIR/Resources/default-config.json" "$APP_RESOURCES/default-config.json"
fi

# 3e. int8 模型（不复制 float32 的 model.onnx，太大）
info "  复制模型文件（int8 模型，约 240MB）..."
cp "$MODELS_DIR/sense-voice/model.int8.onnx" "$APP_RESOURCES/models/sense-voice/"
cp "$MODELS_DIR/sense-voice/tokens.txt" "$APP_RESOURCES/models/sense-voice/"
if [ -d "$MODELS_DIR/sense-voice/test_wavs" ]; then
    cp -r "$MODELS_DIR/sense-voice/test_wavs" "$APP_RESOURCES/models/sense-voice/"
fi

info "  复制 silero-vad 模型..."
cp "$MODELS_DIR/silero-vad/silero_vad.onnx" "$APP_RESOURCES/models/silero-vad/"

success "文件复制完成"
echo ""

# ─── 步骤 4: 修复 dylib 路径 ─────────────────────────────────────────────────
info "步骤 4/7: 修复 dylib 路径..."

BINARY_IN_BUNDLE="$APP_MACOS/$APP_NAME"
SHERPA_DYLIB="$APP_FRAMEWORKS/libsherpa-onnx-c-api.dylib"
ONNX_DYLIB="$APP_FRAMEWORKS/libonnxruntime.1.23.2.dylib"

# 4a. 修复二进制的 rpath（添加指向 Frameworks 目录的路径）
info "  添加 rpath @executable_path/../Frameworks 到二进制..."
install_name_tool -add_rpath "@executable_path/../Frameworks" "$BINARY_IN_BUNDLE" 2>/dev/null || true

# 4b. 修复 dylib 的 install name
info "  修复 libsherpa-onnx-c-api.dylib install name..."
install_name_tool -id "@rpath/libsherpa-onnx-c-api.dylib" "$SHERPA_DYLIB"

info "  修复 libonnxruntime.1.23.2.dylib install name..."
install_name_tool -id "@rpath/libonnxruntime.1.23.2.dylib" "$ONNX_DYLIB"

# 4c. 修复 sherpa-onnx 对 onnxruntime 的依赖（如果有绝对路径）
SHERPA_ONNX_DEP=$(otool -L "$SHERPA_DYLIB" | grep onnxruntime | grep -v "^$SHERPA_DYLIB" | awk '{print $1}' || true)
if [ -n "$SHERPA_ONNX_DEP" ] && [[ "$SHERPA_ONNX_DEP" != "@rpath"* ]]; then
    info "  修复 sherpa-onnx 对 onnxruntime 的依赖路径: $SHERPA_ONNX_DEP"
    install_name_tool -change "$SHERPA_ONNX_DEP" "@rpath/libonnxruntime.1.23.2.dylib" "$SHERPA_DYLIB"
fi

# 4d. 验证路径
info "  验证二进制依赖..."
MISSING_RPATHS=$(otool -L "$BINARY_IN_BUNDLE" | grep -v "@rpath\|@executable_path\|@loader_path\|/usr/lib\|/System\|$BINARY_IN_BUNDLE" | grep "\.dylib" || true)
if [ -n "$MISSING_RPATHS" ]; then
    warn "  以下依赖可能有问题（非系统库、非@rpath）:"
    echo "$MISSING_RPATHS"
fi

success "dylib 路径修复完成"
echo ""

# ─── 步骤 5: ad-hoc 代码签名 ────────────────────────────────────────────────
info "步骤 5/7: ad-hoc 代码签名..."

# 先签名 dylib（要在 bundle 签名之前）
info "  移除所有 Frameworks 原始签名..."
for dylib in "$APP_FRAMEWORKS"/*.dylib; do
    [ -f "$dylib" ] || continue
    codesign --remove-signature "$dylib" 2>/dev/null || true
    info "    已移除: $(basename "$dylib")"
done

info "  重新签名 Frameworks（无 hardened runtime）..."
for dylib in "$APP_FRAMEWORKS"/*.dylib; do
    [ -f "$dylib" ] || continue
    codesign --force --sign - "$dylib" 2>&1 | grep -v "replacing existing signature" || true
    info "    已签名: $(basename "$dylib")"
done

# 签名整个 bundle（不要使用 --deep，避免嵌套签名不一致）
info "  签名 .app bundle..."
codesign --force --sign - "$APP_BUNDLE" 2>&1 | grep -v "replacing existing signature" || true

success "代码签名完成"
echo ""

# ─── 步骤 6: 验证 ───────────────────────────────────────────────────────────
info "步骤 6/7: 验证 bundle..."

# 验证版本号
PLIST_VER=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null)
info "  Bundle 版本: $PLIST_VER (期望: $APP_VERSION)"
if [ "$PLIST_VER" != "$APP_VERSION" ]; then
    error "版本号不匹配! Info.plist=$PLIST_VER, 期望=$APP_VERSION"
fi

# 验证签名
info "  验证代码签名..."
codesign -dv "$APP_BUNDLE" 2>&1 | head -5 || warn "签名验证输出异常"

# 验证 Gatekeeper（ad-hoc 签名在 macOS 15+ 上预期会显示 rejected）
info "  验证 Gatekeeper..."
if command -v spctl &>/dev/null; then
    spctl --assess --type execute "$APP_BUNDLE" 2>&1 || warn "ad-hoc 签名被 Gatekeeper 标记（正常 - 用户首次运行时右键选择 Open 即可）"
else
    warn "  spctl 命令不可用（可能在沙箱环境中），跳过 Gatekeeper 检查"
fi

# 验证 bundle 结构
info "  验证 bundle 结构..."
[ -f "$APP_CONTENTS/Info.plist" ]    && echo "    ✅ Info.plist" || warn "    ❌ Info.plist 缺失"
[ -f "$APP_MACOS/$APP_NAME" ]        && echo "    ✅ MacOS/$APP_NAME" || warn "    ❌ 主二进制缺失"
[ -f "$APP_FRAMEWORKS/libsherpa-onnx-c-api.dylib" ] && echo "    ✅ Frameworks/libsherpa-onnx-c-api.dylib" || warn "    ❌ sherpa dylib 缺失"
[ -f "$APP_FRAMEWORKS/libonnxruntime.1.23.2.dylib" ] && echo "    ✅ Frameworks/libonnxruntime.1.23.2.dylib" || warn "    ❌ onnxruntime dylib 缺失"
[ -f "$APP_RESOURCES/models/sense-voice/model.int8.onnx" ] && echo "    ✅ models/sense-voice/model.int8.onnx" || warn "    ❌ int8 模型缺失"
[ -f "$APP_RESOURCES/models/sense-voice/tokens.txt" ] && echo "    ✅ models/sense-voice/tokens.txt" || warn "    ❌ tokens.txt 缺失"
[ -f "$APP_RESOURCES/models/silero-vad/silero_vad.onnx" ] && echo "    ✅ models/silero-vad/silero_vad.onnx" || warn "    ❌ silero-vad 模型缺失"

# 显示 bundle 大小
BUNDLE_SIZE=$(du -sh "$APP_BUNDLE" | cut -f1)
info "  Bundle 大小: $BUNDLE_SIZE"

success "Bundle 验证完成"
echo ""

# ─── 步骤 7: 制作 DMG ───────────────────────────────────────────────────────
info "步骤 7/7: 制作 DMG..."

DMG_STAGING="$DIST_DIR/.dmg-staging"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"

# 复制 .app bundle
cp -R "$APP_BUNDLE" "$DMG_STAGING/"

# 创建 /Applications 软链接（用于拖拽安装）
ln -s /Applications "$DMG_STAGING/Applications"

# 复制辅助文件
cp "$SCRIPT_DIR/download_float32_model.sh" "$DMG_STAGING/"
cp "$SCRIPT_DIR/UNINSTALL.md" "$DMG_STAGING/"

# 创建 README 文件
cat > "$DMG_STAGING/README.md" << 'README_EOF'
# VoiceInput v2.0.0

本地离线语音识别输入法，基于 SenseVoice + Sherpa-ONNX。

## 安装
将 VoiceInput.app 拖拽到 Applications 文件夹。

## 首次运行
双击 VoiceInput.app 启动后，系统会请求麦克风权限，请允许。

## 使用
- 默认热键：右 Option（按住说话）
- 菜单栏图标右键可打开设置

## 卸载
见 UNINSTALL.md

## 下载 float32 精确模型
运行 download_float32_model.sh（需联网，约 894MB）

---
urDAO Investment © 2026
README_EOF

# 删除旧 DMG
rm -f "$DMG_PATH"

# 创建 DMG
info "  创建 DMG（请稍候）..."
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$DMG_STAGING" \
    -ov \
    -format UDZO \
    "$DMG_PATH" 2>&1 | tail -3

rm -rf "$DMG_STAGING"

DMG_SIZE=$(du -sh "$DMG_PATH" | cut -f1)
success "DMG 制作完成: $DMG_PATH ($DMG_SIZE)"
echo ""

# ─── 完成 ────────────────────────────────────────────────────────────────────
echo "============================================"
echo -e "${GREEN}  🎉 打包完成！${NC}"
echo "============================================"
echo ""
echo "产物:"
echo "  .app bundle: $APP_BUNDLE"
echo "  DMG 镜像:    $DMG_PATH"
echo ""
echo "测试方式:"
echo "  # 直接运行 .app"
echo "  open $APP_BUNDLE"
echo ""
echo "  # 或挂载 DMG 测试"
echo "  open $DMG_PATH"
echo ""
echo "安装:"
echo "  将 VoiceInput.app 拖拽到 /Applications 或 ~/Applications 即可"
echo ""

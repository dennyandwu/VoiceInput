#!/bin/bash
# download_float32_model.sh
# 下载 SenseVoice float32 精确模型（894MB）
# 用于需要更高识别精度的场景
#
# 用法：
#   1. 放在 VoiceInput.app 旁边运行：
#      bash download_float32_model.sh
#   2. 或传入 .app 路径：
#      bash download_float32_model.sh /Applications/VoiceInput.app

set -euo pipefail

# ─── 确定模型目录 ──────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# 支持传入 .app 路径，或自动检测同目录下的 .app
if [ $# -ge 1 ] && [ -d "$1" ]; then
    APP_PATH="$1"
elif [ -d "$SCRIPT_DIR/VoiceInput.app" ]; then
    APP_PATH="$SCRIPT_DIR/VoiceInput.app"
elif [ -d "/Applications/VoiceInput.app" ]; then
    APP_PATH="/Applications/VoiceInput.app"
elif [ -d "$HOME/Applications/VoiceInput.app" ]; then
    APP_PATH="$HOME/Applications/VoiceInput.app"
else
    echo "❌ 找不到 VoiceInput.app"
    echo "   用法: $0 [/path/to/VoiceInput.app]"
    exit 1
fi

MODEL_DIR="$APP_PATH/Contents/Resources/models/sense-voice"

echo "=== VoiceInput float32 模型下载 ==="
echo "目标目录: $MODEL_DIR"
echo ""

# 检查目录是否存在
if [ ! -d "$MODEL_DIR" ]; then
    echo "❌ 模型目录不存在: $MODEL_DIR"
    exit 1
fi

# 检查是否已有 float32 模型
if [ -f "$MODEL_DIR/model.onnx" ]; then
    SIZE=$(du -sh "$MODEL_DIR/model.onnx" | cut -f1)
    echo "✅ float32 模型已存在（$SIZE），无需重新下载"
    echo "   路径: $MODEL_DIR/model.onnx"
    exit 0
fi

# ─── 下载模型 ──────────────────────────────────────────────────────────────────
ARCHIVE_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17.tar.bz2"
TMP_ARCHIVE="/tmp/sense-voice-float32.tar.bz2"
TMP_DIR="/tmp/sense-voice-extract"

echo "⬇️  下载中（约 894MB，请耐心等待）..."
echo "   来源: $ARCHIVE_URL"
echo ""

curl -L --progress-bar -o "$TMP_ARCHIVE" "$ARCHIVE_URL"

echo ""
echo "📦 解压中..."
rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"
tar -xjf "$TMP_ARCHIVE" -C "$TMP_DIR"

# 找到 model.onnx
EXTRACTED_MODEL=$(find "$TMP_DIR" -name "model.onnx" | head -1)
if [ -z "$EXTRACTED_MODEL" ]; then
    echo "❌ 解压后未找到 model.onnx"
    echo "   解压内容:"
    ls -la "$TMP_DIR/"
    exit 1
fi

echo "✅ 找到模型文件: $EXTRACTED_MODEL"
echo "📋 复制到 bundle..."
cp "$EXTRACTED_MODEL" "$MODEL_DIR/model.onnx"

# 清理临时文件
rm -rf "$TMP_ARCHIVE" "$TMP_DIR"

MODEL_SIZE=$(du -sh "$MODEL_DIR/model.onnx" | cut -f1)
echo ""
echo "🎉 float32 模型安装完成！"
echo "   路径: $MODEL_DIR/model.onnx"
echo "   大小: $MODEL_SIZE"
echo ""
echo "在 VoiceInput 设置中切换到「float32 (精确)」模型即可使用。"

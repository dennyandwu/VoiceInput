#!/usr/bin/env bash
# build.sh - VoiceInput 编译脚本
# Phase 4: MenuBar GUI + 完整集成
# 使用 swiftc 直接编译，链接 sherpa-onnx 动态库
# Copyright (c) 2026 urDAO Investment

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# ─── 配置 ───────────────────────────────────────────────────────────────────
SHERPA_DIR="$SCRIPT_DIR/sherpa-onnx-v1.12.28-osx-universal2-shared"
SOURCES_DIR="$SCRIPT_DIR/Sources/VoiceInput"
OUTPUT="$SCRIPT_DIR/VoiceInput"

# 检查 sherpa-onnx 库
if [ ! -d "$SHERPA_DIR" ]; then
  echo "❌ ERROR: sherpa-onnx 库未找到: $SHERPA_DIR"
  echo "   请运行 download_libs.sh 下载"
  exit 1
fi

INCLUDE_DIR="$SHERPA_DIR/include"
LIB_DIR="$SHERPA_DIR/lib"

echo "=== VoiceInput Build (Phase 4: MenuBar GUI) ==="
echo "sherpa-onnx: $SHERPA_DIR"
echo "Output:      $OUTPUT"
echo ""

# ─── 编译 ────────────────────────────────────────────────────────────────────
echo "⏳ 编译中..."

swiftc \
  -lc++ \
  -import-objc-header "$SOURCES_DIR/SherpaOnnx-Bridging-Header.h" \
  -I "$INCLUDE_DIR" \
  "$SOURCES_DIR/SherpaOnnx.swift" \
  "$SOURCES_DIR/SpeechEngine.swift" \
  "$SOURCES_DIR/AudioRecorder.swift" \
  "$SOURCES_DIR/VoiceActivityDetector.swift" \
  "$SOURCES_DIR/RecognitionPipeline.swift" \
  "$SOURCES_DIR/TextInjector.swift" \
  "$SOURCES_DIR/HotkeyManager.swift" \
  "$SOURCES_DIR/SettingsManager.swift" \
  "$SOURCES_DIR/WordLibraryManager.swift" \
  "$SOURCES_DIR/LLMPostProcessor.swift" \
  "$SOURCES_DIR/PermissionManager.swift" \
  "$SOURCES_DIR/StatusBarController.swift" \
  "$SOURCES_DIR/HotkeyRecorderWindow.swift" \
  "$SOURCES_DIR/RecordingOverlayWindow.swift" \
  "$SOURCES_DIR/UpdateChecker.swift" \
  "$SOURCES_DIR/TextPostProcessor.swift" \
  "$SOURCES_DIR/AppDelegate.swift" \
  "$SOURCES_DIR/main.swift" \
  -L "$LIB_DIR" \
  -lsherpa-onnx-c-api \
  -lonnxruntime \
  -framework AVFoundation \
  -framework AppKit \
  -framework Carbon \
  -target arm64-apple-macosx14.0 \
  -O \
  -o "$OUTPUT"

echo "✅ 编译成功: $OUTPUT"
echo ""
echo "运行方式:"
echo "  export DYLD_LIBRARY_PATH=\"$LIB_DIR:\$DYLD_LIBRARY_PATH\""
echo ""
echo "  # CLI 模式（保留所有原有功能）:"
echo "  $OUTPUT --test"
echo "  $OUTPUT --simulate Resources/models/sense-voice/test_wavs/zh.wav"
echo "  $OUTPUT --mic"
echo "  $OUTPUT --ptt"
echo ""
echo "  # GUI 模式（MenuBar App）:"
echo "  $OUTPUT"
echo "  # 无参数启动，图标出现在菜单栏，右键显示菜单"

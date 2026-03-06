#!/usr/bin/env bash
# run.sh - 运行 VoiceInput（设置 DYLD_LIBRARY_PATH）
# Copyright (c) 2026 urDAO Investment

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SHERPA_DIR="$SCRIPT_DIR/sherpa-onnx-v1.12.28-osx-universal2-shared"

export DYLD_LIBRARY_PATH="$SHERPA_DIR/lib:${DYLD_LIBRARY_PATH:-}"

if [ ! -f "$SCRIPT_DIR/VoiceInput" ]; then
  echo "⚠️  未找到编译产物，先运行 build.sh..."
  bash "$SCRIPT_DIR/build.sh"
fi

exec "$SCRIPT_DIR/VoiceInput" "$@"

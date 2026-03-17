#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "== VoiceInput Lint =="

if command -v swiftlint >/dev/null 2>&1; then
  echo "[1/2] SwiftLint"
  swiftlint lint --strict
else
  echo "[1/2] SwiftLint 未安装，跳过（brew install swiftlint）"
fi

if command -v shellcheck >/dev/null 2>&1; then
  echo "[2/2] ShellCheck"
  shellcheck build.sh build_app.sh release.sh
else
  echo "[2/2] ShellCheck 未安装，跳过（brew install shellcheck）"
fi

echo "✅ Lint 完成"

# VoiceInput

macOS 全局语音输入工具 — 按住快捷键说话，自动识别并输入到任意应用。

## 功能

- 🎙️ **全局语音输入** — 在任何应用中按住快捷键说话，识别结果自动粘贴
- 🌍 **多语言识别** — 基于 SenseVoice 模型，支持中/英/日/韩/粤语自动检测
- ⚡ **极速识别** — M系列芯片优化，RTF < 0.01（5秒语音仅需49ms识别）
- 🎯 **自定义快捷键** — 支持任意按键作为触发键
- 📊 **录音可视化** — 悬浮窗实时显示录音波形和计时
- 🔄 **自动更新** — 一键检查并下载最新版本
- 🔒 **本地运行** — 所有语音处理在本地完成，无需联网

## 系统要求

- macOS 13.0+ (Ventura 或更高)
- Apple Silicon (M1/M2/M3/M4)
- 约 300MB 磁盘空间（含 int8 模型）

## 安装

1. 从 [Releases](https://github.com/urdao/VoiceInput/releases) 下载最新 DMG
2. 打开 DMG，将 VoiceInput.app 拖入 /Applications
3. 首次运行：右键 → 打开（绕过 Gatekeeper）
4. 授予权限：麦克风 + 辅助功能

## 使用

- **Push-to-Talk**: 按住快捷键说话，松开后自动识别并输入
- **Toggle 模式**: 按一次开始录音，再按一次停止
- 右键菜单栏图标可切换模式、模型、快捷键

## 技术栈

- Swift (native macOS)
- [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) — ONNX Runtime 推理引擎
- [SenseVoice](https://github.com/FunAudioLLM/SenseVoice) — 阿里达摩院 ASR 模型
- Silero VAD — 语音活动检测
- CGEvent Tap — 全局热键监听
- AVAudioEngine — 实时音频采集

## 许可

MIT License — Copyright (c) 2026 urDAO Investment

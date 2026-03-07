# VoiceInput

macOS 全局语音输入工具 — 按住快捷键说话，自动识别并输入到任意应用。

## 功能

- 🎙️ **全局语音输入** — 在任何应用中按住快捷键说话，松开后文字自动输入到光标位置
- 🌍 **多语言识别** — 基于 SenseVoice 模型，支持中/英/日/韩/粤语自动检测
- ⚡ **极速识别** — M系列芯片优化，RTF < 0.01（5秒语音仅需 49ms 识别）
- ⌨️ **不污染剪贴板** — 使用 CGEvent Unicode 直接模拟键入，不影响剪贴板内容
- 🎯 **自定义快捷键** — 支持任意按键作为触发键（默认右 Option）
- 📊 **录音可视化** — 悬浮窗实时显示录音波形和计时
- 🔄 **自动更新** — 一键检查并下载最新版本
- 🔒 **完全本地** — 所有语音处理在设备上完成，无需联网，无数据上传

## 系统要求

- macOS 13.0+（Ventura 或更高）
- Apple Silicon（M1/M2/M3/M4）
- 约 300MB 磁盘空间（含 int8 模型）

## 安装

### 方式一：局域网下载（推荐，速度最快）

```bash
# 下载 DMG（替换为实际的局域网 IP 和版本号）
curl -O http://<mac-mini-ip>:9999/VoiceInput-v1.0.5-beta-macos-arm64.dmg

# 打开 DMG
open VoiceInput-v1.0.5-beta-macos-arm64.dmg
```

将 VoiceInput.app 拖入 Applications 文件夹。

### 方式二：GitHub Releases

从 [Releases](https://github.com/dennyandwu/VoiceInput/releases) 下载最新 DMG。

> ⚠️ GitHub 对大文件上传有限制，如果 DMG 大小明显不对（应约 187MB），请使用局域网方式下载。

### 首次启动

由于未经 Apple 公证，首次启动需要解除 Gatekeeper 限制：

```bash
# 解除隔离属性（每次重新安装后需要执行一次）
sudo xattr -r -d com.apple.quarantine /Applications/VoiceInput.app

# 启动应用
open /Applications/VoiceInput.app
```

或者：右键点击 VoiceInput.app → 选择「打开」→ 在弹窗中点击「打开」。

### 权限设置

首次启动时需要授予以下权限（在「系统设置 → 隐私与安全性」中）：

| 权限 | 用途 | 必须 |
|------|------|------|
| 🎤 麦克风 | 录音 | ✅ |
| ♿ 辅助功能 | 全局快捷键 + 文字输入 | ✅ |

## 模型

VoiceInput 使用以下开源模型：

### SenseVoice-Small（语音识别）

- **来源**: [FunAudioLLM/SenseVoice](https://github.com/FunAudioLLM/SenseVoice) — 阿里达摩院开源
- **能力**: 中/英/日/韩/粤语自动检测，支持情感识别和音频事件检测
- **许可**: Apache 2.0
- **预转换 ONNX 模型**: [sherpa-onnx SenseVoice 模型](https://github.com/k2-fsa/sherpa-onnx/releases/tag/asr-models)

| 模型 | 文件 | 大小 | 速度 | 精度 |
|------|------|------|------|------|
| **int8（默认）** | `model.int8.onnx` | 228MB | ⚡ 更快 | 与 float32 差异 <1% |
| **float32** | `model.onnx` | 894MB | 正常 | 最高精度 |

#### 切换到 float32 模型

int8 模型已内置。如需使用 float32 精度模型：

1. 下载模型文件：
```bash
# 从 sherpa-onnx 模型仓库下载（约 894MB）
curl -L -o model.onnx "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17.tar.bz2"

# 解压后取出 model.onnx
tar xf sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17.tar.bz2
cp sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/model.onnx .
```

2. 放入 app 资源目录：
```bash
cp model.onnx /Applications/VoiceInput.app/Contents/Resources/models/sense-voice/model.onnx
```

3. 在菜单栏右键 → 选择「float32（精准）」

### Silero VAD（语音活动检测）

- **来源**: [snakers4/silero-vad](https://github.com/snakers4/silero-vad)
- **能力**: 实时检测语音起止，过滤静音和噪音
- **许可**: MIT
- **已内置**: `silero_vad.onnx`（629KB）

## 使用方法

### 基本操作

1. 启动 VoiceInput，菜单栏出现 🎙️ 图标
2. 在**任意应用**中，按住 **右 Option 键** 开始说话
3. 松开按键，识别结果自动输入到光标位置
4. 听到 **"Tink"** 音效 = 开始录音，**"Pop"** 音效 = 停止录音

### 录音模式

- **Push-to-Talk（默认）** — 按住说话，松开停止
- **Toggle** — 按一次开始，再按一次停止

### 菜单栏选项

右键点击菜单栏图标可以：

- 🔑 设置快捷键 — 自定义触发按键
- 🧠 切换模型 — int8（快速，228MB）/ float32（精准，894MB）
- 🔄 检查更新 — 检测并下载新版本
- ℹ️ 关于 — 查看版本信息

### 调试

如果语音识别不工作，通过终端启动查看日志：

```bash
/Applications/VoiceInput.app/Contents/MacOS/VoiceInput 2>&1
```

关注以下日志：
- `采集 XXX 样本 (X.XXs)` — 应大于 1 秒
- `maxAmp=X.XX` — 应大于 0.01（否则麦克风可能没声音）
- `识别完成: "..."` — 识别结果

## 从源码构建

```bash
# 克隆仓库
git clone https://github.com/dennyandwu/VoiceInput.git
cd VoiceInput

# 下载 sherpa-onnx 预编译库（需要手动放置）
# 参考：https://github.com/k2-fsa/sherpa-onnx/releases

# 编译 CLI 版本
bash build.sh

# 打包 .app + DMG
bash build_app.sh
```

## 技术栈

- **Swift** — 原生 macOS 开发
- **[sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx)** — ONNX Runtime 推理引擎
- **[SenseVoice](https://github.com/FunAudioLLM/SenseVoice)** — 阿里达摩院多语言 ASR 模型
- **Silero VAD** — 语音活动检测
- **CGEvent Tap** — 全局热键监听
- **AVAudioEngine** — 实时音频采集
- **CGEventKeyboardSetUnicodeString** — 文字注入（不污染剪贴板）

## 许可

[MIT License](LICENSE) — Copyright (c) 2026 urDAO Investment

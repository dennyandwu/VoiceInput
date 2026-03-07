# OpenClaw STT 引擎替换方案

> Author: Satoshi ⚡ | Date: 2026-03-07
> Task: 替换 whisper-cli 为 sensevoice-transcribe

---

## 一、Benchmark 对比

### 测试环境
- Mac mini M4, macOS 26.2, arm64
- whisper-cli: ggml-base.bin (141MB), whisper.cpp via Homebrew
- sensevoice-transcribe: model.int8.onnx (228MB), sherpa-onnx v1.12.28

### 中文测试 (zh.wav, 5.59s)

| 指标 | whisper-cli (base) | sensevoice | 对比 |
|------|-------------------|------------|------|
| **速度** | 0.71s (总) | 0.52s (总) | **SenseVoice 快 27%** |
| **推理时间** | ~95ms | ~57ms | **SenseVoice 快 40%** |
| **结果** | 開放時間早上9點,墜下5點 | 开放时间早上9点至下午5点。 | **SenseVoice 完胜** |
| **问题** | ❌ 繁体、"墜下"错误、无标点 | ✅ 简体、准确、有标点 | — |

### 英文测试 (en.wav, 7.15s)

| 指标 | whisper-cli (base) | sensevoice | 对比 |
|------|-------------------|------------|------|
| **速度** | 0.69s (总) | 0.55s (总) | **SenseVoice 快 20%** |
| **推理时间** | ~99ms | ~70ms | **SenseVoice 快 29%** |
| **结果** | The tribal thief... fifty pieces of gold. | The tribal chieftain... 50 pieces of code. | **各有错误** |
| **问题** | "thief"应为"chieftain" | "code"应为"gold" | 英文精度接近 |

### 总结

| 维度 | whisper-cli (base) | sensevoice (int8) | 胜出 |
|------|-------------------|-------------------|------|
| **中文准确率** | ⭐⭐ | ⭐⭐⭐⭐⭐ | SenseVoice |
| **英文准确率** | ⭐⭐⭐ | ⭐⭐⭐ | 持平 |
| **速度** | 0.7s | 0.5s | SenseVoice |
| **模型大小** | 141MB | 228MB | whisper 更小 |
| **标点输出** | ❌ 无 | ✅ 有 | SenseVoice |
| **简繁体** | 繁体输出 | 简体输出 | SenseVoice |
| **ITN** | ❌ | ✅ (数字规范化) | SenseVoice |

**结论：SenseVoice 在中文场景全面碾压 whisper-base，速度也更快。强烈推荐替换。**

---

## 二、sensevoice-transcribe CLI

### 位置
```
/Users/0xfg_bot/.openclaw/workspace-satoshi/VoiceInput/tools/sensevoice-transcribe
```

### 用法（兼容 whisper-cli 接口）
```bash
# 基础用法 — 直接输出到 stdout
sensevoice-transcribe <audio.wav>

# whisper-cli 兼容模式 — 输出到 .txt 文件
sensevoice-transcribe -m <model_dir> -otxt -of <output_base> <audio.wav>

# 指定语言
sensevoice-transcribe -l zh <audio.wav>   # 中文
sensevoice-transcribe -l en <audio.wav>   # 英文
sensevoice-transcribe -l auto <audio.wav> # 自动检测（默认）
```

### 接口兼容性
| whisper-cli 参数 | sensevoice-transcribe | 说明 |
|------------------|----------------------|------|
| `-m <model>` | ✅ 支持 | 可指向目录或 .onnx 文件 |
| `-otxt` | ✅ 支持 | 输出 .txt 文件 |
| `-of <base>` | ✅ 支持 | 输出文件前缀 |
| `-l <lang>` | ✅ 支持 | zh/en/auto |
| `-t <threads>` | ✅ 支持(忽略) | SenseVoice 默认 4 线程 |
| `-f <file>` | ✅ 支持 | 音频文件路径 |
| `--no-timestamps` | ✅ 支持(忽略) | SenseVoice 不输出时间戳 |

### 模型自动发现
优先级：`-m 参数` → `SENSEVOICE_MODEL 环境变量` → 默认路径

### 依赖
- sherpa-onnx 共享库（已通过 rpath 链接）
- ffmpeg（音频格式转换，brew install ffmpeg）
- 无 Python 依赖

---

## 三、替换方案

### 方案 A：符号链接（最简单，推荐）

```bash
# 1. 安装 sensevoice-transcribe 到 PATH
sudo ln -sf /Users/0xfg_bot/.openclaw/workspace-satoshi/VoiceInput/tools/sensevoice-transcribe \
  /opt/homebrew/bin/sensevoice-transcribe

# 2. 设置 OpenClaw 环境变量
# 在 OpenClaw gateway 配置或 .zshrc 中：
export WHISPER_CPP_MODEL="/Users/0xfg_bot/.openclaw/workspace-satoshi/VoiceInput/Resources/models/sense-voice"
```

但这需要 OpenClaw 源码支持 sensevoice-transcribe 命令。

### 方案 B：OpenClaw 配置修改（推荐）

OpenClaw 的 `audio-transcription-runner` 支持多个后端。查看 `resolveLocalWhisperCppEntry()`:

```javascript
// 当前逻辑：
if (!await hasBinary("whisper-cli")) return null;
const modelPath = envModel || "/opt/homebrew/share/whisper-cpp/for-tests-ggml-tiny.bin";
return { command: "whisper-cli", args: ["-m", modelPath, "-otxt", "-of", ...] };
```

**建议 OpenClaw 新增 sensevoice 后端检测：**

```javascript
async function resolveLocalSenseVoiceEntry() {
  if (!await hasBinary("sensevoice-transcribe")) return null;
  const envModel = process.env.SENSEVOICE_MODEL?.trim();
  const defaultModel = path.join(os.homedir(), 
    ".openclaw/workspace-satoshi/VoiceInput/Resources/models/sense-voice");
  const modelPath = envModel || defaultModel;
  return {
    command: "sensevoice-transcribe",
    args: ["-m", modelPath, "-otxt", "-of"],
    priority: 10, // 高于 whisper-cli
  };
}
```

### 方案 C：whisper-cli 替身（hack，临时方案）

```bash
# 备份原 whisper-cli
sudo mv /opt/homebrew/bin/whisper-cli /opt/homebrew/bin/whisper-cli.bak

# 创建替身脚本
cat > /opt/homebrew/bin/whisper-cli << 'EOF'
#!/bin/bash
# whisper-cli → sensevoice-transcribe 替身
exec /Users/0xfg_bot/.openclaw/workspace-satoshi/VoiceInput/tools/sensevoice-transcribe "$@"
EOF
chmod +x /opt/homebrew/bin/whisper-cli
```

---

## 四、推荐步骤

1. **立即可做**：方案 C（替身脚本），零侵入，随时可回滚
2. **正式方案**：向 OpenClaw 提 PR，新增 sensevoice 后端（方案 B）
3. **长期**：sensevoice-transcribe 作为独立工具发布到 Homebrew

### 回滚
```bash
# 恢复原 whisper-cli
sudo mv /opt/homebrew/bin/whisper-cli.bak /opt/homebrew/bin/whisper-cli
```

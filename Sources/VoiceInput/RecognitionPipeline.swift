// Sources/VoiceInput/RecognitionPipeline.swift
// 语音识别完整 Pipeline
// 串联 AudioRecorder → VAD → SpeechEngine
// Copyright (c) 2026 urDAO Investment

import Foundation
import AVFoundation

// MARK: - Pipeline 结果

struct PipelineResult {
    let text: String
    let lang: String
    let emotion: String
    let event: String
    let audioSamples: Int      // 处理的音频样本数
    let duration: Double       // 音频时长（秒）
    let processingTime: Double // 识别耗时（秒）

    var isEmpty: Bool { text.isEmpty }

    var description: String {
        let parts = [
            "text: \"\(text)\"",
            "lang: \(lang.isEmpty ? "?" : lang)",
            "duration: \(String(format: "%.2f", duration))s",
            "RTF: \(String(format: "%.3f", processingTime / max(duration, 0.001)))"
        ]
        return parts.joined(separator: ", ")
    }
}

// MARK: - RecognitionPipeline

/// RecognitionPipeline 串联完整语音识别流程
/// 支持两种工作模式：
/// 1. Push-to-Talk：手动 startListening / stopListening
/// 2. Simulate：从 WAV 文件模拟麦克风输入
class RecognitionPipeline {

    // MARK: - 组件

    let recorder = AudioRecorder()
    let engine: SpeechEngine
    let vad: VoiceActivityDetector?

    // MARK: - 配置

    var useVAD: Bool  // 是否启用 VAD（默认 true，模型可用时）

    // MARK: - 状态

    private(set) var isListening: Bool = false
    private var vadSegments: [[Float]] = []
    private let vadLock = NSLock()

    // MARK: - 初始化

    /// 初始化 Pipeline
    /// - Parameters:
    ///   - modelPaths: SpeechEngine 模型路径（model.onnx + tokens.txt）
    ///   - sileroModelPath: silero-vad 模型路径（nil 使用默认）
    ///   - useVAD: 是否启用 VAD（默认 true）
    ///   - numThreads: 识别线程数（默认 4）
    init(
        modelPaths: (model: String, tokens: String),
        sileroModelPath: String? = nil,
        useVAD: Bool = true,
        numThreads: Int = 4
    ) {
        self.engine = SpeechEngine()
        self.useVAD = useVAD

        // 初始化 VAD
        if useVAD {
            self.vad = VoiceActivityDetector(sileroModelPath: sileroModelPath)
            fputs("[Pipeline] VAD 后端: \(self.vad!.backendName)\n", stderr)
        } else {
            self.vad = nil
            fputs("[Pipeline] VAD 已禁用\n", stderr)
        }

        // 加载识别模型
        let loaded = engine.loadModel(
            modelPath: modelPaths.model,
            tokensPath: modelPaths.tokens,
            numThreads: numThreads
        )

        if !loaded {
            fputs("[Pipeline] ERROR: 模型加载失败！\n", stderr)
        }
    }

    var modelLoaded: Bool { engine.loaded }

    // MARK: - Push-to-Talk 模式

    /// 开始录音监听
    /// - Returns: 成否成功
    @discardableResult
    func startListening() -> Bool {
        guard modelLoaded else {
            fputs("[Pipeline] ERROR: 模型未加载\n", stderr)
            return false
        }
        guard !isListening else {
            fputs("[Pipeline] 已在监听中\n", stderr)
            return false
        }

        vad?.reset()
        vadLock.lock()
        vadSegments = []
        vadLock.unlock()

        // 设置实时 VAD 回调
        if useVAD, let vad = vad {
            recorder.onAudioBuffer = { [weak self] samples in
                guard let self = self else { return }
                let segments = vad.acceptSamples(samples)
                if !segments.isEmpty {
                    self.vadLock.lock()
                    for seg in segments {
                        self.vadSegments.append(seg.samples)
                    }
                    self.vadLock.unlock()
                    for seg in segments {
                        fputs("[Pipeline] VAD 检测到语音段: \(String(format: "%.2f", seg.duration))s\n", stderr)
                    }
                }
            }
        } else {
            recorder.onAudioBuffer = nil
        }

        isListening = recorder.startRecording()
        if isListening {
            fputs("[Pipeline] 开始监听 🎙️\n", stderr)
        }
        return isListening
    }

    /// 停止录音并识别
    /// - Returns: 识别结果
    func stopListening() -> PipelineResult {
        guard isListening else {
            fputs("[Pipeline] 未在监听中\n", stderr)
            return PipelineResult(text: "", lang: "", emotion: "", event: "", audioSamples: 0, duration: 0, processingTime: 0)
        }

        let fullAudio = recorder.stopRecording()
        isListening = false

        fputs("[Pipeline] 录音结束，总样本: \(fullAudio.count) (\(String(format: "%.2f", Double(fullAudio.count) / 16000.0))s)\n", stderr)

        // 检查音频是否有效（非全零）
        if !fullAudio.isEmpty {
            let maxAmp = fullAudio.map { abs($0) }.max() ?? 0
            let rms = sqrt(fullAudio.map { $0 * $0 }.reduce(0, +) / Float(fullAudio.count))
            fputs("[Pipeline] 音频统计: maxAmp=\(String(format: "%.4f", maxAmp)), RMS=\(String(format: "%.4f", rms))\n", stderr)
            if maxAmp < 0.001 {
                fputs("[Pipeline] ⚠️ 音频几乎静音！检查麦克风是否正常\n", stderr)
            }
        }

        recorder.onAudioBuffer = nil

        // 获取要识别的音频
        let audioToRecognize: [Float]

        if useVAD, let vad = vad {
            // flush 最后可能未完成的语音段
            let finalSegments = vad.flush()
            vadLock.lock()
            for seg in finalSegments {
                vadSegments.append(seg.samples)
            }
            let segments = vadSegments
            vadSegments = []
            vadLock.unlock()

            if segments.isEmpty {
                fputs("[Pipeline] VAD 未检测到语音段，使用完整录音进行识别\n", stderr)
                audioToRecognize = fullAudio
            } else {
                // 拼接所有语音段
                audioToRecognize = segments.flatMap { $0 }
                fputs("[Pipeline] VAD 合并 \(segments.count) 段语音，总计 \(audioToRecognize.count) 样本\n", stderr)
            }
        } else {
            audioToRecognize = fullAudio
        }

        return recognize(audioData: audioToRecognize)
    }

    // MARK: - 定时录音模式

    /// 录音指定时长后识别
    /// - Parameters:
    ///   - duration: 录音时长（秒）
    /// - Returns: 识别结果
    func recordAndRecognize(duration: Double) -> PipelineResult {
        guard modelLoaded else {
            fputs("[Pipeline] ERROR: 模型未加载\n", stderr)
            return PipelineResult(text: "", lang: "", emotion: "", event: "", audioSamples: 0, duration: 0, processingTime: 0)
        }

        fputs("[Pipeline] 开始录音 \(duration)s...\n", stderr)

        if !startListening() {
            return PipelineResult(text: "", lang: "", emotion: "", event: "", audioSamples: 0, duration: 0, processingTime: 0)
        }

        Thread.sleep(forTimeInterval: duration)

        let result = stopListening()
        fputs("[Pipeline] 录音完成，结果: \(result.description)\n", stderr)
        return result
    }

    // MARK: - 模拟模式（无麦克风测试）

    /// 从 WAV 文件模拟麦克风输入，测试完整 Pipeline
    /// - Parameter fileURL: WAV 文件路径
    /// - Returns: 识别结果
    func simulate(fileURL: URL) -> PipelineResult {
        guard modelLoaded else {
            fputs("[Pipeline] ERROR: 模型未加载\n", stderr)
            return PipelineResult(text: "", lang: "", emotion: "", event: "", audioSamples: 0, duration: 0, processingTime: 0)
        }

        fputs("[Pipeline] 模拟模式: \(fileURL.lastPathComponent)\n", stderr)

        let source = SimulatedAudioSource()
        guard source.load(fileURL: fileURL) else {
            fputs("[Pipeline] ERROR: 无法加载模拟音频\n", stderr)
            return PipelineResult(text: "", lang: "", emotion: "", event: "", audioSamples: 0, duration: 0, processingTime: 0)
        }

        vad?.reset()
        var allSegments: [[Float]] = []

        if useVAD, let vad = vad {
            // 通过 VAD 分块处理
            source.simulateRealtime(chunkSize: 512) { chunk in
                let segments = vad.acceptSamples(chunk)
                for seg in segments {
                    allSegments.append(seg.samples)
                    fputs("[Pipeline] VAD 检测到语音段: \(String(format: "%.2f", seg.duration))s\n", stderr)
                }
            }
            // flush 最后一段
            let finalSegments = vad.flush()
            for seg in finalSegments {
                allSegments.append(seg.samples)
                fputs("[Pipeline] VAD flush 语音段: \(String(format: "%.2f", seg.duration))s\n", stderr)
            }
        }

        // 决定识别的音频
        let audioToRecognize: [Float]
        if allSegments.isEmpty {
            fputs("[Pipeline] VAD 无输出，使用全量音频\n", stderr)
            audioToRecognize = source.samples
        } else {
            audioToRecognize = allSegments.flatMap { $0 }
            fputs("[Pipeline] 合并 \(allSegments.count) 个语音段，共 \(audioToRecognize.count) 样本\n", stderr)
        }

        return recognize(audioData: audioToRecognize)
    }

    // MARK: - 直接识别文件

    /// 直接识别 WAV 文件（不经过 VAD）
    func recognize(fileURL: URL) -> PipelineResult {
        guard modelLoaded else {
            return PipelineResult(text: "", lang: "", emotion: "", event: "", audioSamples: 0, duration: 0, processingTime: 0)
        }

        let t0 = Date()
        let result = engine.recognize(fileURL: fileURL)
        let elapsed = Date().timeIntervalSince(t0)

        return PipelineResult(
            text: result.text,
            lang: result.lang,
            emotion: result.emotion,
            event: result.event,
            audioSamples: 0,
            duration: 0,
            processingTime: elapsed
        )
    }

    // MARK: - 内部：识别音频数据

    private func recognize(audioData: [Float]) -> PipelineResult {
        guard !audioData.isEmpty else {
            fputs("[Pipeline] 无有效音频数据\n", stderr)
            return PipelineResult(text: "", lang: "", emotion: "", event: "", audioSamples: 0, duration: 0, processingTime: 0)
        }

        let duration = Double(audioData.count) / 16000.0
        let t0 = Date()

        // MARK: 短音频快速路径 — 直接走 Whisper
        // SenseVoice 对短音频语言检测不稳定（"SenseVoice" → "アイスボイス"）
        let shortThreshold = SettingsManager.shared.shortAudioThreshold
        if duration < shortThreshold && engine.hasWhisper {
            fputs("[Pipeline] 短音频（\(String(format: "%.1f", duration))s < \(String(format: "%.1f", shortThreshold))s）→ Whisper 直接处理\n", stderr)
            let whisperResult = engine.recognizeWithWhisper(audioData: audioData, sampleRate: 16000)
            let wText = whisperResult.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let elapsed = Date().timeIntervalSince(t0)
            if !wText.isEmpty {
                fputs("[Pipeline] Whisper 短音频结果: \"\(wText)\" (\(String(format: "%.3f", elapsed))s)\n", stderr)
                return PipelineResult(
                    text: wText,
                    lang: whisperResult.lang.isEmpty ? "<|en|>" : whisperResult.lang,
                    emotion: "", event: "",
                    audioSamples: audioData.count,
                    duration: duration,
                    processingTime: elapsed
                )
            }
            fputs("[Pipeline] Whisper 短音频返回空，回退 SenseVoice\n", stderr)
        }

        // 第一遍：SenseVoice（快速语言检测 + 中文识别）
        let senseVoiceResult = engine.recognize(audioData: audioData, sampleRate: 16000)
        let detectedLang = TextPostProcessor.extractLanguage(senseVoiceResult.text).isEmpty
            ? senseVoiceResult.lang
            : TextPostProcessor.extractLanguage(senseVoiceResult.text)

        let svText = TextPostProcessor.clean(senseVoiceResult.text)
        let svChinese = chineseRatio(svText)
        let svASCII = asciiRatio(svText)
        let svDom = dominantLanguage(svText)

        fputs("[Pipeline] SenseVoice: lang=\(detectedLang), dom=\(svDom), zh=\(String(format: "%.1f%%", svChinese * 100)), ascii=\(String(format: "%.1f%%", svASCII * 100)), text=\"\(svText)\"\n", stderr)

        // MARK: 日语/韩语误检拦截 → Whisper fallback
        // SenseVoice 对短音频或英语容易误判为日语假名，fallback 到 Whisper
        if (detectedLang == "<|ja|>" || detectedLang == "<|ko|>") && svChinese == 0 && svASCII == 0 {
            let hasUsefulContent = svText.unicodeScalars.contains { scalar in
                (0x4E00...0x9FFF).contains(scalar.value) ||   // CJK Unified
                (0x3400...0x4DBF).contains(scalar.value) ||   // CJK Extension A
                (0x0041...0x007A).contains(scalar.value)      // ASCII letters
            }
            if !hasUsefulContent {
                if engine.hasWhisper {
                    fputs("[Pipeline] ⚠️ 语言误检(\(detectedLang))，全假名无汉字 → Whisper fallback\n", stderr)
                    let whisperResult = engine.recognizeWithWhisper(audioData: audioData, sampleRate: 16000)
                    let wText = whisperResult.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !wText.isEmpty {
                        fputs("[Pipeline] Whisper fallback 结果: \"\(wText)\"\n", stderr)
                        return PipelineResult(
                            text: wText,
                            lang: whisperResult.lang.isEmpty ? "<|en|>" : whisperResult.lang,
                            emotion: "", event: "",
                            audioSamples: audioData.count,
                            duration: duration,
                            processingTime: Date().timeIntervalSince(t0)
                        )
                    }
                    fputs("[Pipeline] Whisper fallback 也返回空，丢弃\n", stderr)
                } else {
                    fputs("[Pipeline] ⚠️ 语言误检(\(detectedLang))，无 Whisper 可用，丢弃\n", stderr)
                }
                return PipelineResult(text: "", lang: "zh", emotion: "", event: "", audioSamples: 0, duration: duration, processingTime: 0)
            }
        }

        var finalResult = senseVoiceResult

        // MARK: 智能路由策略
        if svDom == "zh" {
            // a. 纯中文（>80% 中文字符）→ 直接用 SenseVoice
            fputs("[Pipeline] 路由: 纯中文 → SenseVoice\n", stderr)

        } else if svDom == "en" {
            // b. 纯英文（>80% ASCII）→ 用 Whisper（如已加载）
            if engine.hasWhisper {
                fputs("[Pipeline] 路由: 纯英文 → Whisper\n", stderr)
                let whisperResult = engine.recognizeWithWhisper(audioData: audioData, sampleRate: 16000)
                if !whisperResult.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    fputs("[Pipeline] Whisper 结果: \"\(whisperResult.text)\"\n", stderr)
                    finalResult = whisperResult
                } else {
                    fputs("[Pipeline] Whisper 返回空，回退 SenseVoice\n", stderr)
                }
            } else {
                fputs("[Pipeline] 路由: 纯英文但 Whisper 未加载 → SenseVoice\n", stderr)
            }

        } else {
            // c. 中英混合（20%-80%）
            if engine.hasWhisper && svASCII >= 0.25 {
                // 英文占比 ≥25% 才值得调用 Whisper
                fputs("[Pipeline] 路由: 中英混合（ascii=\(String(format: "%.0f%%", svASCII * 100))）→ Whisper 优先，校验中文保留\n", stderr)
                let whisperResult = engine.recognizeWithWhisper(audioData: audioData, sampleRate: 16000)
                let wText = TextPostProcessor.clean(whisperResult.text)
                let wChinese = chineseRatio(wText)

                fputs("[Pipeline] Whisper: zh=\(String(format: "%.1f%%", wChinese * 100)), text=\"\(wText)\"\n", stderr)

                // Whisper 结果中文比例 >= SenseVoice 的 50%：Whisper 保留了足够多的中文 → 用 Whisper
                let threshold = svChinese * 0.5
                if !wText.isEmpty && wChinese >= threshold {
                    fputs("[Pipeline] Whisper 中文保留率 OK（\(String(format: "%.1f%%", wChinese * 100)) >= \(String(format: "%.1f%%", threshold * 100))），采用 Whisper\n", stderr)
                    finalResult = whisperResult
                } else {
                    // Whisper 丢失了太多中文 → 保留 SenseVoice
                    fputs("[Pipeline] Whisper 中文保留率不足，回退 SenseVoice（保护中文内容）\n", stderr)
                }
            } else if !engine.hasWhisper {
                fputs("[Pipeline] 路由: 中英混合但 Whisper 未加载 → SenseVoice\n", stderr)
            } else {
                fputs("[Pipeline] 路由: 中英混合但英文占比低（ascii=\(String(format: "%.0f%%", svASCII * 100)) < 25%）→ SenseVoice\n", stderr)
            }
        }

        let elapsed = Date().timeIntervalSince(t0)

        fputs("[Pipeline] 识别完成: \"\(finalResult.text)\" (lang=\(finalResult.lang), RTF=\(String(format: "%.3f", elapsed/max(duration, 0.001))))\n", stderr)

        return PipelineResult(
            text: finalResult.text,
            lang: finalResult.lang,
            emotion: finalResult.emotion,
            event: finalResult.event,
            audioSamples: audioData.count,
            duration: duration,
            processingTime: elapsed
        )
    }

    // MARK: - 语言分析辅助函数

    /// 计算文本中中文字符（CJK）的比例
    private func chineseRatio(_ text: String) -> Double {
        guard !text.isEmpty else { return 0.0 }
        let total = text.unicodeScalars.count
        let chinese = text.unicodeScalars.filter { scalar in
            (0x4E00...0x9FFF).contains(scalar.value) ||  // CJK 统一表意文字
            (0x3400...0x4DBF).contains(scalar.value) ||  // CJK 扩展 A
            (0x20000...0x2A6DF).contains(scalar.value)   // CJK 扩展 B
        }.count
        return Double(chinese) / Double(total)
    }

    /// 计算文本中 ASCII 可打印字符（字母+数字）的比例
    private func asciiRatio(_ text: String) -> Double {
        guard !text.isEmpty else { return 0.0 }
        let total = text.unicodeScalars.count
        let ascii = text.unicodeScalars.filter { scalar in
            (0x41...0x5A).contains(scalar.value) || // A-Z
            (0x61...0x7A).contains(scalar.value) || // a-z
            (0x30...0x39).contains(scalar.value)    // 0-9
        }.count
        return Double(ascii) / Double(total)
    }

    /// 判断文本的主导语言
    /// - Returns: "zh"（纯中文 >70%）/ "en"（纯英文 >80%）/ "mixed"（混合）
    private func dominantLanguage(_ text: String) -> String {
        let zh = chineseRatio(text)
        let en = asciiRatio(text)
        if zh > 0.7 { return "zh" }
        if en > 0.8 { return "en" }
        return "mixed"
    }
}

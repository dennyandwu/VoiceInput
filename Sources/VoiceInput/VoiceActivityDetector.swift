// Sources/VoiceInput/VoiceActivityDetector.swift
// VAD - 语音活动检测封装
// 优先使用 sherpa-onnx silero-vad，fallback 到能量阈值 VAD
// Copyright (c) 2026 urDAO Investment

import Foundation

// MARK: - VAD 协议

/// VAD 检测结果
struct SpeechSegment {
    let samples: [Float]       // 语音段 PCM 数据（16kHz Float32）
    let startSample: Int       // 起始样本位置
    let duration: Double       // 时长（秒）

    var isEmpty: Bool { samples.isEmpty }
}

/// VAD 接口协议
protocol VoiceActivityDetectorProtocol {
    /// 送入音频样本，返回检测到的语音段（可能为空）
    func acceptSamples(_ samples: [Float]) -> [SpeechSegment]
    /// 刷新（处理最后剩余的音频）
    func flush() -> [SpeechSegment]
    /// 重置状态
    func reset()
    /// 是否正在说话
    var isSpeaking: Bool { get }
}

// MARK: - Silero VAD（基于 sherpa-onnx）

/// SileroVAD 封装 sherpa-onnx 的 silero-vad 实现
class SileroVAD: VoiceActivityDetectorProtocol {

    private let vad: SherpaOnnxVoiceActivityDetectorWrapper
    private var _isSpeaking: Bool = false

    /// 初始化
    /// - Parameters:
    ///   - modelPath: silero_vad.onnx 路径
    ///   - threshold: 语音检测阈值（默认 0.5）
    ///   - minSilenceDuration: 最短静音时长（秒，默认 0.25）
    ///   - minSpeechDuration: 最短语音时长（秒，默认 0.25）
    ///   - windowSize: 处理窗口大小（样本数，silero-vad 固定 512）
    ///   - maxSpeechDuration: 最长单段语音（秒，默认 30）
    ///   - bufferSizeInSeconds: 内部环形缓冲区大小（秒，默认 30）
    init?(
        modelPath: String,
        threshold: Float = 0.5,
        minSilenceDuration: Float = 0.3,
        minSpeechDuration: Float = 0.25,
        windowSize: Int = 512,
        maxSpeechDuration: Float = 30.0,
        bufferSizeInSeconds: Float = 30.0
    ) {
        guard FileManager.default.fileExists(atPath: modelPath) else {
            fputs("[SileroVAD] ERROR: 模型文件不存在: \(modelPath)\n", stderr)
            return nil
        }

        let sileroConfig = sherpaOnnxSileroVadModelConfig(
            model: modelPath,
            threshold: threshold,
            minSilenceDuration: minSilenceDuration,
            minSpeechDuration: minSpeechDuration,
            windowSize: windowSize,
            maxSpeechDuration: maxSpeechDuration
        )

        var vadConfig = sherpaOnnxVadModelConfig(
            sileroVad: sileroConfig,
            sampleRate: 16000,
            numThreads: 1,
            provider: "cpu",
            debug: 0
        )

        self.vad = SherpaOnnxVoiceActivityDetectorWrapper(
            config: &vadConfig,
            buffer_size_in_seconds: bufferSizeInSeconds
        )

        fputs("[SileroVAD] 初始化成功，模型: \((modelPath as NSString).lastPathComponent)\n", stderr)
        fputs("[SileroVAD] 阈值=\(threshold), 最短静音=\(minSilenceDuration)s, 最短语音=\(minSpeechDuration)s\n", stderr)
    }

    var isSpeaking: Bool { _isSpeaking }

    func acceptSamples(_ samples: [Float]) -> [SpeechSegment] {
        guard !samples.isEmpty else { return [] }

        vad.acceptWaveform(samples: samples)
        _isSpeaking = vad.isSpeechDetected()

        return collectSegments()
    }

    func flush() -> [SpeechSegment] {
        vad.flush()
        _isSpeaking = false
        return collectSegments()
    }

    func reset() {
        vad.reset()
        _isSpeaking = false
    }

    private func collectSegments() -> [SpeechSegment] {
        var segments: [SpeechSegment] = []

        while !vad.isEmpty() {
            let seg = vad.front()
            let duration = Double(seg.samples.count) / 16000.0
            segments.append(SpeechSegment(
                samples: seg.samples,
                startSample: seg.start,
                duration: duration
            ))
            vad.pop()
        }

        return segments
    }
}

// MARK: - 能量阈值 VAD（Fallback）

/// EnergyVAD 基于 RMS 能量阈值的简单 VAD
/// 用于无 silero-vad 模型时的 fallback
class EnergyVAD: VoiceActivityDetectorProtocol {

    private let threshold: Float          // RMS 能量阈值
    private let sampleRate: Int           // 采样率
    private let frameSize: Int            // 每帧样本数
    private let silenceDuration: Double   // 静音超过此时长判断为语音结束（秒）
    private let minSpeechDuration: Double // 最短语音时长（秒）

    // 内部状态
    private var accumulated: [Float] = []  // 当前语音段累积
    private var silentFrames: Int = 0      // 连续静音帧计数
    private var totalSamples: Int = 0      // 已处理总样本数（用于计算起始位置）
    private var speechStart: Int = 0       // 语音段起始样本位置
    private var inSpeech: Bool = false

    private var silenceFrameThreshold: Int {
        Int(silenceDuration * Double(sampleRate) / Double(frameSize))
    }

    private var minSpeechSamples: Int {
        Int(minSpeechDuration * Double(sampleRate))
    }

    var isSpeaking: Bool { inSpeech }

    /// 初始化
    /// - Parameters:
    ///   - threshold: RMS 能量阈值（默认 0.01，范围约 0.005~0.05）
    ///   - sampleRate: 采样率（默认 16000）
    ///   - frameSize: 每帧处理样本数（默认 512）
    ///   - silenceDuration: 静音多久视为语音结束（秒，默认 1.0）
    ///   - minSpeechDuration: 最短语音时长（秒，默认 0.3）
    init(
        threshold: Float = 0.01,
        sampleRate: Int = 16000,
        frameSize: Int = 512,
        silenceDuration: Double = 1.0,
        minSpeechDuration: Double = 0.3
    ) {
        self.threshold = threshold
        self.sampleRate = sampleRate
        self.frameSize = frameSize
        self.silenceDuration = silenceDuration
        self.minSpeechDuration = minSpeechDuration

        fputs("[EnergyVAD] 初始化，阈值=\(threshold), 静音超时=\(silenceDuration)s\n", stderr)
    }

    func acceptSamples(_ samples: [Float]) -> [SpeechSegment] {
        var result: [SpeechSegment] = []
        var offset = 0

        while offset < samples.count {
            let end = min(offset + frameSize, samples.count)
            let frame = Array(samples[offset..<end])
            offset = end

            let rms = computeRMS(frame)

            if rms >= threshold {
                // 有语音
                if !inSpeech {
                    inSpeech = true
                    silentFrames = 0
                    speechStart = totalSamples
                    accumulated = []
                    fputs("[EnergyVAD] 语音开始 (RMS=\(String(format: "%.4f", rms)))\n", stderr)
                }
                accumulated.append(contentsOf: frame)
                silentFrames = 0
            } else {
                // 静音
                if inSpeech {
                    accumulated.append(contentsOf: frame)
                    silentFrames += 1

                    if silentFrames >= silenceFrameThreshold {
                        // 静音超过阈值，语音结束
                        inSpeech = false
                        fputs("[EnergyVAD] 语音结束 (静音帧=\(silentFrames))\n", stderr)

                        if accumulated.count >= minSpeechSamples {
                            // 去掉末尾静音部分
                            let trimEnd = accumulated.count - silentFrames * frameSize
                            let speechSamples = trimEnd > 0 ? Array(accumulated[0..<min(trimEnd, accumulated.count)]) : accumulated
                            let duration = Double(speechSamples.count) / Double(sampleRate)
                            result.append(SpeechSegment(
                                samples: speechSamples,
                                startSample: speechStart,
                                duration: duration
                            ))
                            fputs("[EnergyVAD] 输出语音段: \(String(format: "%.2f", duration))s\n", stderr)
                        } else {
                            fputs("[EnergyVAD] 丢弃短语音段 (\(accumulated.count) 样本 < 最小 \(minSpeechSamples))\n", stderr)
                        }
                        accumulated = []
                    }
                }
            }

            totalSamples += frame.count
        }

        return result
    }

    func flush() -> [SpeechSegment] {
        guard inSpeech && !accumulated.isEmpty else { return [] }
        inSpeech = false
        let duration = Double(accumulated.count) / Double(sampleRate)
        if accumulated.count >= minSpeechSamples {
            let seg = SpeechSegment(
                samples: accumulated,
                startSample: speechStart,
                duration: duration
            )
            accumulated = []
            fputs("[EnergyVAD] flush 输出语音段: \(String(format: "%.2f", duration))s\n", stderr)
            return [seg]
        }
        accumulated = []
        return []
    }

    func reset() {
        accumulated = []
        silentFrames = 0
        totalSamples = 0
        speechStart = 0
        inSpeech = false
    }

    private func computeRMS(_ frame: [Float]) -> Float {
        guard !frame.isEmpty else { return 0 }
        let sumSq = frame.reduce(Float(0)) { $0 + $1 * $1 }
        return (sumSq / Float(frame.count)).squareRoot()
    }
}

// MARK: - VoiceActivityDetector 工厂

/// VoiceActivityDetector 自动选择最佳 VAD 实现
/// 优先 silero-vad，fallback 能量阈值
class VoiceActivityDetector {

    private var impl: VoiceActivityDetectorProtocol
    private(set) var backendName: String

    /// 初始化
    /// - Parameters:
    ///   - sileroModelPath: silero_vad.onnx 路径（nil 则使用默认路径）
    ///   - energyThreshold: 能量阈值 fallback（默认 0.01）
    init(sileroModelPath: String? = nil, energyThreshold: Float = 0.01) {
        // 确定模型路径
        let modelPath = sileroModelPath ?? Self.defaultSileroModelPath()

        if let silero = SileroVAD(modelPath: modelPath) {
            impl = silero
            backendName = "silero-vad"
            fputs("[VAD] 使用 silero-vad 后端\n", stderr)
        } else {
            impl = EnergyVAD(threshold: energyThreshold)
            backendName = "energy-threshold"
            fputs("[VAD] 回退到能量阈值 VAD（未找到 silero-vad 模型）\n", stderr)
        }
    }

    static func defaultSileroModelPath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.openclaw/workspace-satoshi/VoiceInput/Resources/models/silero-vad/silero_vad.onnx"
    }

    var isSpeaking: Bool { impl.isSpeaking }

    func acceptSamples(_ samples: [Float]) -> [SpeechSegment] {
        impl.acceptSamples(samples)
    }

    func flush() -> [SpeechSegment] {
        impl.flush()
    }

    func reset() {
        impl.reset()
    }
}

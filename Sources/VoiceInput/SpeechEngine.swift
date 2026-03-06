// Sources/VoiceInput/SpeechEngine.swift
// SenseVoice 识别引擎封装
// Copyright (c) 2026 urDAO Investment

import Foundation
import AVFoundation

/// SpeechEngine 封装 sherpa-onnx SenseVoice 离线识别
/// 支持中英日韩粤五语混识
class SpeechEngine {
    private var recognizer: SherpaOnnxOfflineRecognizer?
    private var modelPath: String = ""
    private var tokensPath: String = ""
    private var isLoaded: Bool = false

    // MARK: - 初始化

    init() {}

    // MARK: - 模型加载

    /// 加载 SenseVoice 模型
    /// - Parameters:
    ///   - modelPath: model.int8.onnx 路径
    ///   - tokensPath: tokens.txt 路径
    ///   - numThreads: 推理线程数（默认4）
    /// - Returns: 是否加载成功
    @discardableResult
    func loadModel(modelPath: String, tokensPath: String, numThreads: Int = 4) -> Bool {
        self.modelPath = modelPath
        self.tokensPath = tokensPath

        // 验证文件存在
        guard FileManager.default.fileExists(atPath: modelPath) else {
            fputs("[SpeechEngine] ERROR: model not found: \(modelPath)\n", stderr)
            return false
        }
        guard FileManager.default.fileExists(atPath: tokensPath) else {
            fputs("[SpeechEngine] ERROR: tokens not found: \(tokensPath)\n", stderr)
            return false
        }

        let t0 = Date()

        // SenseVoice 模型配置
        let senseVoiceConfig = sherpaOnnxOfflineSenseVoiceModelConfig(
            model: modelPath,
            language: "auto",            // 自动语言检测
            useInverseTextNormalization: true   // ITN: 数字/标点规范化
        )

        let modelConfig = sherpaOnnxOfflineModelConfig(
            tokens: tokensPath,
            numThreads: numThreads,
            provider: "cpu",
            debug: 0,
            senseVoice: senseVoiceConfig
        )

        let featConfig = sherpaOnnxFeatureConfig(
            sampleRate: 16000,
            featureDim: 80
        )

        var config = sherpaOnnxOfflineRecognizerConfig(
            featConfig: featConfig,
            modelConfig: modelConfig
        )

        let recognizerObj = SherpaOnnxOfflineRecognizer(config: &config)
        self.recognizer = recognizerObj
        self.isLoaded = true

        let elapsed = Date().timeIntervalSince(t0)
        fputs("[SpeechEngine] Model loaded in \(String(format: "%.3f", elapsed))s\n", stderr)
        fputs("[SpeechEngine] Model: \((modelPath as NSString).lastPathComponent)\n", stderr)

        return true
    }

    // MARK: - 识别接口

    /// 识别 Float32 音频数据
    /// - Parameters:
    ///   - audioData: PCM Float32 样本，范围 [-1.0, 1.0]
    ///   - sampleRate: 采样率（默认 16000）
    /// - Returns: 识别结果文本，失败返回空字符串
    func recognize(audioData: [Float], sampleRate: Int = 16000) -> RecognitionResult {
        guard let rec = recognizer, isLoaded else {
            fputs("[SpeechEngine] ERROR: model not loaded\n", stderr)
            return RecognitionResult(text: "", lang: "", emotion: "", event: "")
        }

        guard !audioData.isEmpty else {
            return RecognitionResult(text: "", lang: "", emotion: "", event: "")
        }

        let t0 = Date()
        let result = rec.decode(samples: audioData, sampleRate: sampleRate)
        let elapsed = Date().timeIntervalSince(t0)

        let duration = Double(audioData.count) / Double(sampleRate)
        let rtf = elapsed / duration

        fputs("[SpeechEngine] Recognized \(String(format: "%.2f", duration))s audio "
            + "in \(String(format: "%.3f", elapsed))s (RTF=\(String(format: "%.3f", rtf)))\n",
            stderr)

        return RecognitionResult(
            text: result.text,
            lang: result.lang,
            emotion: result.emotion,
            event: result.event
        )
    }

    /// 识别 WAV 文件
    /// - Parameter fileURL: WAV 文件路径
    /// - Returns: 识别结果
    func recognize(fileURL: URL) -> RecognitionResult {
        do {
            let audioFile = try AVAudioFile(forReading: fileURL)
            let format = audioFile.processingFormat

            // 需要 16kHz 单声道 Float32
            let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16000,
                channels: 1,
                interleaved: false
            )!

            let frameCount = AVAudioFrameCount(audioFile.length)

            // 如果格式不匹配，需要转换
            if format.sampleRate == 16000 && format.channelCount == 1
                && format.commonFormat == .pcmFormatFloat32 {
                // 直接读取
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
                try audioFile.read(into: buffer)
                let samples = Array(
                    UnsafeBufferPointer(
                        start: buffer.floatChannelData![0],
                        count: Int(buffer.frameLength)
                    )
                )
                return recognize(audioData: samples)
            } else {
                // 需要格式转换
                fputs("[SpeechEngine] Converting audio format: \(format) -> 16kHz mono float32\n",
                    stderr)

                guard let converter = AVAudioConverter(from: format, to: targetFormat) else {
                    fputs("[SpeechEngine] ERROR: Cannot create audio converter\n", stderr)
                    return RecognitionResult(text: "", lang: "", emotion: "", event: "")
                }

                let inputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
                try audioFile.read(into: inputBuffer)

                // 估算输出帧数
                let ratio = 16000.0 / format.sampleRate
                let outputFrameCount = AVAudioFrameCount(Double(frameCount) * ratio + 1)
                let outputBuffer = AVAudioPCMBuffer(
                    pcmFormat: targetFormat,
                    frameCapacity: outputFrameCount
                )!

                var inputConsumed = false
                let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                    if inputConsumed {
                        outStatus.pointee = .endOfStream
                        return nil
                    }
                    outStatus.pointee = .haveData
                    inputConsumed = true
                    return inputBuffer
                }

                var error: NSError?
                converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)

                if let err = error {
                    fputs("[SpeechEngine] ERROR: Conversion failed: \(err)\n", stderr)
                    return RecognitionResult(text: "", lang: "", emotion: "", event: "")
                }

                let samples = Array(
                    UnsafeBufferPointer(
                        start: outputBuffer.floatChannelData![0],
                        count: Int(outputBuffer.frameLength)
                    )
                )
                return recognize(audioData: samples)
            }
        } catch {
            fputs("[SpeechEngine] ERROR: Cannot read audio file \(fileURL): \(error)\n", stderr)
            return RecognitionResult(text: "", lang: "", emotion: "", event: "")
        }
    }

    // MARK: - 状态

    var loaded: Bool { isLoaded }
}

// MARK: - 识别结果

struct RecognitionResult {
    let text: String
    let lang: String       // SenseVoice 检测到的语言 (zh/en/ja/ko/yue)
    let emotion: String    // 情绪标签
    let event: String      // 事件标签 (音乐/掌声等)

    var isEmpty: Bool { text.isEmpty }

    var description: String {
        var parts = [String]()
        if !text.isEmpty { parts.append("text: \"\(text)\"") }
        if !lang.isEmpty { parts.append("lang: \(lang)") }
        if !emotion.isEmpty { parts.append("emotion: \(emotion)") }
        if !event.isEmpty { parts.append("event: \(event)") }
        return parts.joined(separator: ", ")
    }
}

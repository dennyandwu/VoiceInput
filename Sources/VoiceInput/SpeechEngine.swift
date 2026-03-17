// Sources/VoiceInput/SpeechEngine.swift
// SenseVoice 识别引擎封装
// Copyright (c) 2026 urDAO Investment

import Foundation
import AVFoundation
import os

/// SpeechEngine 封装 sherpa-onnx SenseVoice 离线识别
/// 支持中英日韩粤五语混识
class SpeechEngine {

    static let logger = Logger(subsystem: "com.urdao.voiceinput", category: "SpeechEngine")

    private var recognizer: SherpaOnnxOfflineRecognizer?
    private var whisperRecognizer: SherpaOnnxOfflineRecognizer?
    private var modelPath: String = ""
    private var tokensPath: String = ""
    private var isLoaded: Bool = false
    private var whisperLoaded: Bool = false

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
            Self.logger.error("model not found: \(modelPath)")
            return false
        }
        guard FileManager.default.fileExists(atPath: tokensPath) else {
            Self.logger.error("tokens not found: \(tokensPath)")
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
        Self.logger.info("Model loaded in \(String(format: "%.3f", elapsed))s")
        Self.logger.info("Model: \((modelPath as NSString).lastPathComponent)")

        return true
    }

    // MARK: - Whisper 模型加载

    /// 加载 Whisper 模型（用于英文识别增强）
    /// - Parameters:
    ///   - encoderPath: whisper-encoder.onnx 路径
    ///   - decoderPath: whisper-decoder.onnx 路径
    ///   - tokensPath: tokens.txt 路径
    ///   - numThreads: 推理线程数
    /// - Returns: 是否加载成功
    @discardableResult
    func loadWhisper(encoderPath: String, decoderPath: String, tokensPath: String, numThreads: Int = 4) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: encoderPath) else {
            Self.logger.info("Whisper encoder not found: \(encoderPath)")
            return false
        }
        guard fm.fileExists(atPath: decoderPath) else {
            Self.logger.info("Whisper decoder not found: \(decoderPath)")
            return false
        }
        guard fm.fileExists(atPath: tokensPath) else {
            Self.logger.info("Whisper tokens not found: \(tokensPath)")
            return false
        }

        let t0 = Date()

        let whisperConfig = sherpaOnnxOfflineWhisperModelConfig(
            encoder: encoderPath,
            decoder: decoderPath,
            language: "en",          // 强制英文
            task: "transcribe"
        )

        let modelConfig = sherpaOnnxOfflineModelConfig(
            tokens: tokensPath,
            whisper: whisperConfig,
            numThreads: numThreads,
            provider: "cpu",
            debug: 0
        )

        let featConfig = sherpaOnnxFeatureConfig(
            sampleRate: 16000,
            featureDim: 80
        )

        var config = sherpaOnnxOfflineRecognizerConfig(
            featConfig: featConfig,
            modelConfig: modelConfig
        )

        let rec = SherpaOnnxOfflineRecognizer(config: &config)
        self.whisperRecognizer = rec
        self.whisperLoaded = true

        let elapsed = Date().timeIntervalSince(t0)
        Self.logger.info("Whisper loaded in \(String(format: "%.3f", elapsed))s")
        Self.logger.info("Whisper encoder: \((encoderPath as NSString).lastPathComponent)")

        return true
    }

    /// Whisper 是否已加载
    var hasWhisper: Bool { whisperLoaded }

    /// 用 Whisper 识别英文音频
    func recognizeWithWhisper(audioData: [Float], sampleRate: Int = 16000) -> RecognitionResult {
        guard let rec = whisperRecognizer, whisperLoaded else {
            Self.logger.info("Whisper not loaded, falling back to SenseVoice")
            return recognize(audioData: audioData, sampleRate: sampleRate)
        }

        guard !audioData.isEmpty else {
            return RecognitionResult(text: "", lang: "en", emotion: "", event: "")
        }

        let t0 = Date()
        let result = rec.decode(samples: audioData, sampleRate: sampleRate)
        let elapsed = Date().timeIntervalSince(t0)

        let duration = Double(audioData.count) / Double(sampleRate)
        Self.logger.info("Whisper recognized \(String(format: "%.2f", duration))s in \(String(format: "%.3f", elapsed))s (RTF=\(String(format: "%.3f", elapsed/duration)))")

        return RecognitionResult(
            text: result.text,
            lang: "en",
            emotion: "",
            event: ""
        )
    }

    // MARK: - 识别接口

    /// 识别 Float32 音频数据
    /// - Parameters:
    ///   - audioData: PCM Float32 样本，范围 [-1.0, 1.0]
    ///   - sampleRate: 采样率（默认 16000）
    /// - Returns: 识别结果文本，失败返回空字符串
    func recognize(audioData: [Float], sampleRate: Int = 16000) -> RecognitionResult {
        guard let rec = recognizer, isLoaded else {
            Self.logger.error("model not loaded")
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

        Self.logger.info("Recognized \(String(format: "%.2f", duration))s audio in \(String(format: "%.3f", elapsed))s (RTF=\(String(format: "%.3f", rtf)))")

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
                Self.logger.info("Converting audio format: \(format) -> 16kHz mono float32")

                guard let converter = AVAudioConverter(from: format, to: targetFormat) else {
                    Self.logger.error("Cannot create audio converter")
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
                    Self.logger.error("Conversion failed: \(err)")
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
            Self.logger.error("Cannot read audio file \(fileURL): \(error)")
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

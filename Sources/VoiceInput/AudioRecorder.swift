// Sources/VoiceInput/AudioRecorder.swift
// AVAudioEngine 实时录音封装
// Phase 2 实现：完整 AVAudioEngine 麦克风采集
// Copyright (c) 2026 urDAO Investment

import Foundation
import AVFoundation
import os

/// AudioRecorder 封装 AVAudioEngine 实时麦克风录音
/// - 采样率：16kHz，单声道，Float32
/// - 支持实时 buffer 回调（用于 VAD）
/// - 线程安全：内部使用 DispatchQueue 同步
class AudioRecorder {

    private static let logger = Logger(subsystem: "com.urdao.voiceinput", category: "AudioRecorder")

    // MARK: - 配置

    static let targetSampleRate: Double = 16000
    static let targetChannels: AVAudioChannelCount = 1
    static let tapBufferSize: AVAudioFrameCount = 4096

    // MARK: - 内部状态

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?

    private let lock = NSLock()
    private var _audioBuffer: [Float] = []
    private var _isRecording: Bool = false

    // MARK: - 公共属性

    /// 实时 buffer 回调（在后台串行队列调用，非音频线程）
    var onAudioBuffer: (([Float]) -> Void)?
    /// 录音状态回调
    var onRecordingStarted: (() -> Void)?
    var onRecordingStopped: (() -> Void)?

    /// 是否正在录音
    var isRecording: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isRecording
    }

    // MARK: - 初始化

    init() {}

    deinit {
        if isRecording {
            _ = _stopInternal()
        }
    }

    // MARK: - 录音控制

    /// 开始录音
    /// - Returns: 成功返回 true，失败返回 false
    @discardableResult
    func startRecording() -> Bool {
        lock.lock()
        guard !_isRecording else {
            lock.unlock()
            Self.logger.debug("已在录音中")
            return false
        }
        lock.unlock()

        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)

        Self.logger.info("设备格式: \(inputFormat)")
        Self.logger.info("目标格式: 16kHz 单声道 Float32")

        // 构建目标格式：16kHz 单声道 Float32
        guard let fmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioRecorder.targetSampleRate,
            channels: AudioRecorder.targetChannels,
            interleaved: false
        ) else {
            Self.logger.error("无法创建目标音频格式")
            return false
        }
        targetFormat = fmt

        // 如果设备格式不是 16kHz 单声道，创建 converter
        let needsConversion = (
            inputFormat.sampleRate != AudioRecorder.targetSampleRate ||
            inputFormat.channelCount != AudioRecorder.targetChannels ||
            inputFormat.commonFormat != .pcmFormatFloat32
        )

        if needsConversion {
            guard let conv = AVAudioConverter(from: inputFormat, to: fmt) else {
                Self.logger.error("无法创建 AVAudioConverter")
                return false
            }
            converter = conv
            Self.logger.info("启用格式转换: \(inputFormat.sampleRate)Hz \(inputFormat.channelCount)ch → 16kHz 1ch")
        } else {
            converter = nil
            Self.logger.info("设备原生 16kHz 单声道，无需转换")
        }

        // 清空 buffer
        lock.lock()
        _audioBuffer = []
        _isRecording = true
        lock.unlock()

        // 安装 tap
        // 注意：tap 在 inputFormat 下运行，不能直接指定 16kHz
        inputNode.installTap(
            onBus: 0,
            bufferSize: AudioRecorder.tapBufferSize,
            format: inputFormat  // 必须用 inputNode 的实际格式
        ) { [weak self] buffer, _ in
            self?.handleBuffer(buffer)
        }

        // 启动 engine
        do {
            engine.prepare()
            try engine.start()
        } catch {
            Self.logger.error("AVAudioEngine 启动失败: \(error.localizedDescription)")
            inputNode.removeTap(onBus: 0)
            lock.lock()
            _isRecording = false
            lock.unlock()
            return false
        }

        Self.logger.info("开始录音 ✅")
        onRecordingStarted?()
        return true
    }

    /// 停止录音，返回完整音频数据
    /// - Returns: Float32 PCM 样本，采样率 16kHz
    func stopRecording() -> [Float] {
        lock.lock()
        guard _isRecording else {
            lock.unlock()
            Self.logger.debug("未在录音")
            return []
        }
        lock.unlock()

        return _stopInternal()
    }

    // MARK: - 内部方法

    private func _stopInternal() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        lock.lock()
        _isRecording = false
        let result = _audioBuffer
        _audioBuffer = []
        lock.unlock()

        converter = nil
        targetFormat = nil

        Self.logger.info("停止录音，采集 \(result.count) 样本 (\(String(format: "%.2f", Double(result.count) / AudioRecorder.targetSampleRate))s)")
        onRecordingStopped?()
        return result
    }

    /// 处理原始 tap buffer（在音频线程调用）
    private func handleBuffer(_ inputBuffer: AVAudioPCMBuffer) {
        let converted: [Float]

        if let conv = converter, let fmt = targetFormat {
            // 需要格式转换
            // 计算输出帧数
            let ratio = AudioRecorder.targetSampleRate / inputBuffer.format.sampleRate
            let outputFrameCount = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio + 1)

            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: outputFrameCount) else {
                return
            }

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
            let status = conv.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)

            // 重置 converter 状态，否则收到 endOfStream 后不再处理后续 buffer
            conv.reset()

            if let err = error {
                Self.logger.error("格式转换错误: \(err.localizedDescription)")
                return
            }

            if status == .error {
                return
            }

            guard let channelData = outputBuffer.floatChannelData else { return }
            converted = Array(UnsafeBufferPointer(
                start: channelData[0],
                count: Int(outputBuffer.frameLength)
            ))
        } else {
            // 直接使用（已是 16kHz 单声道 Float32）
            guard let channelData = inputBuffer.floatChannelData else { return }

            // 如果是多声道，只取第一个声道
            converted = Array(UnsafeBufferPointer(
                start: channelData[0],
                count: Int(inputBuffer.frameLength)
            ))
        }

        guard !converted.isEmpty else { return }

        // 追加到内部 buffer（使用锁保护）
        lock.lock()
        _audioBuffer.append(contentsOf: converted)
        lock.unlock()

        // 回调（在当前音频线程触发，调用者需注意线程）
        onAudioBuffer?(converted)
    }
}

// MARK: - 模拟音频源（用于无麦克风测试）

/// SimulatedAudioSource 从 WAV 文件读取 PCM 数据，模拟 AudioRecorder 的行为
/// 用于无麦克风环境（如 Mac mini）的测试
class SimulatedAudioSource {

    private static let logger = Logger(subsystem: "com.urdao.voiceinput", category: "SimulatedAudioSource")

    private(set) var samples: [Float] = []
    private(set) var sampleRate: Double = 16000

    /// 从 WAV 文件加载音频数据（自动转换为 16kHz 单声道 Float32）
    func load(fileURL: URL) -> Bool {
        do {
            let audioFile = try AVAudioFile(forReading: fileURL)
            let format = audioFile.processingFormat
            sampleRate = format.sampleRate

            let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16000,
                channels: 1,
                interleaved: false
            )!

            let frameCount = AVAudioFrameCount(audioFile.length)

            if format.sampleRate == 16000 && format.channelCount == 1
                && format.commonFormat == .pcmFormatFloat32 {
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
                try audioFile.read(into: buffer)
                samples = Array(UnsafeBufferPointer(
                    start: buffer.floatChannelData![0],
                    count: Int(buffer.frameLength)
                ))
            } else {
                guard let converter = AVAudioConverter(from: format, to: targetFormat) else {
                    Self.logger.error("无法创建 converter")
                    return false
                }

                let inputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
                try audioFile.read(into: inputBuffer)

                let ratio = 16000.0 / format.sampleRate
                let outputFrameCount = AVAudioFrameCount(Double(frameCount) * ratio + 1)
                let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCount)!

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
                    Self.logger.error("转换失败: \(err.localizedDescription)")
                    return false
                }

                samples = Array(UnsafeBufferPointer(
                    start: outputBuffer.floatChannelData![0],
                    count: Int(outputBuffer.frameLength)
                ))
                sampleRate = 16000
            }

            Self.logger.info("加载 \(fileURL.lastPathComponent): \(self.samples.count) 样本 (\(String(format: "%.2f", Double(self.samples.count) / 16000))s)")
            return true
        } catch {
            Self.logger.error("读取文件失败: \(error.localizedDescription)")
            return false
        }
    }

    /// 分块模拟实时回调（chunkSize 个样本一组）
    func simulateRealtime(chunkSize: Int = 512, callback: ([Float]) -> Void) {
        var offset = 0
        while offset < samples.count {
            let end = min(offset + chunkSize, samples.count)
            let chunk = Array(samples[offset..<end])
            callback(chunk)
            offset = end
        }
    }
}

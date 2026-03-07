// sensevoice-transcribe.swift — 最小化 SenseVoice CLI 转录工具
// 兼容 whisper-cli 输出格式，用于替换 OpenClaw STT 后端
// Copyright (c) 2026 urDAO Investment

import Foundation
import AVFoundation

@main
struct SenseVoiceCLI {
    static func main() {
        run()
    }
}

func run() {
guard CommandLine.arguments.count >= 2 else {
    fputs("Usage: sensevoice-transcribe [options] <audio_file>\n", stderr)
    fputs("Options:\n", stderr)
    fputs("  -m <model>     Model path (default: bundled int8)\n", stderr)
    fputs("  -otxt          Output to .txt file\n", stderr)
    fputs("  -of <base>     Output file base name\n", stderr)
    fputs("  -l <lang>      Language: auto/zh/en (default: auto)\n", stderr)
    fputs("  -t <threads>   Number of threads (default: 4)\n", stderr)
    exit(1)
}

// ─── 解析参数 ───
var modelPath = ""
var tokensPath = ""
var wavPath = ""
var outputTxt = false
var outputBase = ""
var language = "auto"
var numThreads = 4

var i = 1
while i < CommandLine.arguments.count {
    let arg = CommandLine.arguments[i]
    switch arg {
    case "-m":
        i += 1; modelPath = CommandLine.arguments[i]
    case "-otxt", "--output-txt":
        outputTxt = true
    case "-of", "--output-file":
        i += 1; outputBase = CommandLine.arguments[i]
    case "-l", "--language":
        i += 1; language = CommandLine.arguments[i]
    case "-t", "--threads":
        i += 1; numThreads = Int(CommandLine.arguments[i]) ?? 4
    case "-f", "--file":
        i += 1; wavPath = CommandLine.arguments[i]
    case "-nt", "--no-timestamps", "-pp", "-pc":
        break  // 忽略 whisper-cli 特有参数
    default:
        if !arg.hasPrefix("-") && wavPath.isEmpty {
            wavPath = arg
        }
    }
    i += 1
}

// ─── 自动查找模型 ───
let fm = FileManager.default
let execDir = (CommandLine.arguments[0] as NSString).deletingLastPathComponent

func findModel() -> (model: String, tokens: String)? {
    // 1. 用户指定的 -m 参数
    if !modelPath.isEmpty {
        if fm.fileExists(atPath: modelPath) && modelPath.hasSuffix(".onnx") {
            let dir = (modelPath as NSString).deletingLastPathComponent
            let tokens = (dir as NSString).appendingPathComponent("tokens.txt")
            if fm.fileExists(atPath: tokens) { return (modelPath, tokens) }
        }
        // -m 可能指向目录
        let int8 = (modelPath as NSString).appendingPathComponent("model.int8.onnx")
        let fp32 = (modelPath as NSString).appendingPathComponent("model.onnx")
        let tokens = (modelPath as NSString).appendingPathComponent("tokens.txt")
        if fm.fileExists(atPath: int8) && fm.fileExists(atPath: tokens) { return (int8, tokens) }
        if fm.fileExists(atPath: fp32) && fm.fileExists(atPath: tokens) { return (fp32, tokens) }
    }

    // 2. SENSEVOICE_MODEL 环境变量
    if let envModel = ProcessInfo.processInfo.environment["SENSEVOICE_MODEL"],
       fm.fileExists(atPath: envModel) {
        let dir = (envModel as NSString).deletingLastPathComponent
        let tokens = (dir as NSString).appendingPathComponent("tokens.txt")
        if fm.fileExists(atPath: tokens) { return (envModel, tokens) }
    }

    // 3. VoiceInput 默认路径
    let defaultPaths = [
        "/Users/0xfg_bot/.openclaw/workspace-satoshi/VoiceInput/Resources/models/sense-voice",
        "\(NSHomeDirectory())/Library/Application Support/VoiceInput/models/sense-voice",
    ]
    for dir in defaultPaths {
        let int8 = (dir as NSString).appendingPathComponent("model.int8.onnx")
        let tokens = (dir as NSString).appendingPathComponent("tokens.txt")
        if fm.fileExists(atPath: int8) && fm.fileExists(atPath: tokens) {
            return (int8, tokens)
        }
    }

    return nil
}

guard let modelInfo = findModel() else {
    fputs("Error: SenseVoice model not found. Use -m <path> or set SENSEVOICE_MODEL.\n", stderr)
    exit(1)
}

guard !wavPath.isEmpty && fm.fileExists(atPath: wavPath) else {
    fputs("Error: audio file not found: \(wavPath)\n", stderr)
    exit(1)
}

// ─── 加载模型 ───
let t0 = Date()

let senseVoiceConfig = sherpaOnnxOfflineSenseVoiceModelConfig(
    model: modelInfo.model,
    language: language,
    useInverseTextNormalization: true
)

let modelConfig = sherpaOnnxOfflineModelConfig(
    tokens: modelInfo.tokens,
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

let recognizer = SherpaOnnxOfflineRecognizer(config: &config)

let loadTime = Date().timeIntervalSince(t0)
fputs("[sensevoice] model loaded in \(String(format: "%.3f", loadTime))s (\((modelInfo.model as NSString).lastPathComponent))\n", stderr)

// ─── 读取音频 ───
let fileURL = URL(fileURLWithPath: wavPath)

func readAudioSamples(from url: URL) -> [Float]? {
    guard let audioFile = try? AVAudioFile(forReading: url) else { return nil }
    
    let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    let srcFormat = audioFile.processingFormat
    let frameCount = AVAudioFrameCount(audioFile.length)
    
    if srcFormat.sampleRate == 16000 && srcFormat.channelCount == 1 {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) else { return nil }
        try? audioFile.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }
    
    // 需要转换
    guard let srcBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frameCount) else { return nil }
    try? audioFile.read(into: srcBuffer)
    
    guard let converter = AVAudioConverter(from: srcFormat, to: targetFormat) else { return nil }
    
    let ratio = 16000.0 / srcFormat.sampleRate
    let outFrames = AVAudioFrameCount(Double(srcBuffer.frameLength) * ratio) + 1024
    guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outFrames) else { return nil }
    
    var consumed = false
    converter.convert(to: outBuffer, error: nil) { _, outStatus in
        if consumed { outStatus.pointee = .endOfStream; return nil }
        consumed = true
        outStatus.pointee = .haveData
        return srcBuffer
    }
    converter.reset()
    
    return Array(UnsafeBufferPointer(start: outBuffer.floatChannelData![0], count: Int(outBuffer.frameLength)))
}

guard let samples = readAudioSamples(from: fileURL), !samples.isEmpty else {
    fputs("Error: cannot read audio from \(wavPath)\n", stderr)
    exit(1)
}

let duration = Double(samples.count) / 16000.0
fputs("[sensevoice] audio: \(String(format: "%.2f", duration))s, \(samples.count) samples\n", stderr)

// ─── 识别 ───
let t1 = Date()
let result = recognizer.decode(samples: samples, sampleRate: 16000)
let recTime = Date().timeIntervalSince(t1)

fputs("[sensevoice] recognized in \(String(format: "%.3f", recTime))s (RTF=\(String(format: "%.4f", recTime/max(duration, 0.001))))\n", stderr)

// 清理 SenseVoice tokens: <|zh|><|NEUTRAL|><|Speech|><|woitn|>
let cleaned = result.text
    .replacingOccurrences(of: "<\\|[^|]+\\|>", with: "", options: .regularExpression)
    .trimmingCharacters(in: .whitespacesAndNewlines)

// ─── 输出 ───
if outputTxt && !outputBase.isEmpty {
    try? cleaned.write(toFile: "\(outputBase).txt", atomically: true, encoding: .utf8)
}

// 总是输出到 stdout（兼容 OpenClaw 的 stdout 捕获）
print(cleaned)
} // end run()

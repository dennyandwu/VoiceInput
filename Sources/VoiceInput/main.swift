// Sources/VoiceInput/main.swift
// VoiceInput 入口 - 支持 CLI 模式和 GUI（MenuBar）模式
// Phase 4: MenuBar GUI + CLI 保留
// Copyright (c) 2026 urDAO Investment

import Foundation
import AppKit

// MARK: - 运行模式检测

// 如果有 CLI 参数（--test, --mic, --ptt, --simulate 等），走 CLI 模式
// 如果无参数，启动 GUI MenuBar 模式

let cliArgs = CommandLine.arguments

if cliArgs.count > 1 {
    // ═══════════════════════════════════════════════════════
    // CLI 模式（保留原有逻辑）
    // ═══════════════════════════════════════════════════════
    runCLI()
} else {
    // ═══════════════════════════════════════════════════════
    // GUI 模式 — 启动 MenuBar App
    // ═══════════════════════════════════════════════════════
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}

// MARK: - CLI 入口

func runCLI() {
    let args = CommandLine.arguments

    // 解析 flag 参数
    let parsedArgs = parseArgs(Array(args.dropFirst()))
    let useVAD = parsedArgs["--no-vad"] == nil
    let vadModelPath = parsedArgs["--vad-model"]

    switch args[1] {
    case "--help", "-h":
        printUsage()

    case "--test":
        runTest()

    case "--simulate":
        let wavPath: String
        if args.count >= 3 && !args[2].hasPrefix("--") {
            wavPath = args[2]
        } else if let v = parsedArgs["--simulate"], !v.isEmpty {
            wavPath = v
        } else {
            fputs("ERROR: --simulate 需要指定 wav 文件路径\n", stderr)
            fputs("用法: VoiceInput --simulate <audio.wav>\n", stderr)
            exit(1)
        }
        runSimulate(wavPath: wavPath, useVAD: useVAD, vadModelPath: vadModelPath)

    case "--mic":
        let duration: Double
        if let durStr = parsedArgs["--duration"], let durVal = Double(durStr) {
            duration = durVal
        } else {
            duration = 5.0
        }
        runMic(duration: duration, useVAD: useVAD, vadModelPath: vadModelPath)

    case "--ptt":
        runPTT(useVAD: useVAD, vadModelPath: vadModelPath)

    case "--model":
        guard args.count >= 4 else {
            fputs("ERROR: --model 需要 <model_dir> <audio.wav>\n", stderr)
            exit(1)
        }
        recognizeFile(path: args[3], modelDir: args[2])

    default:
        // 直接识别文件
        let wavPath = args[1]
        guard FileManager.default.fileExists(atPath: wavPath) else {
            fputs("ERROR: 文件不存在: \(wavPath)\n", stderr)
            printUsage()
            exit(1)
        }
        recognizeFile(path: wavPath)
    }
}

// MARK: - 路径工具

func defaultModelDir() -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return "\(home)/.openclaw/workspace-satoshi/VoiceInput/Resources/models/sense-voice"
}

func defaultSileroModelPath() -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return "\(home)/.openclaw/workspace-satoshi/VoiceInput/Resources/models/silero-vad/silero_vad.onnx"
}

func getModelPaths(modelDir: String? = nil) -> (model: String, tokens: String) {
    let dir = modelDir
        ?? ProcessInfo.processInfo.environment["SENSE_VOICE_MODEL_DIR"]
        ?? defaultModelDir()
    return (
        model: "\(dir)/model.int8.onnx",
        tokens: "\(dir)/tokens.txt"
    )
}

// MARK: - 用法

func printUsage() {
    print("""
    VoiceInput — 语音识别工具（支持 CLI 和 MenuBar GUI 两种模式）

    GUI 模式（无参数）:
      VoiceInput                               启动 MenuBar 常驻 app

    CLI 模式:
      VoiceInput <audio.wav>                   识别单个音频文件
      VoiceInput --test                        运行内置多语言测试
      VoiceInput --simulate <audio.wav>        模拟麦克风输入（无麦克风测试完整 Pipeline）
      VoiceInput --mic                         麦克风录音 5 秒后识别
      VoiceInput --mic --duration <秒>         麦克风录音指定时长后识别
      VoiceInput --ptt                         Push-to-Talk 模式（Enter 开始，Enter 停止）
      VoiceInput --model <model_dir> <audio>   指定模型目录识别文件

    选项:
      --no-vad                                 禁用 VAD（--mic/--simulate/--ptt 有效）
      --vad-model <path>                       指定 silero-vad 模型路径

    环境变量:
      SENSE_VOICE_MODEL_DIR   SenseVoice 模型目录路径

    默认模型路径:
      SenseVoice: ~/workspace-satoshi/VoiceInput/Resources/models/sense-voice/
      Silero VAD: ~/workspace-satoshi/VoiceInput/Resources/models/silero-vad/silero_vad.onnx
    """)
}

// MARK: - Phase 1 测试

func runTest() {
    print("=== VoiceInput 多语言识别测试 ===\n")

    let paths = getModelPaths()
    print("模型路径: \(paths.model)")
    print("Tokens:   \(paths.tokens)\n")

    let engine = SpeechEngine()

    print("⏳ 加载模型...")
    let loaded = engine.loadModel(
        modelPath: paths.model,
        tokensPath: paths.tokens,
        numThreads: 4
    )

    guard loaded else {
        print("❌ 模型加载失败！")
        exit(1)
    }
    print("✅ 模型加载成功\n")

    let modelDir = (paths.model as NSString).deletingLastPathComponent
    let testWavsDir = "\(modelDir)/test_wavs"

    let testFiles: [(lang: String, file: String)] = [
        ("中文",     "zh.wav"),
        ("English",  "en.wav"),
        ("日本語",   "ja.wav"),
        ("한국어",   "ko.wav"),
        ("粤語",     "yue.wav"),
    ]

    var successCount = 0
    var failCount = 0

    print("--- 多语言识别测试 ---\n")
    for (lang, filename) in testFiles {
        let wavPath = "\(testWavsDir)/\(filename)"
        let fileURL = URL(fileURLWithPath: wavPath)

        guard FileManager.default.fileExists(atPath: wavPath) else {
            print("[\(lang)] ⚠️  跳过（文件不存在）: \(wavPath)")
            continue
        }

        let t0 = Date()
        let result = engine.recognize(fileURL: fileURL)
        let elapsed = Date().timeIntervalSince(t0)

        if result.isEmpty {
            print("[\(lang)] ❌ 识别失败")
            failCount += 1
        } else {
            print("[\(lang)] ✅ \"\(result.text)\"")
            if !result.lang.isEmpty {
                print("         lang=\(result.lang), emotion=\(result.emotion), event=\(result.event)")
            }
            print("         耗时: \(String(format: "%.3f", elapsed))s")
            successCount += 1
        }
        print()
    }

    print("--- 测试结果 ---")
    print("成功: \(successCount), 失败: \(failCount)")
    print("\n✅ 测试完成！")

    exit(failCount > 0 ? 1 : 0)
}

// MARK: - 文件识别

func recognizeFile(path: String, modelDir: String? = nil) {
    let paths = getModelPaths(modelDir: modelDir)
    let engine = SpeechEngine()

    let loaded = engine.loadModel(
        modelPath: paths.model,
        tokensPath: paths.tokens,
        numThreads: 4
    )

    guard loaded else {
        fputs("ERROR: 模型加载失败\n", stderr)
        exit(1)
    }

    let fileURL = URL(fileURLWithPath: path)
    let result = engine.recognize(fileURL: fileURL)

    if result.isEmpty {
        fputs("ERROR: 识别失败或无结果\n", stderr)
        exit(1)
    }

    print(result.text)
    fputs("lang=\(result.lang) emotion=\(result.emotion) event=\(result.event)\n", stderr)
}

// MARK: - 模拟模式（Phase 2）

func runSimulate(wavPath: String, useVAD: Bool = true, vadModelPath: String? = nil) {
    print("=== VoiceInput 模拟麦克风测试 ===\n")

    guard FileManager.default.fileExists(atPath: wavPath) else {
        fputs("ERROR: 文件不存在: \(wavPath)\n", stderr)
        exit(1)
    }

    let paths = getModelPaths()
    let sileroPath = vadModelPath ?? defaultSileroModelPath()

    print("音频文件: \(wavPath)")
    print("SenseVoice: \(paths.model)")
    print("Silero VAD: \(sileroPath)")
    print("VAD 启用: \(useVAD)\n")

    let pipeline = RecognitionPipeline(
        modelPaths: paths,
        sileroModelPath: sileroPath,
        useVAD: useVAD
    )

    guard pipeline.modelLoaded else {
        fputs("ERROR: 模型加载失败\n", stderr)
        exit(1)
    }

    print("⏳ 模拟麦克风输入...\n")
    let t0 = Date()
    let result = pipeline.simulate(fileURL: URL(fileURLWithPath: wavPath))
    let elapsed = Date().timeIntervalSince(t0)

    if result.isEmpty {
        print("❌ 识别结果为空")
        exit(1)
    } else {
        print("\n✅ 识别结果: \"\(result.text)\"")
        print("   语言: \(result.lang.isEmpty ? "未知" : result.lang)")
        print("   情绪: \(result.emotion.isEmpty ? "-" : result.emotion)")
        print("   事件: \(result.event.isEmpty ? "-" : result.event)")
        print("   音频: \(String(format: "%.2f", result.duration))s")
        print("   耗时: \(String(format: "%.3f", elapsed))s")
        print("   RTF:  \(String(format: "%.3f", result.processingTime / max(result.duration, 0.001)))")
    }
}

// MARK: - 麦克风模式（Phase 2）

func runMic(duration: Double = 5.0, useVAD: Bool = true, vadModelPath: String? = nil) {
    print("=== VoiceInput 麦克风模式 ===\n")

    let paths = getModelPaths()
    let sileroPath = vadModelPath ?? defaultSileroModelPath()

    print("录音时长: \(duration)s")
    print("VAD 启用: \(useVAD)\n")

    let pipeline = RecognitionPipeline(
        modelPaths: paths,
        sileroModelPath: sileroPath,
        useVAD: useVAD
    )

    guard pipeline.modelLoaded else {
        fputs("ERROR: 模型加载失败\n", stderr)
        exit(1)
    }

    print("🎙️  开始录音，录制 \(duration) 秒...\n")
    let result = pipeline.recordAndRecognize(duration: duration)

    if result.isEmpty {
        print("❌ 识别结果为空（静音或识别失败）")
    } else {
        print("\n✅ 识别结果: \"\(result.text)\"")
        print("   语言: \(result.lang.isEmpty ? "未知" : result.lang)")
        if !result.emotion.isEmpty { print("   情绪: \(result.emotion)") }
        if !result.event.isEmpty   { print("   事件: \(result.event)") }
        print("   音频: \(String(format: "%.2f", result.duration))s")
        print("   识别耗时: \(String(format: "%.3f", result.processingTime))s")
    }
}

// MARK: - Push-to-Talk 模式（Phase 2）

func runPTT(useVAD: Bool = true, vadModelPath: String? = nil) {
    print("=== VoiceInput Push-to-Talk 模式 ===\n")

    let paths = getModelPaths()
    let sileroPath = vadModelPath ?? defaultSileroModelPath()

    print("VAD 启用: \(useVAD)")
    print("操作: 按 Enter 开始录音，再按 Enter 停止并识别\n")

    let pipeline = RecognitionPipeline(
        modelPaths: paths,
        sileroModelPath: sileroPath,
        useVAD: useVAD
    )

    guard pipeline.modelLoaded else {
        fputs("ERROR: 模型加载失败\n", stderr)
        exit(1)
    }

    var sessionCount = 0

    while true {
        print("按 Enter 开始录音（输入 'q' 退出）: ", terminator: "")
        fflush(stdout)

        guard let input = readLine() else { break }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if trimmed == "q" || trimmed == "quit" || trimmed == "exit" {
            print("👋 退出")
            break
        }

        print("🎙️  录音中...（按 Enter 停止）")

        if !pipeline.startListening() {
            fputs("ERROR: 无法开始录音\n", stderr)
            continue
        }

        // 等待用户按 Enter
        _ = readLine()

        print("⏳ 停止录音，识别中...")
        let result = pipeline.stopListening()
        sessionCount += 1

        if result.isEmpty {
            print("[\(sessionCount)] ❌ 识别结果为空\n")
        } else {
            print("[\(sessionCount)] ✅ \"\(result.text)\"")
            if !result.lang.isEmpty { print("    lang=\(result.lang)") }
            print("    音频: \(String(format: "%.2f", result.duration))s, 识别: \(String(format: "%.3f", result.processingTime))s")
            print()
        }
    }
}

// MARK: - 参数解析工具

func parseArgs(_ args: [String]) -> [String: String] {
    var result: [String: String] = [:]
    var i = 0
    while i < args.count {
        let arg = args[i]
        if arg.hasPrefix("--") {
            let key = arg
            if i + 1 < args.count && !args[i + 1].hasPrefix("--") {
                result[key] = args[i + 1]
                i += 2
            } else {
                result[key] = ""  // flag without value
                i += 1
            }
        } else {
            i += 1
        }
    }
    return result
}

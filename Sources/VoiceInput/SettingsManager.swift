// Sources/VoiceInput/SettingsManager.swift
// 用户设置管理 - UserDefaults 持久化
// Phase 4: MenuBar GUI
// Copyright (c) 2026 urDAO Investment

import Foundation
import AppKit

/// SettingsManager 管理应用所有用户设置，持久化到 UserDefaults
final class SettingsManager {

    // MARK: - Singleton

    static let shared = SettingsManager()

    // MARK: - UserDefaults Keys

    private enum Keys {
        static let hotkeyMode      = "voiceinput.hotkeyMode"      // "ptt" / "toggle"
        static let triggerKeyCode  = "voiceinput.triggerKeyCode"   // UInt16
        static let modelType       = "voiceinput.modelType"        // "int8" / "float32"
        static let languageMode    = "voiceinput.languageMode"      // "auto" / "zh" / "en" / "zh+en"
        static let launchAtLogin   = "voiceinput.launchAtLogin"    // Bool
        static let showNotification = "voiceinput.showNotification" // Bool
        // LLM 后处理
        static let llmPostProcessingEnabled = "llmPostProcessingEnabled" // Bool
        static let llmApiKey                = "llmApiKey"                // String
        static let llmApiBaseURL            = "llmApiBaseURL"            // String
    }

    private let defaults = UserDefaults.standard

    // MARK: - Init

    private init() {
        registerDefaults()
    }

    /// 注册默认值（仅在 key 不存在时生效）
    private func registerDefaults() {
        defaults.register(defaults: [
            Keys.hotkeyMode:       "ptt",
            Keys.triggerKeyCode:   UInt16(0x3D),   // 右 Option
            Keys.modelType:        "int8",
            Keys.languageMode:     "zh+en",        // 默认中英双语
            Keys.launchAtLogin:    false,
            Keys.showNotification: true,
            // LLM 后处理默认值
            Keys.llmPostProcessingEnabled: false,
            Keys.llmApiKey:                "",
            Keys.llmApiBaseURL:            "https://api.openai.com/v1",
        ])
    }

    // MARK: - 热键模式

    /// 热键触发模式：.pushToTalk 或 .toggle
    var hotkeyMode: HotkeyManager.Mode {
        get {
            let raw = defaults.string(forKey: Keys.hotkeyMode) ?? "ptt"
            return raw == "toggle" ? .toggle : .pushToTalk
        }
        set {
            defaults.set(newValue == .toggle ? "toggle" : "ptt", forKey: Keys.hotkeyMode)
        }
    }

    /// 热键模式显示名称
    var hotkeyModeName: String {
        switch hotkeyMode {
        case .pushToTalk: return "Push-to-Talk"
        case .toggle:     return "Toggle"
        }
    }

    // MARK: - 热键 KeyCode

    /// 触发热键的虚拟 keyCode，默认右 Option (0x3D = 61)
    var triggerKeyCode: UInt16 {
        get {
            let raw = defaults.integer(forKey: Keys.triggerKeyCode)
            return raw == 0 ? 0x3D : UInt16(raw)
        }
        set {
            defaults.set(Int(newValue), forKey: Keys.triggerKeyCode)
        }
    }

    /// 热键显示名称
    var triggerKeyName: String {
        switch triggerKeyCode {
        case 0x3D: return "右Option"
        case 0x3A: return "左Option"
        case 0x38: return "左Shift"
        case 0x3C: return "右Shift"
        case 0x3B: return "左Control"
        case 0x3E: return "右Control"
        case 0x37: return "左Command"
        case 0x36: return "右Command"
        case 0x35: return "Escape"
        case 0x31: return "Space"
        default:   return "KeyCode(0x\(String(triggerKeyCode, radix: 16)))"
        }
    }

    // MARK: - 模型类型

    /// 使用的模型类型："int8"（快速） 或 "float32"（精确）
    var modelType: String {
        get { defaults.string(forKey: Keys.modelType) ?? "int8" }
        set { defaults.set(newValue, forKey: Keys.modelType) }
    }

    /// 模型类型显示名称
    var modelTypeName: String {
        modelType == "float32" ? "float32 (精确)" : "int8 (快速)"
    }

    /// 语言模式："auto" / "zh" / "en" / "zh+en"
    var languageMode: String {
        get { defaults.string(forKey: Keys.languageMode) ?? "zh+en" }
        set { defaults.set(newValue, forKey: Keys.languageMode) }
    }

    var languageModeName: String {
        switch languageMode {
        case "zh":    return "仅中文"
        case "en":    return "仅英文"
        case "zh+en": return "中文+英文"
        case "auto":  return "自动（全部语言）"
        default:      return languageMode
        }
    }

    /// 当前允许的语言代码列表
    var allowedLanguages: Set<String> {
        switch languageMode {
        case "zh":    return ["zh"]
        case "en":    return ["en"]
        case "zh+en": return ["zh", "en"]
        case "auto":  return ["zh", "en", "ja", "ko", "yue"]
        default:      return ["zh", "en"]
        }
    }

    // MARK: - 开机启动

    /// 是否开机启动
    var launchAtLogin: Bool {
        get { defaults.bool(forKey: Keys.launchAtLogin) }
        set {
            defaults.set(newValue, forKey: Keys.launchAtLogin)
            applyLaunchAtLogin(newValue)
        }
    }

    /// 应用开机启动设置（使用 SMAppService 或 LoginItems）
    private func applyLaunchAtLogin(_ enable: Bool) {
        // 对于非 .app bundle 的直接运行二进制，通过 LaunchAgent plist 实现
        let launchAgentDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
        let plistPath = launchAgentDir.appendingPathComponent("com.urdao.VoiceInput.plist")

        if enable {
            // 获取当前二进制路径
            let binaryPath = CommandLine.arguments[0]

            // 检查是否在 .app bundle 中运行
            let isInBundle = binaryPath.contains(".app/Contents/MacOS/")

            let plistContent: String
            if isInBundle {
                // .app bundle 模式：直接用 open 命令启动，无需 DYLD_LIBRARY_PATH
                let macosDir = (binaryPath as NSString).deletingLastPathComponent
                let contentsDir = (macosDir as NSString).deletingLastPathComponent
                let appPath = (contentsDir as NSString).deletingLastPathComponent
                plistContent = """
                <?xml version="1.0" encoding="UTF-8"?>
                <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
                    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                <plist version="1.0">
                <dict>
                    <key>Label</key>
                    <string>com.urdao.VoiceInput</string>
                    <key>ProgramArguments</key>
                    <array>
                        <string>/usr/bin/open</string>
                        <string>-a</string>
                        <string>\(appPath)</string>
                    </array>
                    <key>RunAtLoad</key>
                    <true/>
                    <key>KeepAlive</key>
                    <false/>
                </dict>
                </plist>
                """
            } else {
                // 直接二进制模式：需要 DYLD_LIBRARY_PATH
                let libDir = (binaryPath as NSString).deletingLastPathComponent
                    .appending("/../sherpa-onnx-v1.12.28-osx-universal2-shared/lib")
                let resolvedLibDir = (libDir as NSString).standardizingPath

                plistContent = """
                <?xml version="1.0" encoding="UTF-8"?>
                <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
                    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                <plist version="1.0">
                <dict>
                    <key>Label</key>
                    <string>com.urdao.VoiceInput</string>
                    <key>ProgramArguments</key>
                    <array>
                        <string>\(binaryPath)</string>
                    </array>
                    <key>EnvironmentVariables</key>
                    <dict>
                        <key>DYLD_LIBRARY_PATH</key>
                        <string>\(resolvedLibDir)</string>
                    </dict>
                    <key>RunAtLoad</key>
                    <true/>
                    <key>KeepAlive</key>
                    <false/>
                </dict>
                </plist>
                """
            }

            do {
                try FileManager.default.createDirectory(at: launchAgentDir,
                    withIntermediateDirectories: true)
                try plistContent.write(to: plistPath, atomically: true, encoding: .utf8)
                fputs("[Settings] LaunchAgent plist 已写入: \(plistPath.path)\n", stderr)
            } catch {
                fputs("[Settings] ERROR: 无法写入 LaunchAgent plist: \(error)\n", stderr)
            }
        } else {
            // 删除 plist
            if FileManager.default.fileExists(atPath: plistPath.path) {
                do {
                    try FileManager.default.removeItem(at: plistPath)
                    fputs("[Settings] LaunchAgent plist 已删除\n", stderr)
                } catch {
                    fputs("[Settings] ERROR: 无法删除 LaunchAgent plist: \(error)\n", stderr)
                }
            }
        }
    }

    // MARK: - 通知

    /// 识别完成后是否发送系统通知
    var showNotification: Bool {
        get { defaults.bool(forKey: Keys.showNotification) }
        set { defaults.set(newValue, forKey: Keys.showNotification) }
    }

    // MARK: - LLM 后处理

    /// 是否启用 LLM 后处理
    var llmPostProcessingEnabled: Bool {
        get { defaults.bool(forKey: Keys.llmPostProcessingEnabled) }
        set { defaults.set(newValue, forKey: Keys.llmPostProcessingEnabled) }
    }

    /// OpenAI API Key（或兼容 API 的密钥）
    var llmApiKey: String {
        get { defaults.string(forKey: Keys.llmApiKey) ?? "" }
        set { defaults.set(newValue, forKey: Keys.llmApiKey) }
    }

    /// API Base URL，默认 https://api.openai.com/v1，支持自定义（兼容 OpenAI compatible API）
    var llmApiBaseURL: String {
        get {
            let stored = defaults.string(forKey: Keys.llmApiBaseURL) ?? ""
            return stored.isEmpty ? "https://api.openai.com/v1" : stored
        }
        set { defaults.set(newValue, forKey: Keys.llmApiBaseURL) }
    }

    // MARK: - 用户数据目录

    /// 用户数据目录：~/Library/Application Support/VoiceInput/
    /// 用于存放用户下载的模型等，不随 app 更新被覆盖
    static var appSupportDir: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/VoiceInput"
    }

    /// 用户模型目录：~/Library/Application Support/VoiceInput/models/sense-voice/
    static var userModelDir: String {
        return "\(appSupportDir)/models/sense-voice"
    }

    /// Whisper 模型目录：~/Library/Application Support/VoiceInput/models/whisper/
    static var whisperModelDir: String {
        return "\(appSupportDir)/models/whisper"
    }

    /// 确保用户数据目录存在
    static func ensureAppSupportDir() {
        let fm = FileManager.default
        let dirs = [appSupportDir, userModelDir, whisperModelDir]
        for dir in dirs {
            if !fm.fileExists(atPath: dir) {
                try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            }
        }
    }

    // MARK: - 模型路径解析

    /// 根据 modelType 返回对应的模型文件名
    var modelFileName: String {
        modelType == "float32" ? "model.onnx" : "model.int8.onnx"
    }

    /// 解析模型文件路径
    /// 查找顺序：
    /// 1. ~/Library/Application Support/VoiceInput/models/sense-voice/ （用户数据，不随更新丢失）
    /// 2. .app bundle/Contents/Resources/models/sense-voice/ （随 app 分发）
    /// 3. 开发环境 fallback 路径
    func resolveModelPath() -> String {
        let fileName = modelFileName

        // 1. 用户数据目录（float32 模型下载到这里）
        let userPath = (Self.userModelDir as NSString).appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: userPath) {
            fputs("[Settings] 模型路径（用户目录）: \(userPath)\n", stderr)
            return userPath
        }

        // 2. App bundle
        if let resourcePath = Bundle.main.resourcePath {
            let bundlePath = ((resourcePath as NSString).appendingPathComponent("models/sense-voice") as NSString).appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: bundlePath) {
                return bundlePath
            }
        }

        // 3. 开发环境 fallback
        let binaryDir = (CommandLine.arguments[0] as NSString).deletingLastPathComponent
        let relPath = ((binaryDir as NSString).appendingPathComponent("Resources/models/sense-voice") as NSString).appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: relPath) {
            return relPath
        }

        // 最终 fallback
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.openclaw/workspace-satoshi/VoiceInput/Resources/models/sense-voice/\(fileName)"
    }

    /// 返回模型目录（用于显示和诊断）
    func resolveModelDir() -> String {
        // 优先 bundle
        if let resourcePath = Bundle.main.resourcePath {
            let bundlePath = (resourcePath as NSString).appendingPathComponent("models/sense-voice")
            if FileManager.default.fileExists(atPath: bundlePath) {
                return bundlePath
            }
        }
        let binaryDir = (CommandLine.arguments[0] as NSString).deletingLastPathComponent
        let relPath = (binaryDir as NSString).appendingPathComponent("Resources/models/sense-voice")
        if FileManager.default.fileExists(atPath: relPath) {
            return relPath
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.openclaw/workspace-satoshi/VoiceInput/Resources/models/sense-voice"
    }

    /// 返回 tokens.txt 路径（优先用户目录，再 bundle）
    func resolveTokensPath() -> String {
        let userPath = (Self.userModelDir as NSString).appendingPathComponent("tokens.txt")
        if FileManager.default.fileExists(atPath: userPath) {
            return userPath
        }

        if let resourcePath = Bundle.main.resourcePath {
            let bundlePath = ((resourcePath as NSString).appendingPathComponent("models/sense-voice") as NSString).appendingPathComponent("tokens.txt")
            if FileManager.default.fileExists(atPath: bundlePath) {
                return bundlePath
            }
        }

        let dir = resolveModelDir()
        return (dir as NSString).appendingPathComponent("tokens.txt")
    }

    /// 返回 silero-vad 模型路径
    func resolveSileroModelPath() -> String {
        if let resourcePath = Bundle.main.resourcePath {
            let bundlePath = (resourcePath as NSString).appendingPathComponent("models/silero-vad/silero_vad.onnx")
            if FileManager.default.fileExists(atPath: bundlePath) {
                return bundlePath
            }
        }
        let binaryDir = (CommandLine.arguments[0] as NSString).deletingLastPathComponent
        let relPath = (binaryDir as NSString).appendingPathComponent("Resources/models/silero-vad/silero_vad.onnx")
        if FileManager.default.fileExists(atPath: relPath) {
            return relPath
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.openclaw/workspace-satoshi/VoiceInput/Resources/models/silero-vad/silero_vad.onnx"
    }
}

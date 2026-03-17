// Sources/VoiceInput/SettingsManager.swift
// 用户设置管理 - 统一代理到 ConfigManager（Single Source of Truth）
// Phase 4: MenuBar GUI
// Copyright (c) 2026 urDAO Investment
//
// 架构说明：
// - 所有配置读写统一走 ConfigManager（config.json）
// - UserDefaults 仅保留 triggerKeyCode（热键）
// - API Key 继续使用 Keychain（安全）
// - 升级时一次性迁移旧 UserDefaults 数据到 ConfigManager

import Foundation
import AppKit
import os

/// SettingsManager 管理应用所有用户设置
/// 持久化层：ConfigManager (config.json) 作为 single source of truth
final class SettingsManager {

    private static let logger = Logger(subsystem: "com.urdao.voiceinput", category: "SettingsManager")

    // MARK: - Singleton

    static let shared = SettingsManager()

    // MARK: - UserDefaults Keys（仅保留热键 + 迁移标记）

    private enum Keys {
        // 热键 keyCode 仍用 UserDefaults（不属于 config.json 范畴）
        static let triggerKeyCode  = "voiceinput.triggerKeyCode"   // UInt16

        // 旧 UserDefaults key（仅用于迁移读取）
        static let hotkeyMode      = "voiceinput.hotkeyMode"
        static let modelType       = "voiceinput.modelType"
        static let languageMode    = "voiceinput.languageMode"
        static let launchAtLogin   = "voiceinput.launchAtLogin"
        static let showNotification = "voiceinput.showNotification"
        static let llmPostProcessingEnabled = "llmPostProcessingEnabled"
        static let llmApiKey                = "llmApiKey"
        static let llmApiBaseURL            = "llmApiBaseURL"
        static let llmModel                 = "llmModel"
        static let llmActivePreset          = "llmActivePreset"
        static let whisperModel             = "whisperModel"
        static let llmMaxTokens             = "llmMaxTokens"
        static let llmTemperature           = "llmTemperature"
        static let llmTimeout               = "llmTimeout"
        static let llmMinTextLength         = "llmMinTextLength"
        static let shortAudioThreshold      = "shortAudioThreshold"

        // 迁移标记
        static let configMigrated = "voiceinput.configMigrated"
    }

    // MARK: - ConfigManager Key Mapping（UserDefaults key → config.json dot-path）

    private enum ConfigKeys {
        static let hotkeyMode               = "ui.hotkeyMode"
        static let modelType                = "asr.modelType"
        static let languageMode             = "asr.languageMode"
        static let launchAtLogin            = "ui.launchAtLogin"
        static let showNotification         = "ui.showNotification"
        static let llmPostProcessingEnabled = "llm.enabled"
        static let llmApiBaseURL            = "llm.apiBaseURL"
        static let llmModel                 = "llm.model"
        static let llmActivePreset          = "llm.activePreset"
        static let whisperModel             = "routing.whisperModel"
        static let llmMaxTokens             = "llm.maxTokens"
        static let llmTemperature           = "llm.temperature"
        static let llmTimeout               = "llm.timeout"
        static let llmMinTextLength         = "llm.minTextLength"
        static let shortAudioThreshold      = "asr.shortAudioThreshold"
    }

    // MARK: - LLM 预设定义

    struct LLMPreset {
        let id: String
        let name: String
        let defaultBaseURL: String
        let defaultModel: String
        let needsApiKey: Bool  // Ollama 不需要
    }

    static let llmPresets: [LLMPreset] = [
        // 云端
        LLMPreset(id: "deepseek",  name: "DeepSeek",    defaultBaseURL: "https://api.deepseek.com",       defaultModel: "deepseek-chat",     needsApiKey: true),
        LLMPreset(id: "qwen",      name: "通义千问",     defaultBaseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1", defaultModel: "qwen-turbo", needsApiKey: true),
        LLMPreset(id: "gemini",    name: "Gemini",      defaultBaseURL: "https://generativelanguage.googleapis.com/v1beta/openai", defaultModel: "gemini-2.0-flash", needsApiKey: true),
        LLMPreset(id: "openai",    name: "OpenAI",      defaultBaseURL: "https://api.openai.com/v1",      defaultModel: "gpt-4o-mini",       needsApiKey: true),
        LLMPreset(id: "groq",      name: "Groq",        defaultBaseURL: "https://api.groq.com/openai/v1", defaultModel: "llama-3.3-70b-versatile", needsApiKey: true),
        // 本地 Ollama
        LLMPreset(id: "ollama-3b",  name: "Ollama Qwen2.5-3B",  defaultBaseURL: "http://localhost:11434/v1", defaultModel: "qwen2.5:3b",  needsApiKey: false),
        LLMPreset(id: "ollama-7b",  name: "Ollama Qwen2.5-7B",  defaultBaseURL: "http://localhost:11434/v1", defaultModel: "qwen2.5:7b",  needsApiKey: false),
        LLMPreset(id: "ollama-14b", name: "Ollama Qwen2.5-14B", defaultBaseURL: "http://localhost:11434/v1", defaultModel: "qwen2.5:14b", needsApiKey: false),
        LLMPreset(id: "ollama-32b", name: "Ollama Qwen2.5-32B", defaultBaseURL: "http://localhost:11434/v1", defaultModel: "qwen2.5:32b", needsApiKey: false),
    ]

    private let defaults = UserDefaults.standard

    // MARK: - Init

    private init() {
        migrateApiKeyToKeychain()
        migrateUserDefaultsToConfig()
    }

    /// 迁移明文 API Key 从 UserDefaults 到 Keychain（旧版兼容）
    private func migrateApiKeyToKeychain() {
        if let oldKey = defaults.string(forKey: Keys.llmApiKey), !oldKey.isEmpty {
            if KeychainHelper.get(service: "com.urdao.voiceinput", account: "llmApiKey") == nil {
                KeychainHelper.set(oldKey, service: "com.urdao.voiceinput", account: "llmApiKey")
                Self.logger.info("API Key 已从 UserDefaults 迁移到 Keychain")
            }
            defaults.removeObject(forKey: Keys.llmApiKey)
        }
    }

    /// 一次性迁移：将旧 UserDefaults 配置迁移到 ConfigManager
    /// 检查 voiceinput.configMigrated flag，未迁移则执行一次
    private func migrateUserDefaultsToConfig() {
        // 已迁移则跳过
        guard !defaults.bool(forKey: Keys.configMigrated) else {
            Self.logger.info("配置已迁移，跳过")
            return
        }

        Self.logger.info("开始迁移 UserDefaults 配置到 ConfigManager...")
        let cfg = ConfigManager.shared

        // hotkeyMode
        if let v = defaults.string(forKey: Keys.hotkeyMode), !v.isEmpty {
            cfg.set(ConfigKeys.hotkeyMode, value: v)
        }
        // modelType
        if let v = defaults.string(forKey: Keys.modelType), !v.isEmpty {
            cfg.set(ConfigKeys.modelType, value: v)
        }
        // languageMode
        if let v = defaults.string(forKey: Keys.languageMode), !v.isEmpty {
            cfg.set(ConfigKeys.languageMode, value: v)
        }
        // launchAtLogin（UserDefaults.bool 默认返回 false，只迁移显式设置过的值）
        if defaults.object(forKey: Keys.launchAtLogin) != nil {
            cfg.set(ConfigKeys.launchAtLogin, value: defaults.bool(forKey: Keys.launchAtLogin))
        }
        // showNotification（同上）
        if defaults.object(forKey: Keys.showNotification) != nil {
            cfg.set(ConfigKeys.showNotification, value: defaults.bool(forKey: Keys.showNotification))
        }
        // llmPostProcessingEnabled
        if defaults.object(forKey: Keys.llmPostProcessingEnabled) != nil {
            cfg.set(ConfigKeys.llmPostProcessingEnabled, value: defaults.bool(forKey: Keys.llmPostProcessingEnabled))
        }
        // llmApiBaseURL
        if let v = defaults.string(forKey: Keys.llmApiBaseURL), !v.isEmpty {
            cfg.set(ConfigKeys.llmApiBaseURL, value: v)
        }
        // llmModel
        if let v = defaults.string(forKey: Keys.llmModel), !v.isEmpty {
            cfg.set(ConfigKeys.llmModel, value: v)
        }
        // llmActivePreset
        if let v = defaults.string(forKey: Keys.llmActivePreset), !v.isEmpty {
            cfg.set(ConfigKeys.llmActivePreset, value: v)
        }
        // whisperModel
        if let v = defaults.string(forKey: Keys.whisperModel), !v.isEmpty {
            cfg.set(ConfigKeys.whisperModel, value: v)
        }
        // llmMaxTokens
        if defaults.object(forKey: Keys.llmMaxTokens) != nil {
            let v = defaults.integer(forKey: Keys.llmMaxTokens)
            if v > 0 { cfg.set(ConfigKeys.llmMaxTokens, value: v) }
        }
        // llmTemperature
        if defaults.object(forKey: Keys.llmTemperature) != nil {
            let v = defaults.double(forKey: Keys.llmTemperature)
            if v > 0 { cfg.set(ConfigKeys.llmTemperature, value: v) }
        }
        // llmTimeout
        if defaults.object(forKey: Keys.llmTimeout) != nil {
            let v = defaults.double(forKey: Keys.llmTimeout)
            if v > 0 { cfg.set(ConfigKeys.llmTimeout, value: v) }
        }
        // llmMinTextLength
        if defaults.object(forKey: Keys.llmMinTextLength) != nil {
            let v = defaults.integer(forKey: Keys.llmMinTextLength)
            if v > 0 { cfg.set(ConfigKeys.llmMinTextLength, value: v) }
        }
        // shortAudioThreshold
        if defaults.object(forKey: Keys.shortAudioThreshold) != nil {
            let v = defaults.double(forKey: Keys.shortAudioThreshold)
            if v > 0 { cfg.set(ConfigKeys.shortAudioThreshold, value: v) }
        }

        // 迁移旧预设配置（UserDefaults "llm.preset.{id}.baseURL/model"）
        for preset in Self.llmPresets {
            let prefix = "llm.preset.\(preset.id)"
            if let url = defaults.string(forKey: "\(prefix).baseURL"), !url.isEmpty {
                cfg.set("presets.\(preset.id).baseURL", value: url)
            }
            if let model = defaults.string(forKey: "\(prefix).model"), !model.isEmpty {
                cfg.set("presets.\(preset.id).model", value: model)
            }
        }

        // 标记迁移完成
        defaults.set(true, forKey: Keys.configMigrated)
        Self.logger.info("UserDefaults → ConfigManager 迁移完成")
    }

    // MARK: - 热键模式

    /// 热键触发模式：.pushToTalk 或 .toggle
    var hotkeyMode: HotkeyManager.Mode {
        get {
            let raw = ConfigManager.shared.getString(ConfigKeys.hotkeyMode, default: "ptt")
            return raw == "toggle" ? .toggle : .pushToTalk
        }
        set {
            ConfigManager.shared.set(ConfigKeys.hotkeyMode, value: newValue == .toggle ? "toggle" : "ptt")
        }
    }

    /// 热键模式显示名称
    var hotkeyModeName: String {
        switch hotkeyMode {
        case .pushToTalk: return "Push-to-Talk"
        case .toggle:     return "Toggle"
        }
    }

    // MARK: - 热键 KeyCode（仍用 UserDefaults）

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
        get { ConfigManager.shared.getString(ConfigKeys.modelType, default: "int8") }
        set { ConfigManager.shared.set(ConfigKeys.modelType, value: newValue) }
    }

    /// 模型类型显示名称
    var modelTypeName: String {
        modelType == "float32" ? "float32 (精确)" : "int8 (快速)"
    }

    /// 语言模式："auto" / "zh" / "en" / "zh+en"
    var languageMode: String {
        get { ConfigManager.shared.getString(ConfigKeys.languageMode, default: "zh+en") }
        set { ConfigManager.shared.set(ConfigKeys.languageMode, value: newValue) }
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
        get { ConfigManager.shared.getBool(ConfigKeys.launchAtLogin, default: false) }
        set {
            ConfigManager.shared.set(ConfigKeys.launchAtLogin, value: newValue)
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
            let isInBundle = binaryPath.contains(".app/Contents/MacOS/")

            // C4: 用 PropertyListSerialization 代替字符串拼接，防止 XML 注入
            var plistDict: [String: Any] = [
                "Label": "com.urdao.VoiceInput",
                "RunAtLoad": true,
                "KeepAlive": false
            ]

            if isInBundle {
                let macosDir = (binaryPath as NSString).deletingLastPathComponent
                let contentsDir = (macosDir as NSString).deletingLastPathComponent
                let appPath = (contentsDir as NSString).deletingLastPathComponent
                plistDict["ProgramArguments"] = ["/usr/bin/open", "-a", appPath]
            } else {
                let libDir = (binaryPath as NSString).deletingLastPathComponent
                    .appending("/../sherpa-onnx-v1.12.28-osx-universal2-shared/lib")
                let resolvedLibDir = (libDir as NSString).standardizingPath
                plistDict["ProgramArguments"] = [binaryPath]
                plistDict["EnvironmentVariables"] = ["DYLD_LIBRARY_PATH": resolvedLibDir]
            }

            do {
                try FileManager.default.createDirectory(at: launchAgentDir,
                    withIntermediateDirectories: true)
                let plistData = try PropertyListSerialization.data(
                    fromPropertyList: plistDict, format: .xml, options: 0)
                try plistData.write(to: plistPath)
                Self.logger.info("LaunchAgent plist 已写入: \(plistPath.path)")
            } catch {
                Self.logger.error("无法写入 LaunchAgent plist: \(error)")
            }
        } else {
            // 删除 plist
            if FileManager.default.fileExists(atPath: plistPath.path) {
                do {
                    try FileManager.default.removeItem(at: plistPath)
                    Self.logger.info("LaunchAgent plist 已删除")
                } catch {
                    Self.logger.error("无法删除 LaunchAgent plist: \(error)")
                }
            }
        }
    }

    // MARK: - 通知

    /// 识别完成后是否发送系统通知
    var showNotification: Bool {
        get { ConfigManager.shared.getBool(ConfigKeys.showNotification, default: true) }
        set { ConfigManager.shared.set(ConfigKeys.showNotification, value: newValue) }
    }

    // MARK: - LLM 后处理

    /// 是否启用 LLM 后处理
    var llmPostProcessingEnabled: Bool {
        get { ConfigManager.shared.getBool(ConfigKeys.llmPostProcessingEnabled, default: false) }
        set { ConfigManager.shared.set(ConfigKeys.llmPostProcessingEnabled, value: newValue) }
    }

    /// OpenAI API Key（或兼容 API 的密钥）
    // C5: API Key 使用 Keychain 存储，不读写 config.json
    var llmApiKey: String {
        get { KeychainHelper.get(service: "com.urdao.voiceinput", account: "llmApiKey") ?? "" }
        set {
            if newValue.isEmpty {
                KeychainHelper.delete(service: "com.urdao.voiceinput", account: "llmApiKey")
            } else {
                KeychainHelper.set(newValue, service: "com.urdao.voiceinput", account: "llmApiKey")
            }
            // 清除旧的 UserDefaults 明文存储（兼容性清理）
            defaults.removeObject(forKey: Keys.llmApiKey)
        }
    }

    /// API Base URL，默认 https://api.openai.com/v1，支持自定义（兼容 OpenAI compatible API）
    var llmApiBaseURL: String {
        get {
            let stored = ConfigManager.shared.getString(ConfigKeys.llmApiBaseURL, default: "")
            return stored.isEmpty ? "https://api.openai.com/v1" : stored
        }
        set { ConfigManager.shared.set(ConfigKeys.llmApiBaseURL, value: newValue) }
    }

    /// LLM 模型名，默认 gpt-4o-mini
    var llmModel: String {
        get {
            let stored = ConfigManager.shared.getString(ConfigKeys.llmModel, default: "")
            return stored.isEmpty ? "gpt-4o-mini" : stored
        }
        set { ConfigManager.shared.set(ConfigKeys.llmModel, value: newValue) }
    }

    /// 当前激活的预设 ID
    var llmActivePreset: String {
        get { ConfigManager.shared.getString(ConfigKeys.llmActivePreset, default: "") }
        set { ConfigManager.shared.set(ConfigKeys.llmActivePreset, value: newValue) }
    }

    // MARK: - Whisper 模型选择

    /// Whisper 模型类型
    enum WhisperModel: String {
        case smallEn = "small.en"
        case largeV3 = "large-v3"

        var displayName: String {
            switch self {
            case .smallEn: return "Small (英文专用, ~60MB)"
            case .largeV3: return "Large-v3 (多语言, ~1GB)"
            }
        }

        var downloadURL: String {
            switch self {
            case .smallEn:
                return "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-whisper-small.en.tar.bz2"
            case .largeV3:
                return "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-whisper-large-v3.tar.bz2"
            }
        }

        var encoderFile: String {
            switch self {
            case .smallEn: return "small.en-encoder.int8.onnx"
            case .largeV3: return "large-v3-encoder.int8.onnx"
            }
        }

        var decoderFile: String {
            switch self {
            case .smallEn: return "small.en-decoder.int8.onnx"
            case .largeV3: return "large-v3-decoder.int8.onnx"
            }
        }

        var tokensFile: String {
            switch self {
            case .smallEn: return "small.en-tokens.txt"
            case .largeV3: return "large-v3-tokens.txt"
            }
        }
    }

    var whisperModel: WhisperModel {
        get {
            let raw = ConfigManager.shared.getString(ConfigKeys.whisperModel, default: "small.en")
            return WhisperModel(rawValue: raw) ?? .smallEn
        }
        set { ConfigManager.shared.set(ConfigKeys.whisperModel, value: newValue.rawValue) }
    }

    // MARK: - LLM 高级参数

    var llmMaxTokens: Int {
        get {
            let v = ConfigManager.shared.getInt(ConfigKeys.llmMaxTokens, default: 0)
            return v > 0 ? v : 200
        }
        set { ConfigManager.shared.set(ConfigKeys.llmMaxTokens, value: newValue) }
    }

    var llmTemperature: Double {
        get {
            let v = ConfigManager.shared.getDouble(ConfigKeys.llmTemperature, default: 0)
            return v > 0 ? v : 0.1
        }
        set { ConfigManager.shared.set(ConfigKeys.llmTemperature, value: newValue) }
    }

    var llmTimeout: Double {
        get {
            let v = ConfigManager.shared.getDouble(ConfigKeys.llmTimeout, default: 0)
            return v > 0 ? v : 4.0
        }
        set { ConfigManager.shared.set(ConfigKeys.llmTimeout, value: newValue) }
    }

    /// LLM 最短文本长度（低于此长度跳过 LLM）
    var llmMinTextLength: Int {
        get {
            let v = ConfigManager.shared.getInt(ConfigKeys.llmMinTextLength, default: 0)
            return v > 0 ? v : 5
        }
        set { ConfigManager.shared.set(ConfigKeys.llmMinTextLength, value: newValue) }
    }

    /// 短音频阈值（秒），低于此时长的音频走 Whisper
    var shortAudioThreshold: Double {
        get {
            let v = ConfigManager.shared.getDouble(ConfigKeys.shortAudioThreshold, default: 0)
            return v > 0 ? v : 2.0
        }
        set { ConfigManager.shared.set(ConfigKeys.shortAudioThreshold, value: newValue) }
    }

    // MARK: - 预设配置存取（存到 config.json presets.{presetId}）

    /// 保存当前配置到指定预设
    func saveCurrentToPreset(_ presetId: String) {
        let cfg = ConfigManager.shared
        // API Key 存 Keychain（不变）
        if !llmApiKey.isEmpty {
            KeychainHelper.set(llmApiKey, service: "com.urdao.voiceinput", account: "llm.preset.\(presetId).apiKey")
        }
        // BaseURL 和 Model 存 config.json
        cfg.set("presets.\(presetId).baseURL", value: llmApiBaseURL)
        cfg.set("presets.\(presetId).model", value: llmModel)
        llmActivePreset = presetId
        Self.logger.info("保存预设 \(presetId): model=\(self.llmModel), baseURL=\(self.llmApiBaseURL)")
    }

    /// 加载预设配置（如果之前保存过，恢复用户的自定义值）
    func loadPreset(_ presetId: String) {
        let cfg = ConfigManager.shared

        // 先保存当前预设（如果有活动预设）
        let currentPreset = llmActivePreset
        if !currentPreset.isEmpty {
            saveCurrentToPreset(currentPreset)
        }

        // 查找预设定义
        guard let preset = Self.llmPresets.first(where: { $0.id == presetId }) else {
            Self.logger.info("未知预设: \(presetId)")
            return
        }

        // 加载保存的配置，没保存过则用默认值
        let savedKey = KeychainHelper.get(service: "com.urdao.voiceinput", account: "llm.preset.\(presetId).apiKey") ?? ""
        let savedURL = cfg.getString("presets.\(presetId).baseURL", default: "")
        let savedModel = cfg.getString("presets.\(presetId).model", default: "")

        llmApiBaseURL = savedURL.isEmpty ? preset.defaultBaseURL : savedURL
        llmModel = savedModel.isEmpty ? preset.defaultModel : savedModel

        if !savedKey.isEmpty {
            llmApiKey = savedKey
        } else if !preset.needsApiKey {
            llmApiKey = "ollama"
        }
        // 如果需要 API Key 且没保存过，不清空当前 key（留给调用方处理）

        llmPostProcessingEnabled = true
        llmActivePreset = presetId

        Self.logger.info("加载预设 \(presetId) (\(preset.name)): model=\(self.llmModel), baseURL=\(self.llmApiBaseURL), hasKey=\(!self.llmApiKey.isEmpty)")
    }

    /// 获取预设已保存的 API Key（用于菜单显示）
    func presetHasApiKey(_ presetId: String) -> Bool {
        let key = KeychainHelper.get(service: "com.urdao.voiceinput", account: "llm.preset.\(presetId).apiKey") ?? ""
        return !key.isEmpty
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
            Self.logger.info("模型路径（用户目录）: \(userPath)")
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

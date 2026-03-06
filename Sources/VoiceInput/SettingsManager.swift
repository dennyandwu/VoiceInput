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
        static let launchAtLogin   = "voiceinput.launchAtLogin"    // Bool
        static let showNotification = "voiceinput.showNotification" // Bool
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
            Keys.launchAtLogin:    false,
            Keys.showNotification: true,
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

    // MARK: - 模型路径解析

    /// 根据 modelType 返回对应的模型文件名
    var modelFileName: String {
        modelType == "float32" ? "model.onnx" : "model.int8.onnx"
    }

    /// 根据二进制位置推算 models 目录路径
    func resolveModelDir() -> String {
        // 优先检查 .app bundle 内的 Resources
        if let resourcePath = Bundle.main.resourcePath {
            let bundlePath = (resourcePath as NSString).appendingPathComponent("models/sense-voice")
            if FileManager.default.fileExists(atPath: bundlePath) {
                return bundlePath
            }
        }
        let binaryPath = CommandLine.arguments[0]
        let binaryDir = (binaryPath as NSString).deletingLastPathComponent
        // 尝试相对路径：<binary_dir>/Resources/models/sense-voice
        let relPath = (binaryDir as NSString)
            .appendingPathComponent("Resources/models/sense-voice")
        if FileManager.default.fileExists(atPath: relPath) {
            return relPath
        }
        // 尝试上一级：适用于二进制在项目根目录的情况
        let parentDir = (binaryDir as NSString).deletingLastPathComponent
        let altPath = (parentDir as NSString)
            .appendingPathComponent("VoiceInput/Resources/models/sense-voice")
        if FileManager.default.fileExists(atPath: altPath) {
            return altPath
        }
        // 最终 fallback：home 目录下的固定路径
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.openclaw/workspace-satoshi/VoiceInput/Resources/models/sense-voice"
    }

    /// 返回完整模型文件路径（model.onnx 或 model.int8.onnx）
    func resolveModelPath() -> String {
        let dir = resolveModelDir()
        return (dir as NSString).appendingPathComponent(modelFileName)
    }

    /// 返回 tokens.txt 路径
    func resolveTokensPath() -> String {
        let dir = resolveModelDir()
        return (dir as NSString).appendingPathComponent("tokens.txt")
    }

    /// 返回 silero-vad 模型路径
    func resolveSileroModelPath() -> String {
        // 优先检查 .app bundle 内的 Resources
        if let resourcePath = Bundle.main.resourcePath {
            let bundlePath = (resourcePath as NSString).appendingPathComponent("models/silero-vad/silero_vad.onnx")
            if FileManager.default.fileExists(atPath: bundlePath) {
                return bundlePath
            }
        }
        let binaryDir = (CommandLine.arguments[0] as NSString).deletingLastPathComponent
        let relPath = (binaryDir as NSString)
            .appendingPathComponent("Resources/models/silero-vad/silero_vad.onnx")
        if FileManager.default.fileExists(atPath: relPath) {
            return relPath
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.openclaw/workspace-satoshi/VoiceInput/Resources/models/silero-vad/silero_vad.onnx"
    }
}

import Foundation

/// 外部 JSON 配置文件管理器
/// 配置文件路径: ~/Library/Application Support/VoiceInput/config.json
/// 修改后重启应用生效
class ConfigManager {
    static let shared = ConfigManager()

    /// 配置文件路径
    static var configDir: String {
        let dir = NSHomeDirectory() + "/Library/Application Support/VoiceInput"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }
    static var configPath: String { configDir + "/config.json" }

    /// 完整配置字典
    private var config: [String: Any] = [:]

    /// 默认配置（从 bundle 内 default-config.json 读取）
    private var defaults: [String: Any] = [:]

    private init() {
        loadDefaults()
        loadConfig()
    }

    // MARK: - 加载

    private func loadDefaults() {
        // 从 bundle 内读取默认配置
        let bundlePath = Bundle.main.resourcePath ?? ""
        let defaultPath = (bundlePath as NSString).appendingPathComponent("default-config.json")

        if let data = FileManager.default.contents(atPath: defaultPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            defaults = json
            fputs("[Config] 默认配置已加载\n", stderr)
        } else {
            fputs("[Config] ⚠️ 未找到 default-config.json，使用硬编码默认值\n", stderr)
            defaults = hardcodedDefaults()
        }
    }

    func loadConfig() {
        let path = ConfigManager.configPath

        if let data = FileManager.default.contents(atPath: path),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            config = json
            fputs("[Config] 用户配置已加载: \(path)\n", stderr)
        } else {
            // 首次运行：拷贝默认配置到用户目录
            config = defaults
            saveConfig()
            fputs("[Config] 首次运行，已创建配置文件: \(path)\n", stderr)
        }
    }

    func saveConfig() {
        do {
            let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: ConfigManager.configPath))
        } catch {
            fputs("[Config] ⚠️ 保存配置失败: \(error.localizedDescription)\n", stderr)
        }
    }

    /// 重新加载配置（菜单可触发）
    func reload() {
        loadConfig()
        fputs("[Config] 配置已重新加载\n", stderr)
    }

    // MARK: - 读取（支持 dot-path: "routing.zhThreshold"）

    func get<T>(_ keyPath: String, default defaultValue: T) -> T {
        let value = resolve(keyPath: keyPath, in: config)
            ?? resolve(keyPath: keyPath, in: defaults)
        return (value as? T) ?? defaultValue
    }

    func getString(_ keyPath: String, default defaultValue: String = "") -> String {
        get(keyPath, default: defaultValue)
    }

    func getDouble(_ keyPath: String, default defaultValue: Double = 0) -> Double {
        // JSON 数字可能是 Int 或 Double
        let value = resolve(keyPath: keyPath, in: config)
            ?? resolve(keyPath: keyPath, in: defaults)
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        return defaultValue
    }

    func getInt(_ keyPath: String, default defaultValue: Int = 0) -> Int {
        let value = resolve(keyPath: keyPath, in: config)
            ?? resolve(keyPath: keyPath, in: defaults)
        if let i = value as? Int { return i }
        if let d = value as? Double { return Int(d) }
        return defaultValue
    }

    func getBool(_ keyPath: String, default defaultValue: Bool = false) -> Bool {
        get(keyPath, default: defaultValue)
    }

    // MARK: - 写入

    func set(_ keyPath: String, value: Any) {
        setNested(keyPath: keyPath, value: value, in: &config)
        saveConfig()
    }

    // MARK: - Dot-path 解析

    private func resolve(keyPath: String, in dict: [String: Any]) -> Any? {
        let parts = keyPath.split(separator: ".").map(String.init)
        var current: Any = dict
        for part in parts {
            guard let d = current as? [String: Any], let next = d[part] else {
                return nil
            }
            current = next
        }
        return current
    }

    private func setNested(keyPath: String, value: Any, in dict: inout [String: Any]) {
        let parts = keyPath.split(separator: ".").map(String.init)
        if parts.count == 1 {
            dict[parts[0]] = value
            return
        }
        let key = parts[0]
        var sub = (dict[key] as? [String: Any]) ?? [:]
        let remaining = parts.dropFirst().joined(separator: ".")
        setNested(keyPath: remaining, value: value, in: &sub)
        dict[key] = sub
    }

    // MARK: - 硬编码默认值（fallback）

    private func hardcodedDefaults() -> [String: Any] {
        return [
            "asr": [
                "languageMode": "zh+en",
                "shortAudioThreshold": 2.0,
                "modelType": "int8"
            ],
            "routing": [
                "zhThreshold": 0.7,
                "enThreshold": 0.8,
                "asciiMinForWhisper": 0.25,
                "mixedChineseRetention": 0.5,
                "whisperModel": "small.en"
            ],
            "vad": [
                "minSpeechDuration": 0.3,
                "silenceThreshold": 0.5
            ],
            "llm": [
                "enabled": false,
                "minTextLength": 5,
                "maxTokens": 200,
                "temperature": 0.1,
                "timeout": 4.0,
                "apiBaseURL": "https://api.openai.com/v1",
                "model": "gpt-4o-mini",
                "activePreset": ""
            ],
            "ui": [
                "showNotification": true,
                "hotkeyMode": "ptt",
                "launchAtLogin": false
            ]
        ]
    }
}

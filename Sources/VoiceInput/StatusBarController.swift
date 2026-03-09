// Sources/VoiceInput/StatusBarController.swift
// 菜单栏状态图标控制器
// Phase 4: MenuBar GUI
// Copyright (c) 2026 urDAO Investment

import Foundation
import AppKit

/// StatusBarController 管理 macOS 菜单栏图标及弹出菜单
///
/// 图标状态：
/// - idle:      mic.fill        — 等待热键触发
/// - recording: mic.badge.plus  — 正在录音
/// - done:      checkmark.circle.fill — 识别完成（短暂显示）
///
/// 交互：
/// - 左键点击：toggle 录音（当 mode == .toggle 时）
/// - 右键 / 辅助点击：显示菜单
final class StatusBarController {

    // MARK: - State

    enum State {
        case idle
        case recording
        case done
    }

    // MARK: - Public Callbacks (set by AppDelegate)

    /// 用户通过菜单栏左键点击触发录音切换（toggle 模式）
    var onClickToggleRecording: (() -> Void)?

    /// 用户在菜单中切换热键模式
    var onHotkeyModeChanged: ((HotkeyManager.Mode) -> Void)?

    /// 用户在菜单中切换模型类型（切换后需要重新加载引擎）
    var onModelTypeChanged: ((String) -> Void)?
    var onFloat32ModelNeeded: ((String) -> Void)?
    var onWhisperDownloadRequested: (() -> Void)?

    /// 用户请求退出
    var onQuit: (() -> Void)?

    /// 用户请求设置新热键
    var onHotkeyRecordRequested: (() -> Void)?

    /// 用户请求检查更新
    var onCheckUpdate: (() -> Void)?

    // MARK: - Private Properties

    private var statusItem: NSStatusItem
    private var currentState: State = .idle
    private var doneResetTimer: DispatchSourceTimer?

    private let settings = SettingsManager.shared

    // MARK: - Init

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setupButton()
    }

    deinit {
        doneResetTimer?.cancel()
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    // MARK: - Setup

    private func setupButton() {
        guard let button = statusItem.button else { return }

        button.image = iconImage(for: .idle)
        button.imagePosition = .imageOnly
        button.toolTip = "VoiceInput — 右键显示菜单"

        // 同时响应左右键
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.action = #selector(handleButtonClick(_:))
        button.target = self
    }

    // MARK: - Button Click Handler

    @objc private func handleButtonClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent!

        if event.type == .rightMouseUp ||
           event.modifierFlags.contains(.control) {
            // 右键或 Control+左键 → 显示菜单
            showMenu()
        } else {
            // 左键 → toggle 录音（仅 toggle 模式有意义，PTT 模式下直接显示菜单）
            if settings.hotkeyMode == .toggle {
                onClickToggleRecording?()
            } else {
                showMenu()
            }
        }
    }

    // MARK: - Public API: 更新状态

    /// 设置菜单栏图标状态
    /// - Parameters:
    ///   - state: 目标状态
    ///   - autoresetAfter: done 状态自动恢复为 idle 的延迟（秒），0 表示不自动恢复
    func setState(_ state: State, autoresetAfter delay: TimeInterval = 0) {
        // 取消之前的 done 计时器
        doneResetTimer?.cancel()
        doneResetTimer = nil

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.currentState = state
            self.statusItem.button?.image = self.iconImage(for: state)

            if state == .done && delay > 0 {
                // 设置自动恢复 timer
                let timer = DispatchSource.makeTimerSource(queue: .main)
                timer.schedule(deadline: .now() + delay)
                timer.setEventHandler { [weak self] in
                    self?.setState(.idle)
                }
                timer.resume()
                self.doneResetTimer = timer
            }
        }
    }

    // MARK: - SF Symbol Icons

    private func iconImage(for state: State) -> NSImage? {
        let symbolName: String
        let tintColor: NSColor

        switch state {
        case .idle:
            symbolName = "mic.fill"
            tintColor = .labelColor

        case .recording:
            symbolName = "mic.badge.plus"
            tintColor = .systemRed

        case .done:
            symbolName = "checkmark.circle.fill"
            tintColor = .systemGreen
        }

        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)

        guard let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else {
            // Fallback: 使用 Unicode 字符作为文本
            let fallback = NSImage(size: NSSize(width: 18, height: 18))
            return fallback
        }

        // 着色
        let tinted = image.copy() as! NSImage
        tinted.isTemplate = state == .idle  // idle 时用 template（自适应深/浅色）

        if state != .idle {
            // 非 idle 状态手动着色
            let colored = NSImage(size: image.size)
            colored.lockFocus()
            tintColor.set()
            let rect = NSRect(origin: .zero, size: image.size)
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
            rect.fill(using: .sourceAtop)
            colored.unlockFocus()
            return colored
        }

        return tinted
    }

    // MARK: - Menu Construction

    private func showMenu() {
        let menu = NSMenu()

        // ─── 标题 ───────────────────────────────────────
        let titleItem = NSMenuItem(title: "VoiceInput v\(UpdateChecker.currentVersion)", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        menu.addItem(.separator())

        // ─── 当前状态指示 ───────────────────────────────
        let stateText: String
        switch currentState {
        case .idle:      stateText = "⏸ 待机中"
        case .recording: stateText = "🔴 录音中..."
        case .done:      stateText = "✅ 识别完成"
        }
        let stateItem = NSMenuItem(title: stateText, action: nil, keyEquivalent: "")
        stateItem.isEnabled = false
        menu.addItem(stateItem)

        menu.addItem(.separator())

        // ─── 热键模式 ───────────────────────────────────
        let modeMenu = NSMenu()

        let pttItem = NSMenuItem(title: "Push-to-Talk (按住说话)", action: #selector(selectPTT), keyEquivalent: "")
        pttItem.target = self
        pttItem.state = settings.hotkeyMode == .pushToTalk ? .on : .off
        modeMenu.addItem(pttItem)

        let toggleItem = NSMenuItem(title: "Toggle (单击开/关)", action: #selector(selectToggle), keyEquivalent: "")
        toggleItem.target = self
        toggleItem.state = settings.hotkeyMode == .toggle ? .on : .off
        modeMenu.addItem(toggleItem)

        let modeItem = NSMenuItem(title: "模式: \(settings.hotkeyModeName)", action: nil, keyEquivalent: "")
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)

        // ─── 热键 ────────────────────────────────────────
        let hotkeyDisplayItem = NSMenuItem(
            title: "热键: \(settings.triggerKeyName)",
            action: #selector(changeHotkey),
            keyEquivalent: ""
        )
        hotkeyDisplayItem.target = self
        hotkeyDisplayItem.isEnabled = true
        menu.addItem(hotkeyDisplayItem)

        // ─── 模型 ────────────────────────────────────────
        let modelMenu = NSMenu()

        let int8Item = NSMenuItem(title: "int8 (快速，推荐)", action: #selector(selectModelInt8), keyEquivalent: "")
        int8Item.target = self
        int8Item.state = settings.modelType == "int8" ? .on : .off
        modelMenu.addItem(int8Item)

        let fp32Item = NSMenuItem(title: "float32 (精确，较慢)", action: #selector(selectModelFloat32), keyEquivalent: "")
        fp32Item.target = self
        fp32Item.state = settings.modelType == "float32" ? .on : .off
        modelMenu.addItem(fp32Item)

        let modelItem = NSMenuItem(title: "模型: \(settings.modelTypeName)", action: nil, keyEquivalent: "")
        modelItem.submenu = modelMenu
        menu.addItem(modelItem)

        // ─── 语言 ────────────────────────────────────────
        let langMenu = NSMenu()

        let langOptions: [(title: String, mode: String)] = [
            ("中文+英文（推荐）", "zh+en"),
            ("仅中文", "zh"),
            ("仅英文", "en"),
            ("自动（全部语言）", "auto"),
        ]

        for opt in langOptions {
            let item = NSMenuItem(title: opt.title, action: #selector(selectLanguageMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = opt.mode
            item.state = settings.languageMode == opt.mode ? .on : .off
            langMenu.addItem(item)
        }

        let langItem = NSMenuItem(title: "语言: \(settings.languageModeName)", action: nil, keyEquivalent: "")
        langItem.submenu = langMenu
        menu.addItem(langItem)

        // ─── Whisper 英文增强 ──────────────────────────────
        let whisperDir = SettingsManager.whisperModelDir
        let whisperInstalled = FileManager.default.fileExists(
            atPath: (whisperDir as NSString).appendingPathComponent("small.en-encoder.int8.onnx"))

        if whisperInstalled {
            let whisperItem = NSMenuItem(title: "✅ Whisper 英文增强已启用", action: nil, keyEquivalent: "")
            whisperItem.isEnabled = false
            menu.addItem(whisperItem)
        } else {
            let whisperItem = NSMenuItem(title: "⬇️ 下载 Whisper 英文增强", action: #selector(downloadWhisper), keyEquivalent: "")
            whisperItem.target = self
            menu.addItem(whisperItem)
        }

        menu.addItem(.separator())

        // ─── 权限状态 ─────────────────────────────────────
        let perms = PermissionManager.checkAll()

        let micTitle = perms.microphone
            ? "✅ 麦克风权限"
            : "❌ 麦克风权限（点击开启）"
        let micItem = NSMenuItem(
            title: micTitle,
            action: perms.microphone ? nil : #selector(requestMicPermission),
            keyEquivalent: ""
        )
        micItem.target = self
        micItem.isEnabled = !perms.microphone
        menu.addItem(micItem)

        let axTitle = perms.accessibility
            ? "✅ 辅助功能权限"
            : "⚠️ 辅助功能权限（点击开启）"
        let axItem = NSMenuItem(
            title: axTitle,
            action: perms.accessibility ? nil : #selector(openAccessibilitySettings),
            keyEquivalent: ""
        )
        axItem.target = self
        axItem.isEnabled = !perms.accessibility
        menu.addItem(axItem)

        menu.addItem(.separator())

        // ─── 开机启动 ─────────────────────────────────────
        let launchItem = NSMenuItem(
            title: "开机启动",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launchItem.target = self
        launchItem.state = settings.launchAtLogin ? .on : .off
        menu.addItem(launchItem)

        menu.addItem(.separator())

        // ─── AI 优化（LLM 后处理）─────────────────────────
        let llmEnabled = settings.llmPostProcessingEnabled && !settings.llmApiKey.isEmpty
        let llmStatusText = llmEnabled ? "✅ AI 优化已启用" : "AI 优化（去填充词/纠错）"

        let llmMenu = NSMenu()

        let llmToggleItem = NSMenuItem(
            title: settings.llmPostProcessingEnabled ? "关闭 AI 优化" : "开启 AI 优化",
            action: #selector(toggleLLM),
            keyEquivalent: ""
        )
        llmToggleItem.target = self
        llmMenu.addItem(llmToggleItem)

        llmMenu.addItem(.separator())

        let apiKeyStatus = settings.llmApiKey.isEmpty ? "❌ 未设置" : "✅ 已设置 (\(String(settings.llmApiKey.prefix(8)))...)"
        let apiKeyItem = NSMenuItem(title: "API Key: \(apiKeyStatus)", action: nil, keyEquivalent: "")
        llmMenu.addItem(apiKeyItem)

        let setApiKeyItem = NSMenuItem(
            title: "设置 API Key...",
            action: #selector(setLLMApiKey),
            keyEquivalent: ""
        )
        setApiKeyItem.target = self
        llmMenu.addItem(setApiKeyItem)

        llmMenu.addItem(.separator())

        let apiBaseItem = NSMenuItem(
            title: "API: \(settings.llmApiBaseURL.isEmpty ? "api.openai.com" : settings.llmApiBaseURL)",
            action: nil,
            keyEquivalent: ""
        )
        llmMenu.addItem(apiBaseItem)

        let setApiBaseItem = NSMenuItem(
            title: "设置 API 地址...",
            action: #selector(setLLMApiBase),
            keyEquivalent: ""
        )
        setApiBaseItem.target = self
        llmMenu.addItem(setApiBaseItem)

        llmMenu.addItem(.separator())

        let llmModelItem = NSMenuItem(title: "模型: \(settings.llmModel)", action: nil, keyEquivalent: "")
        llmMenu.addItem(llmModelItem)

        let setModelItem = NSMenuItem(
            title: "设置模型名...",
            action: #selector(setLLMModel),
            keyEquivalent: ""
        )
        setModelItem.target = self
        llmMenu.addItem(setModelItem)

        llmMenu.addItem(.separator())

        // 预设方案
        let presetsTitle = NSMenuItem(title: "── 快速预设 ──", action: nil, keyEquivalent: "")
        presetsTitle.isEnabled = false
        llmMenu.addItem(presetsTitle)

        // 云端预设
        let cloudTitle = NSMenuItem(title: "── 云端 API ──", action: nil, keyEquivalent: "")
        cloudTitle.isEnabled = false
        llmMenu.addItem(cloudTitle)

        let deepseekPreset = NSMenuItem(title: "🇨🇳 DeepSeek（国内直连）", action: #selector(presetDeepSeek), keyEquivalent: "")
        deepseekPreset.target = self
        llmMenu.addItem(deepseekPreset)

        let qwenPreset = NSMenuItem(title: "🇨🇳 通义千问（免费额度）", action: #selector(presetQwen), keyEquivalent: "")
        qwenPreset.target = self
        llmMenu.addItem(qwenPreset)

        let geminiPreset = NSMenuItem(title: "🔷 Gemini（需科学上网）", action: #selector(presetGemini), keyEquivalent: "")
        geminiPreset.target = self
        llmMenu.addItem(geminiPreset)

        let openaiPreset = NSMenuItem(title: "🟢 OpenAI（需科学上网）", action: #selector(presetOpenAI), keyEquivalent: "")
        openaiPreset.target = self
        llmMenu.addItem(openaiPreset)

        let groqPreset = NSMenuItem(title: "🟠 Groq（需科学上网）", action: #selector(presetGroq), keyEquivalent: "")
        groqPreset.target = self
        llmMenu.addItem(groqPreset)

        // 本地 Ollama 预设
        let localTitle = NSMenuItem(title: "── 本地 Ollama ──", action: nil, keyEquivalent: "")
        localTitle.isEnabled = false
        llmMenu.addItem(localTitle)

        let ollama3b = NSMenuItem(title: "🖥️ Qwen2.5-3B（极速，2GB）", action: #selector(presetOllama3B), keyEquivalent: "")
        ollama3b.target = self
        llmMenu.addItem(ollama3b)

        let ollama7b = NSMenuItem(title: "🖥️ Qwen2.5-7B（推荐，5GB）", action: #selector(presetOllama7B), keyEquivalent: "")
        ollama7b.target = self
        llmMenu.addItem(ollama7b)

        let ollama14b = NSMenuItem(title: "🖥️ Qwen2.5-14B（高质量，9GB）", action: #selector(presetOllama14B), keyEquivalent: "")
        ollama14b.target = self
        llmMenu.addItem(ollama14b)

        let ollama32b = NSMenuItem(title: "🖥️ Qwen2.5-32B（最强，20GB）", action: #selector(presetOllama32B), keyEquivalent: "")
        ollama32b.target = self
        llmMenu.addItem(ollama32b)

        let llmItem = NSMenuItem(title: llmStatusText, action: nil, keyEquivalent: "")
        llmItem.submenu = llmMenu
        menu.addItem(llmItem)

        menu.addItem(.separator())

        // ─── 检查更新 ─────────────────────────────────────
        let updateItem = NSMenuItem(
            title: "检查更新...",
            action: #selector(checkUpdate),
            keyEquivalent: ""
        )
        updateItem.target = self
        menu.addItem(updateItem)

        // ─── 退出 ─────────────────────────────────────────
        let quitItem = NSMenuItem(title: "退出 VoiceInput", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        // 显示菜单
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        // 显示后清除 menu 引用，确保下次按钮点击可以正常响应自定义 action
        statusItem.menu = nil
    }

    // MARK: - Menu Actions

    @objc private func selectPTT() {
        settings.hotkeyMode = .pushToTalk
        onHotkeyModeChanged?(.pushToTalk)
    }

    @objc private func selectToggle() {
        settings.hotkeyMode = .toggle
        onHotkeyModeChanged?(.toggle)
    }

    @objc private func selectModelInt8() {
        settings.modelType = "int8"
        onModelTypeChanged?("int8")
    }

    @objc private func selectLanguageMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? String else { return }
        settings.languageMode = mode
        fputs("[StatusBar] 语言模式切换: \(mode) (\(settings.languageModeName))\n", stderr)
    }

    @objc private func downloadWhisper() {
        onWhisperDownloadRequested?()
    }

    @objc private func selectModelFloat32() {
        // 检查 float32 模型是否存在（用户目录 或 bundle 内）
        let userPath = (SettingsManager.userModelDir as NSString).appendingPathComponent("model.onnx")
        let bundleDir = settings.resolveModelDir()
        let bundlePath = (bundleDir as NSString).appendingPathComponent("model.onnx")

        if FileManager.default.fileExists(atPath: userPath) ||
           FileManager.default.fileExists(atPath: bundlePath) {
            settings.modelType = "float32"
            onModelTypeChanged?("float32")
        } else {
            onFloat32ModelNeeded?(userPath)
        }
    }

    @objc private func requestMicPermission() {
        PermissionManager.requestMicrophone { granted in
            fputs("[StatusBar] 麦克风权限: \(granted ? "已授予" : "被拒绝")\n", stderr)
        }
    }

    @objc private func openAccessibilitySettings() {
        PermissionManager.openAccessibilitySettings()
    }

    @objc private func toggleLaunchAtLogin() {
        settings.launchAtLogin = !settings.launchAtLogin
        fputs("[StatusBar] 开机启动: \(settings.launchAtLogin)\n", stderr)
    }

    @objc private func quitApp() {
        onQuit?()
    }

    @objc private func changeHotkey() {
        onHotkeyRecordRequested?()
    }

    // MARK: - LLM Settings Actions

    @objc private func toggleLLM() {
        settings.llmPostProcessingEnabled = !settings.llmPostProcessingEnabled
        let state = settings.llmPostProcessingEnabled ? "开启" : "关闭"
        fputs("[StatusBar] AI 优化: \(state)\n", stderr)

        if settings.llmPostProcessingEnabled && settings.llmApiKey.isEmpty {
            // 开启但没有 API Key，提示设置
            setLLMApiKey()
        }
    }

    @objc private func setLLMApiKey() {
        DispatchQueue.main.async { [weak self] in
            let alert = NSAlert()
            alert.messageText = "设置 OpenAI API Key"
            alert.informativeText = "输入 API Key 以启用 AI 文本优化功能。\n支持 OpenAI 或兼容 API（如 DeepSeek、Groq）。\n\n留空则关闭 AI 优化。"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "保存")
            alert.addButton(withTitle: "取消")

            let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
            input.stringValue = self?.settings.llmApiKey ?? ""
            input.placeholderString = "sk-..."
            alert.accessoryView = input

            NSApp.activate(ignoringOtherApps: true)
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                let key = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                self?.settings.llmApiKey = key
                if !key.isEmpty {
                    self?.settings.llmPostProcessingEnabled = true
                }
                fputs("[StatusBar] API Key \(key.isEmpty ? "已清除" : "已设置")\n", stderr)
            }
        }
    }

    @objc private func setLLMApiBase() {
        DispatchQueue.main.async { [weak self] in
            let alert = NSAlert()
            alert.messageText = "设置 API 地址"
            alert.informativeText = "自定义 API 地址（兼容 OpenAI 接口）。\n留空使用默认 OpenAI 地址。\n\n示例：\nhttps://generativelanguage.googleapis.com/v1beta/openai (Gemini)\nhttps://api.groq.com/openai/v1 (Groq)\nhttps://api.deepseek.com/v1 (DeepSeek)"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "保存")
            alert.addButton(withTitle: "取消")

            let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
            input.stringValue = self?.settings.llmApiBaseURL ?? ""
            input.placeholderString = "https://api.openai.com/v1"
            alert.accessoryView = input

            NSApp.activate(ignoringOtherApps: true)
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                let url = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                self?.settings.llmApiBaseURL = url
                fputs("[StatusBar] API 地址: \(url.isEmpty ? "默认 (OpenAI)" : url)\n", stderr)
            }
        }
    }

    @objc private func setLLMModel() {
        DispatchQueue.main.async { [weak self] in
            let alert = NSAlert()
            alert.messageText = "设置 AI 模型"
            alert.informativeText = "输入模型名称。常用模型：\n\n• gpt-4o-mini (OpenAI, 推荐)\n• gemini-2.0-flash (Google, 免费)\n• llama-3.3-70b-versatile (Groq)\n• deepseek-chat (DeepSeek)"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "保存")
            alert.addButton(withTitle: "取消")

            let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
            input.stringValue = self?.settings.llmModel ?? "gpt-4o-mini"
            input.placeholderString = "gpt-4o-mini"
            alert.accessoryView = input

            NSApp.activate(ignoringOtherApps: true)
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                let model = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !model.isEmpty {
                    self?.settings.llmModel = model
                    fputs("[StatusBar] LLM 模型: \(model)\n", stderr)
                }
            }
        }
    }

    // MARK: - LLM Presets

    @objc private func presetGemini() {
        settings.llmApiBaseURL = "https://generativelanguage.googleapis.com/v1beta/openai"
        settings.llmModel = "gemini-2.0-flash"
        settings.llmPostProcessingEnabled = true
        fputs("[StatusBar] 预设: Gemini Flash (免费)\n", stderr)
        if settings.llmApiKey.isEmpty { setLLMApiKey() }
    }

    @objc private func presetOpenAI() {
        settings.llmApiBaseURL = "https://api.openai.com/v1"
        settings.llmModel = "gpt-4o-mini"
        settings.llmPostProcessingEnabled = true
        fputs("[StatusBar] 预设: OpenAI gpt-4o-mini\n", stderr)
        if settings.llmApiKey.isEmpty { setLLMApiKey() }
    }

    @objc private func presetGroq() {
        settings.llmApiBaseURL = "https://api.groq.com/openai/v1"
        settings.llmModel = "llama-3.3-70b-versatile"
        settings.llmPostProcessingEnabled = true
        fputs("[StatusBar] 预设: Groq Llama-3.3-70B\n", stderr)
        if settings.llmApiKey.isEmpty { setLLMApiKey() }
    }

    @objc private func presetDeepSeek() {
        settings.llmApiBaseURL = "https://api.deepseek.com"
        settings.llmModel = "deepseek-chat"
        settings.llmPostProcessingEnabled = true
        fputs("[StatusBar] 预设: DeepSeek (国内直连)\n", stderr)
        if settings.llmApiKey.isEmpty { setLLMApiKey() }
    }

    @objc private func presetQwen() {
        settings.llmApiBaseURL = "https://dashscope.aliyuncs.com/compatible-mode/v1"
        settings.llmModel = "qwen-turbo"
        settings.llmPostProcessingEnabled = true
        fputs("[StatusBar] 预设: 通义千问 Qwen-Turbo\n", stderr)
        if settings.llmApiKey.isEmpty { setLLMApiKey() }
    }

    // MARK: - Ollama Presets

    private func applyOllamaPreset(model: String, label: String) {
        settings.llmApiBaseURL = "http://localhost:11434/v1"
        settings.llmModel = model
        settings.llmApiKey = "ollama"  // Ollama 不校验 key，但字段不能为空
        settings.llmPostProcessingEnabled = true
        fputs("[StatusBar] 预设: 本地 Ollama \(label)\n", stderr)

        // 检测 Ollama 是否运行
        DispatchQueue.global().async {
            let url = URL(string: "http://localhost:11434/api/tags")!
            let task = URLSession.shared.dataTask(with: url) { data, response, error in
                if let error = error {
                    DispatchQueue.main.async {
                        let alert = NSAlert()
                        alert.messageText = "Ollama 未运行"
                        alert.informativeText = "请先启动 Ollama 并拉取模型：\n\n1. 启动 Ollama.app\n2. 终端运行：ollama pull \(model)\n3. 等待下载完成后重试"
                        alert.alertStyle = .warning
                        alert.addButton(withTitle: "好的")
                        NSApp.activate(ignoringOtherApps: true)
                        alert.runModal()
                    }
                    return
                }
                // 检查模型是否已下载
                if let data = data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let models = json["models"] as? [[String: Any]] {
                    let modelNames = models.compactMap { $0["name"] as? String }
                    let hasModel = modelNames.contains { $0.hasPrefix(model.replacingOccurrences(of: ":", with: ":")) }
                    if !hasModel {
                        DispatchQueue.main.async {
                            let alert = NSAlert()
                            alert.messageText = "模型未下载"
                            alert.informativeText = "Ollama 已运行，但模型 \(model) 尚未下载。\n\n请在终端运行：\n  ollama pull \(model)\n\n已安装的模型：\n\(modelNames.joined(separator: "\n"))"
                            alert.alertStyle = .informational
                            alert.addButton(withTitle: "好的")
                            NSApp.activate(ignoringOtherApps: true)
                            alert.runModal()
                        }
                    }
                }
            }
            task.resume()
        }
    }

    @objc private func presetOllama3B() {
        applyOllamaPreset(model: "qwen2.5:3b", label: "Qwen2.5-3B (极速)")
    }

    @objc private func presetOllama7B() {
        applyOllamaPreset(model: "qwen2.5:7b", label: "Qwen2.5-7B (推荐)")
    }

    @objc private func presetOllama14B() {
        applyOllamaPreset(model: "qwen2.5:14b", label: "Qwen2.5-14B (高质量)")
    }

    @objc private func presetOllama32B() {
        applyOllamaPreset(model: "qwen2.5:32b", label: "Qwen2.5-32B (最强)")
    }

    @objc private func checkUpdate() {
        onCheckUpdate?()
    }
}

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

    @objc private func selectModelFloat32() {
        // 检查 float32 模型是否存在
        let modelDir = settings.resolveModelDir()
        let float32Path = (modelDir as NSString).appendingPathComponent("model.onnx")

        if FileManager.default.fileExists(atPath: float32Path) {
            // 模型已存在，直接切换
            settings.modelType = "float32"
            onModelTypeChanged?("float32")
        } else {
            // 模型不存在，提示下载
            onFloat32ModelNeeded?(float32Path)
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

    @objc private func checkUpdate() {
        onCheckUpdate?()
    }
}

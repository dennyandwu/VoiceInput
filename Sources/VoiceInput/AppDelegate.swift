// Sources/VoiceInput/AppDelegate.swift
// MenuBar App 入口委托
// Phase 4: MenuBar GUI
// Copyright (c) 2026 urDAO Investment

import Foundation
import AppKit
// UserNotifications requires app bundle; use osascript fallback instead

/// AppDelegate 是 GUI 模式的核心协调器
///
/// 职责：
/// 1. 设置应用为 MenuBar-only（不显示 Dock 图标）
/// 2. 初始化并协调所有组件：StatusBar → HotkeyManager → RecognitionPipeline → TextInjector
/// 3. 管理完整 pipeline：热键 → 录音 → 识别 → 文本注入
/// 4. 响应设置变更（模型切换、模式切换）
final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Components

    private var statusBar: StatusBarController!
    private var hotkeyManager: HotkeyManager!
    private var pipeline: RecognitionPipeline?
    private var textInjector: TextInjector!
    private var recordingOverlay: RecordingOverlayWindow!
    private let settings = SettingsManager.shared

    // MARK: - State

    private var isRecording: Bool = false
    private var isLoadingModel: Bool = false
    private var recordStartTime: Date?

    /// 最短录音时长（秒），低于此值丢弃
    private let minRecordDuration: TimeInterval = 0.5

    // Pipeline 重载队列（避免并发加载）
    private let pipelineQueue = DispatchQueue(label: "com.urdao.voiceinput.pipeline", qos: .userInitiated)

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 不在 Dock 显示图标
        NSApp.setActivationPolicy(.accessory)

        // 初始化组件
        setupTextInjector()
        setupStatusBar()
        setupHotkeyManager()
        setupRecordingOverlay()
        setupAudioLevelCallback()

        // 请求通知权限（用于识别完成通知）
        requestNotificationPermission()

        // 异步加载模型（避免阻塞 UI 启动）
        loadPipelineAsync()

        fputs("[AppDelegate] VoiceInput GUI 模式已启动\n", stderr)
        fputs("[AppDelegate] 模型: \(settings.modelTypeName), 热键: \(settings.triggerKeyName), 模式: \(settings.hotkeyModeName)\n", stderr)
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyManager.stop()
        fputs("[AppDelegate] VoiceInput 已退出\n", stderr)
    }

    // MARK: - Component Setup

    private func setupTextInjector() {
        textInjector = TextInjector()
        textInjector.method = .clipboard
        textInjector.pasteDelayMs = 80
        textInjector.restoreDelayMs = 200
    }

    private func setupStatusBar() {
        statusBar = StatusBarController()

        statusBar.onClickToggleRecording = { [weak self] in
            self?.handleToggleRecording()
        }

        statusBar.onHotkeyModeChanged = { [weak self] mode in
            self?.applyHotkeyMode(mode)
        }

        statusBar.onModelTypeChanged = { [weak self] modelType in
            fputs("[AppDelegate] 模型已切换为: \(modelType)，重新加载引擎...\n", stderr)
            self?.loadPipelineAsync()
        }

        statusBar.onQuit = {
            NSApp.terminate(nil)
        }

        statusBar.onHotkeyRecordRequested = { [weak self] in
            self?.showHotkeyRecorder()
        }

        statusBar.onCheckUpdate = { [weak self] in
            self?.checkForUpdate()
        }
    }

    private func setupHotkeyManager() {
        hotkeyManager = HotkeyManager()
        applyHotkeyMode(settings.hotkeyMode)

        hotkeyManager.onRecordStart = { [weak self] in
            self?.handleRecordStart()
        }

        hotkeyManager.onRecordStop = { [weak self] in
            self?.handleRecordStop()
        }

        // 检查权限后启动
        if PermissionManager.checkAccessibility() {
            hotkeyManager.start()
        } else {
            fputs("[AppDelegate] ⚠️ 辅助功能权限未授予，热键不可用\n", stderr)
            PermissionManager.requestAccessibility()
            // 延迟重试，给用户时间去系统设置中授权
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                if PermissionManager.checkAccessibility() {
                    self?.hotkeyManager.start()
                    fputs("[AppDelegate] ✅ 辅助功能权限已获得，热键已启动\n", stderr)
                }
            }
        }
    }

    private func applyHotkeyMode(_ mode: HotkeyManager.Mode) {
        hotkeyManager.mode = mode
        hotkeyManager.triggerKeyCode = settings.triggerKeyCode
        fputs("[AppDelegate] 热键模式: \(mode == .pushToTalk ? "PTT" : "Toggle"), keyCode=0x\(String(settings.triggerKeyCode, radix: 16))\n", stderr)
    }

    // MARK: - Pipeline 加载

    /// 异步加载（或重新加载）识别引擎
    private func loadPipelineAsync() {
        guard !isLoadingModel else {
            fputs("[AppDelegate] 模型正在加载中，跳过重复请求\n", stderr)
            return
        }

        isLoadingModel = true
        statusBar.setState(.idle)

        pipelineQueue.async { [weak self] in
            guard let self = self else { return }

            let modelPath  = self.settings.resolveModelPath()
            let tokensPath = self.settings.resolveTokensPath()
            let sileroPath = self.settings.resolveSileroModelPath()

            fputs("[AppDelegate] 加载模型: \(modelPath)\n", stderr)
            fputs("[AppDelegate] Tokens:   \(tokensPath)\n", stderr)
            fputs("[AppDelegate] Silero:   \(sileroPath)\n", stderr)

            let newPipeline = RecognitionPipeline(
                modelPaths: (model: modelPath, tokens: tokensPath),
                sileroModelPath: sileroPath,
                useVAD: true,
                numThreads: 4
            )

            DispatchQueue.main.async {
                self.isLoadingModel = false
                if newPipeline.modelLoaded {
                    self.pipeline = newPipeline
                    fputs("[AppDelegate] ✅ 模型加载成功 (\(self.settings.modelTypeName))\n", stderr)
                } else {
                    fputs("[AppDelegate] ❌ 模型加载失败！请检查模型文件路径\n", stderr)
                    self.showAlert(
                        title: "VoiceInput — 模型加载失败",
                        message: "无法加载识别模型：\(modelPath)\n请检查模型文件是否存在。"
                    )
                }
            }
        }
    }

    // MARK: - 录音控制

    private func handleToggleRecording() {
        if isRecording {
            handleRecordStop()
        } else {
            handleRecordStart()
        }
    }

    private func handleRecordStart() {
        guard !isRecording else { return }
        guard let p = pipeline else {
            fputs("[AppDelegate] ⚠️ 模型未加载，无法开始录音\n", stderr)
            if isLoadingModel {
                fputs("[AppDelegate] 模型正在加载中，请稍候...\n", stderr)
            } else {
                loadPipelineAsync()
            }
            return
        }

        guard PermissionManager.checkMicrophone() else {
            fputs("[AppDelegate] ⚠️ 麦克风权限未授予\n", stderr)
            PermissionManager.requestMicrophone { [weak self] granted in
                if granted {
                    self?.handleRecordStart()
                }
            }
            return
        }

        fputs("[AppDelegate] 🎙️ 开始录音\n", stderr)
        isRecording = true
        recordStartTime = Date()
        statusBar.setState(.recording)

        // 播放开始录音提示音
        NSSound(named: "Tink")?.play()

        // 显示录音悬浮窗
        recordingOverlay.show()

        // 设置音频电平回调
        p.recorder.onAudioBuffer = { [weak self] samples in
            self?.feedAudioLevel(samples)
        }

        if !p.startListening() {
            fputs("[AppDelegate] ❌ 无法启动录音\n", stderr)
            isRecording = false
            statusBar.setState(.idle)
        }
    }

    private func handleRecordStop() {
        guard isRecording else { return }
        guard let p = pipeline else { return }

        fputs("[AppDelegate] ⏹ 停止录音，识别中...\n", stderr)
        isRecording = false

        // 播放停止录音提示音
        NSSound(named: "Pop")?.play()

        // 更新悬浮窗状态
        recordingOverlay.setStatus("识别中...")

        // 检查最短录音时长
        let duration = recordStartTime.map { Date().timeIntervalSince($0) } ?? 0
        if duration < minRecordDuration {
            fputs("[AppDelegate] ⚠️ 录音太短 (\(String(format: "%.2f", duration))s < \(minRecordDuration)s)，已丢弃\n", stderr)
            _ = p.stopListening()  // 丢弃结果
            statusBar.setState(.idle)
            recordingOverlay.hide()
            return
        }

        // 停止录音 + 识别在后台队列执行（避免阻塞主线程）
        pipelineQueue.async { [weak self] in
            guard let self = self else { return }

            let result = p.stopListening()

            DispatchQueue.main.async {
                self.handleRecognitionResult(result)
            }
        }
    }

    // MARK: - 识别结果处理

    private func handleRecognitionResult(_ result: PipelineResult) {
        // 后处理：清理识别结果
        let cleanedText = TextPostProcessor.clean(result.text)
        let lang = result.lang.isEmpty ? TextPostProcessor.extractLanguage(result.text) : result.lang
        let langName = TextPostProcessor.languageName(lang)

        if cleanedText.isEmpty {
            fputs("[AppDelegate] ℹ️ 识别结果为空或无意义（原文: \"\(result.text)\"）\n", stderr)
            recordingOverlay.setStatus("未检测到有效语音")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.recordingOverlay.hide()
            }
            statusBar.setState(.idle)
            return
        }

        fputs("[AppDelegate] ✅ 识别结果: \"\(cleanedText)\" [lang=\(lang), RTF=\(String(format: "%.3f", result.processingTime / max(result.duration, 0.001)))]\n", stderr)

        // 更新悬浮窗显示结果
        let displayLang = langName.isEmpty ? "" : "[\(langName)] "
        recordingOverlay.setStatus("\(displayLang)\(cleanedText)")

        // 延迟隐藏悬浮窗（让用户看到结果）
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.recordingOverlay.hide()
        }

        // 更新图标为完成状态
        statusBar.setState(.done, autoresetAfter: 1.0)

        // 注入文本到当前焦点输入框
        let injected = textInjector.inject(text: cleanedText)
        if !injected {
            fputs("[AppDelegate] ⚠️ 文本注入失败\n", stderr)
        }

        // 发送系统通知（如果设置了）
        if settings.showNotification {
            sendNotification(text: cleanedText, lang: lang)
        }
    }

    // MARK: - 系统通知

    private func requestNotificationPermission() {
        // No-op: notifications use osascript, no permission needed
    }

    private func sendNotification(text: String, lang: String) {
        let title = "VoiceInput"
        let subtitle = lang.isEmpty ? "" : "[\(lang)] "
        let body = "\(subtitle)\(text)"
        let script = "display notification \"\(body.replacingOccurrences(of: "\"", with: "\\\""))\" with title \"\(title)\""
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        try? proc.run()
    }

    // MARK: - Alert

    private func showAlert(title: String, message: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.addButton(withTitle: "好的")
            alert.runModal()
        }
    }

    // MARK: - Recording Overlay

    private func setupRecordingOverlay() {
        recordingOverlay = RecordingOverlayWindow()
    }

    private func setupAudioLevelCallback() {
        // 在 pipeline 加载完成后设置 audio buffer 回调
        // 每次 loadPipelineAsync 完成后也需要调用
    }

    /// 更新悬浮窗的音频电平
    private func feedAudioLevel(_ samples: [Float]) {
        // RMS 计算
        guard !samples.isEmpty else { return }
        let sum = samples.reduce(Float(0)) { $0 + $1 * $1 }
        let rms = sqrt(sum / Float(samples.count))
        // 归一化到 0~1（假设最大 RMS ~0.3）
        let level = min(rms / 0.3, 1.0)
        recordingOverlay.updateLevel(level)
    }

    // MARK: - Hotkey Recorder

    private func showHotkeyRecorder() {
        let recorder = HotkeyRecorderWindow()
        recorder.onKeyRecorded = { [weak self] keyCode, name in
            guard let self = self else { return }
            fputs("[AppDelegate] 新热键: keyCode=0x\(String(keyCode, radix: 16)) (\(name))\n", stderr)

            // 保存设置
            self.settings.triggerKeyCode = keyCode

            // 重启 HotkeyManager
            self.hotkeyManager.stop()
            self.hotkeyManager.triggerKeyCode = keyCode
            self.hotkeyManager.start()

            fputs("[AppDelegate] 热键已更新为: \(name)\n", stderr)
        }
        recorder.show()
    }

    // MARK: - Update Checker

    private func checkForUpdate() {
        fputs("[AppDelegate] 检查更新...\n", stderr)

        UpdateChecker.checkForUpdate { [weak self] release, error in
            DispatchQueue.main.async {
                if let error = error {
                    fputs("[AppDelegate] 检查更新失败: \(error.localizedDescription)\n", stderr)
                    self?.showAlert(title: "检查更新失败", message: error.localizedDescription)
                    return
                }

                guard let release = release else {
                    self?.showAlert(title: "检查更新", message: "无法获取版本信息")
                    return
                }

                let current = UpdateChecker.currentVersion
                if UpdateChecker.isNewerVersion(release.version, than: current) {
                    self?.showUpdateAlert(release: release)
                } else {
                    self?.showAlert(title: "已是最新版本",
                        message: "当前版本 v\(current) 已是最新。")
                }
            }
        }
    }

    private func showUpdateAlert(release: UpdateChecker.ReleaseInfo) {
        let alert = NSAlert()
        alert.messageText = "发现新版本 \(release.tagName)"
        alert.informativeText = """
        当前版本: v\(UpdateChecker.currentVersion)
        最新版本: \(release.tagName)

        更新内容:
        \(release.body.prefix(500))
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "下载更新")
        alert.addButton(withTitle: "稍后再说")

        if release.dmgURL != nil {
            alert.addButton(withTitle: "打开 GitHub")
        }

        let response = alert.runModal()

        switch response {
        case .alertFirstButtonReturn:
            if let dmgURL = release.dmgURL {
                downloadUpdate(dmgURL: dmgURL)
            } else {
                UpdateChecker.openReleasesPage()
            }
        case .alertThirdButtonReturn:
            UpdateChecker.openReleasesPage()
        default:
            break
        }
    }

    private func downloadUpdate(dmgURL: String) {
        fputs("[AppDelegate] 下载更新: \(dmgURL)\n", stderr)
        // TODO: 进度条 UI
        UpdateChecker.downloadAndInstall(dmgURL: dmgURL, progress: { progress in
            fputs("[AppDelegate] 下载进度: \(Int(progress * 100))%\n", stderr)
        }) { [weak self] success, error in
            if success {
                fputs("[AppDelegate] ✅ 下载完成，DMG 已打开\n", stderr)
                // 提示用户替换 app
                self?.showAlert(title: "下载完成",
                    message: "DMG 已打开。请将新版 VoiceInput.app 拖到 /Applications 替换旧版本，然后重启。")
            } else if let error = error {
                fputs("[AppDelegate] ❌ 下载失败: \(error.localizedDescription)\n", stderr)
                self?.showAlert(title: "下载失败", message: error.localizedDescription)
            }
        }
    }
}

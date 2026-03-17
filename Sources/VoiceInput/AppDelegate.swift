// Sources/VoiceInput/AppDelegate.swift
// MenuBar App 入口委托
// Phase 4: MenuBar GUI
// Copyright (c) 2026 urDAO Investment

import Foundation
import AppKit
import UserNotifications
import os
// UserNotifications requires app bundle; use osascript fallback instead

/// AppDelegate 是 GUI 模式的核心协调器
///
/// 职责：
/// 1. 设置应用为 MenuBar-only（不显示 Dock 图标）
/// 2. 初始化并协调所有组件：StatusBar → HotkeyManager → RecognitionPipeline → TextInjector
/// 3. 管理完整 pipeline：热键 → 录音 → 识别 → 文本注入
/// 4. 响应设置变更（模型切换、模式切换）
final class AppDelegate: NSObject, NSApplicationDelegate {

    private static let logger = Logger(subsystem: "com.urdao.voiceinput", category: "AppDelegate")

    // MARK: - Components

    private var statusBar: StatusBarController!
    private var hotkeyManager: HotkeyManager!
    private var pipeline: RecognitionPipeline?
    private var textInjector: TextInjector!
    private var recordingOverlay: RecordingOverlayWindow!
    private var hotkeyRecorder: HotkeyRecorderWindow?
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
        // 初始化用户数据目录
        SettingsManager.ensureAppSupportDir()

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

        // 初始化词库（Phase 1: SQLite 词库系统）
        _ = WordLibraryManager.shared  // 触发单例初始化

        // 后台静默检查更新（延迟 10s，避开启动期）
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard UpdateChecker.shouldPeriodicCheck else { return }
            UpdateChecker.checkForUpdateSilent { [weak self] release in
                guard let release = release else { return }
                DispatchQueue.main.async {
                    self?.showUpdateAlert(release: release)
                }
            }
        }

        Self.logger.info("VoiceInput GUI 模式已启动")
        Self.logger.info("模型: \(self.settings.modelTypeName), 热键: \(self.settings.triggerKeyName), 模式: \(self.settings.hotkeyModeName)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyManager.stop()
        Self.logger.info("VoiceInput 已退出")
    }

    // MARK: - Component Setup

    private func setupTextInjector() {
        textInjector = TextInjector()
        textInjector.method = .keyboard  // CGEvent Unicode，不污染剪贴板
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
            Self.logger.info("模型已切换为: \(modelType)，重新加载引擎...")
            self?.loadPipelineAsync()
        }

        statusBar.onFloat32ModelNeeded = { [weak self] destPath in
            self?.downloadFloat32Model(to: destPath)
        }

        statusBar.onWhisperDownloadRequested = { [weak self] in
            self?.downloadWhisperModel()
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
            Self.logger.warning("⚠️ 辅助功能权限未授予，热键不可用")
            PermissionManager.requestAccessibility()
            // 延迟重试，给用户时间去系统设置中授权
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                if PermissionManager.checkAccessibility() {
                    self?.hotkeyManager.start()
                    Self.logger.info("✅ 辅助功能权限已获得，热键已启动")
                }
            }
        }
    }

    private func applyHotkeyMode(_ mode: HotkeyManager.Mode) {
        hotkeyManager.mode = mode
        hotkeyManager.triggerKeyCode = settings.triggerKeyCode
        Self.logger.info("热键模式: \(mode == .pushToTalk ? "PTT" : "Toggle"), keyCode=0x\(String(self.settings.triggerKeyCode, radix: 16))")
    }

    // MARK: - Pipeline 加载

    /// 异步加载（或重新加载）识别引擎
    private func loadPipelineAsync() {
        guard !isLoadingModel else {
            Self.logger.info("模型正在加载中，跳过重复请求")
            return
        }

        isLoadingModel = true
        statusBar.setState(.idle)

        pipelineQueue.async { [weak self] in
            guard let self = self else { return }

            let modelPath  = self.settings.resolveModelPath()
            let tokensPath = self.settings.resolveTokensPath()
            let sileroPath = self.settings.resolveSileroModelPath()

            Self.logger.info("加载模型: \(modelPath)")
            Self.logger.info("Tokens:   \(tokensPath)")
            Self.logger.info("Silero:   \(sileroPath)")

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
                    Self.logger.info("✅ 模型加载成功 (\(self.settings.modelTypeName))")

                    // 尝试加载 Whisper（英文增强，可选）
                    self.tryLoadWhisper(engine: newPipeline.engine)
                } else {
                    Self.logger.error("❌ 模型加载失败！请检查模型文件路径")
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
            Self.logger.warning("⚠️ 模型未加载，无法开始录音")
            if isLoadingModel {
                Self.logger.info("模型正在加载中，请稍候...")
            } else {
                loadPipelineAsync()
            }
            return
        }

        guard PermissionManager.checkMicrophone() else {
            Self.logger.warning("⚠️ 麦克风权限未授予")
            PermissionManager.requestMicrophone { [weak self] granted in
                if granted {
                    self?.handleRecordStart()
                }
            }
            return
        }

        Self.logger.info("🎙️ 开始录音")
        isRecording = true
        recordStartTime = Date()
        statusBar.setState(.recording)

        // 播放开始录音提示音
        NSSound(named: "Tink")?.play()

        // 显示录音悬浮窗
        recordingOverlay.show()

        // 注意：不要在这里设置 onAudioBuffer，Pipeline.startListening() 会设置 VAD 回调
        // 悬浮窗音频电平通过 Pipeline 的回调链获取

        if !p.startListening() {
            Self.logger.error("❌ 无法启动录音")
            isRecording = false
            statusBar.setState(.idle)
            recordingOverlay.hide()
            return
        }

        // startListening() 之后，在 VAD 回调基础上叠加悬浮窗电平更新
        let originalCallback = p.recorder.onAudioBuffer
        p.recorder.onAudioBuffer = { [weak self] samples in
            // 先调用 VAD 的原始回调
            originalCallback?(samples)
            // 再更新悬浮窗电平
            self?.feedAudioLevel(samples)
        }
    }

    private func handleRecordStop() {
        guard isRecording else { return }
        guard let p = pipeline else { return }

        Self.logger.info("⏹ 停止录音，识别中...")
        isRecording = false

        // 播放停止录音提示音
        NSSound(named: "Pop")?.play()

        // 更新悬浮窗状态
        recordingOverlay.setStatus("识别中...")

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
        let rawText = result.text
        let cleanedText = TextPostProcessor.clean(rawText)
        var lang = result.lang.isEmpty ? TextPostProcessor.extractLanguage(rawText) : result.lang

        // 语言白名单过滤
        let allowed = settings.allowedLanguages
        let filtered = TextPostProcessor.filterByLanguage(cleanedText.isEmpty ? rawText : cleanedText, detectedLang: lang, allowed: allowed)
        lang = filtered.lang
        let filteredText = filtered.text  // 使用过滤后的文本（日语假名等已清除）
        let langName = TextPostProcessor.languageName(lang)

        // 优先用过滤后文本，若为空但原文有内容则用原文（去 token 后）
        var processedText: String
        if !filteredText.isEmpty && filteredText.count > 1 {
            processedText = filteredText
        } else {
            // 去掉 SenseVoice token 但保留原始内容
            let stripped = rawText.replacingOccurrences(of: #"<\|[^|]+\|>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // 对降级文本也做语言过滤
            let strippedFiltered = TextPostProcessor.filterByLanguage(stripped, detectedLang: lang, allowed: allowed).text
            let finalStripped = strippedFiltered.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            if !finalStripped.isEmpty {
                processedText = strippedFiltered
                // 隐私：不记录具体文本内容，只记录长度
                Self.logger.info("ℹ️ PostProcessor 过滤了原文，降级使用去 token 文本（长度: \(strippedFiltered.count) 字符）")
            } else {
                Self.logger.info("ℹ️ 识别结果为空或无意义（原文长度: \(rawText.count) 字符）")
                recordingOverlay.setStatus("未检测到有效语音")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                    self?.recordingOverlay.hide()
                }
                statusBar.setState(.idle)
                return
            }
        }

        // 词库修正（Phase 1: SQLite 词库系统）
        let beforeCorrection = processedText
        processedText = WordLibraryManager.shared.applyCorrections(to: processedText)
        if processedText != beforeCorrection {
            // 隐私：不记录具体文本内容
            Self.logger.info("📚 词库修正: \(beforeCorrection.count) 字符 → \(processedText.count) 字符")
        }

        // LLM 后处理（可选，需用户开启 + 配置 API Key）
        let llm = LLMPostProcessor.shared
        if llm.isEnabled {
            let beforeLLM = processedText
            processedText = llm.process(processedText)
            if processedText != beforeLLM {
                // 隐私：不记录具体文本内容
                Self.logger.info("🤖 LLM 优化: \(beforeLLM.count) 字符 → \(processedText.count) 字符")
            }
        }

        let finalText = processedText

        Self.logger.info("✅ 识别完成 [lang=\(lang), RTF=\(String(format: "%.3f", result.processingTime / max(result.duration, 0.001))), 长度=\(finalText.count) 字符]")

        // 更新悬浮窗显示结果
        let displayLang = langName.isEmpty ? "" : "[\(langName)] "
        recordingOverlay.setStatus("\(displayLang)\(finalText)")

        // 更新图标为完成状态
        statusBar.setState(.done, autoresetAfter: 1.0)

        // 关键流程（参考 open-typeless）：
        // 1. 先隐藏悬浮窗，让焦点回到原应用
        // 2. 等待 100ms 让焦点切换完成
        // 3. 再注入文本
        recordingOverlay.hide()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }
            let injected = self.textInjector.inject(text: finalText)
            if !injected {
                Self.logger.warning("⚠️ 文本注入失败")
            }
        }

        // 发送系统通知（如果设置了）
        if settings.showNotification {
            sendNotification(text: finalText, lang: lang)
        }
    }

    // MARK: - 系统通知

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                Self.logger.error("通知权限请求失败: \(error.localizedDescription)")
            }
            Self.logger.info("通知权限: \(granted ? "已授权" : "未授权")")
        }
    }

    private func sendNotification(text: String, lang: String) {
        let content = UNMutableNotificationContent()
        content.title = "VoiceInput"
        content.body = lang.isEmpty ? text : "[\(lang)] \(text)"
        content.sound = nil

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil  // 立即发送
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                Self.logger.error("通知发送失败: \(error.localizedDescription)")
            }
        }
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
        self.hotkeyRecorder = recorder  // 防止 ARC 释放
        recorder.onKeyRecorded = { [weak self] keyCode, name in
            guard let self = self else { return }
            Self.logger.info("新热键: keyCode=0x\(String(keyCode, radix: 16)) (\(name))")

            // 保存设置
            self.settings.triggerKeyCode = keyCode

            // 重启 HotkeyManager
            self.hotkeyManager.stop()
            self.hotkeyManager.triggerKeyCode = keyCode
            self.hotkeyManager.start()

            Self.logger.info("热键已更新为: \(name)")
            self.hotkeyRecorder = nil  // 释放
        }
        recorder.show()
    }

    // MARK: - Update Checker

    private func checkForUpdate() {
        Self.logger.info("检查更新...")

        UpdateChecker.checkForUpdate { [weak self] release, error in
            DispatchQueue.main.async {
                if let error = error {
                    Self.logger.error("检查更新失败: \(error.localizedDescription)")
                    self?.showAlert(title: "检查更新失败", message: error.localizedDescription)
                    return
                }

                guard let release = release else {
                    self?.showAlert(title: "检查更新", message: "无法获取版本信息")
                    return
                }

                let current = UpdateChecker.currentVersion
                let isNewer = UpdateChecker.isNewerVersion(release.version, than: current)
                Self.logger.info("版本比较: remote=\(release.version) vs local=\(current) → isNewer=\(isNewer)")

                if isNewer {
                    self?.showUpdateAlert(release: release)
                } else {
                    self?.showAlert(title: "已是最新版本",
                        message: "当前版本 v\(current) 已是最新。")
                }
            }
        }
    }

    private func showUpdateAlert(release: UpdateChecker.ReleaseInfo) {
        let sizeStr = release.dmgSize > 0 ? "\(release.dmgSize / 1024 / 1024)MB" : "未知大小"
        let changelog = UpdateChecker.formatChangelog(release.body)

        let alert = NSAlert()
        alert.messageText = "发现新版本 \(release.tagName)"
        alert.informativeText = """
        当前版本: v\(UpdateChecker.currentVersion)
        最新版本: \(release.tagName)
        下载大小: \(sizeStr)

        更新内容:
        \(changelog)
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "自动更新")
        alert.addButton(withTitle: "稍后再说")
        alert.addButton(withTitle: "跳过此版本")

        let response = alert.runModal()

        if response == .alertFirstButtonReturn, let dmgURL = release.dmgURL {
            performAutoUpdate(dmgURL: dmgURL, expectedSize: release.dmgSize)
        } else if response == .alertThirdButtonReturn {
            UpdateChecker.skipVersion(release.version)
        }
    }

    private func performAutoUpdate(dmgURL: String, expectedSize: Int64) {
        Self.logger.info("开始自动更新: \(dmgURL)")

        UpdateChecker.autoUpdate(dmgURL: dmgURL, expectedSize: expectedSize, progress: { pct, status in
            Self.logger.info("\(status)")
        }) { [weak self] success, error in
            if !success {
                let msg = error?.localizedDescription ?? "未知错误"
                Self.logger.error("❌ 自动更新失败: \(msg)")
                self?.showAlert(title: "更新失败", message: msg)
            }
        }
    }

    // MARK: - Whisper 英文增强引擎

    /// 尝试加载 Whisper 模型（如果已下载）
    private func tryLoadWhisper(engine: SpeechEngine) {
        let model = settings.whisperModel
        let whisperDir = SettingsManager.whisperModelDir
        let encoderPath = (whisperDir as NSString).appendingPathComponent(model.encoderFile)
        let decoderPath = (whisperDir as NSString).appendingPathComponent(model.decoderFile)
        let tokensPath = (whisperDir as NSString).appendingPathComponent(model.tokensFile)

        guard FileManager.default.fileExists(atPath: encoderPath) else {
            Self.logger.info("Whisper \(model.rawValue) 模型未安装（菜单可下载）")
            return
        }

        pipelineQueue.async {
            let success = engine.loadWhisper(encoderPath: encoderPath, decoderPath: decoderPath, tokensPath: tokensPath)
            if success {
                Self.logger.info("✅ Whisper \(model.rawValue) 已启用")
            }
        }
    }

    /// 下载 Whisper 模型
    private func downloadWhisperModel() {
        let model = settings.whisperModel
        let alert = NSAlert()
        alert.messageText = "下载 Whisper 模型"
        alert.informativeText = """
        \(model.displayName)

        安装后，短音频(<2s)和纯英文语音会使用 Whisper 识别。
        中文长句仍使用 SenseVoice。

        是否下载？
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "下载")
        alert.addButton(withTitle: "取消")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        Self.logger.info("开始下载 Whisper 模型...")
        SettingsManager.ensureAppSupportDir()

        guard let url = URL(string: model.downloadURL) else { return }

        let task = URLSession.shared.downloadTask(with: url) { [weak self] tempURL, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    Self.logger.error("❌ Whisper 下载失败: \(error.localizedDescription)")
                    self?.showAlert(title: "下载失败", message: error.localizedDescription)
                    return
                }

                guard let tempURL = tempURL else {
                    self?.showAlert(title: "下载失败", message: "临时文件为空")
                    return
                }

                Self.logger.info("Whisper 下载完成，解压中...")

                let extractDir = FileManager.default.temporaryDirectory.appendingPathComponent("whisper-extract")
                try? FileManager.default.removeItem(at: extractDir)
                try? FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)

                let tarPath = extractDir.appendingPathComponent("whisper.tar.bz2")
                try? FileManager.default.moveItem(at: tempURL, to: tarPath)

                let tar = Process()
                tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
                tar.arguments = ["xjf", tarPath.path, "-C", extractDir.path]
                try? tar.run()
                tar.waitUntilExit()

                // 查找 encoder 文件并复制所有模型文件到 whisper 目录
                let fm = FileManager.default
                let whisperDir = SettingsManager.whisperModelDir
                var found = false

                if let enumerator = fm.enumerator(at: extractDir, includingPropertiesForKeys: nil) {
                    for case let fileURL as URL in enumerator {
                        let name = fileURL.lastPathComponent
                        // H4: 路径验证防 Zip Slip
                        let resolved = fileURL.standardizedFileURL.path
                        guard resolved.hasPrefix(extractDir.path) else {
                            Self.logger.warning("⚠️ 路径穿越检测，跳过: \(resolved)")
                            continue
                        }
                        // 复制所有 .onnx 和 tokens.txt 文件
                        if name.hasSuffix(".onnx") || name.contains("tokens") {
                            // H5: 验证 onnx 文件最小大小（防截断/空文件）
                            if name.hasSuffix(".onnx") {
                                let attrs = try? fm.attributesOfItem(atPath: fileURL.path)
                                let size = (attrs?[.size] as? Int64) ?? 0
                                if size < 1_000_000 {  // < 1MB 的 onnx 文件视为异常
                                    Self.logger.warning("⚠️ 模型文件过小，跳过: \(name) (\(size) bytes)")
                                    continue
                                }
                            }
                            let destPath = (whisperDir as NSString).appendingPathComponent(name)
                            try? fm.removeItem(atPath: destPath)
                            try? fm.copyItem(atPath: fileURL.path, toPath: destPath)
                            Self.logger.info("复制: \(name)")
                            if name.contains("encoder") { found = true }
                        }
                    }
                }

                try? fm.removeItem(at: extractDir)

                if found {
                    Self.logger.info("✅ Whisper 模型已安装")
                    // 立即加载
                    if let pipeline = self?.pipeline {
                        self?.tryLoadWhisper(engine: pipeline.engine)
                    }
                    self?.showAlert(title: "Whisper 已安装",
                        message: "\(model.displayName) 已安装。短音频和英文语音将自动使用 Whisper 识别。")
                } else {
                    self?.showAlert(title: "安装失败", message: "解压后未找到 Whisper 模型文件")
                }
            }
        }

        task.resume()
        let sizeHint = model == .smallEn ? "约 200MB" : "约 1GB"
        showAlert(title: "正在下载", message: "Whisper \(model.displayName)（\(sizeHint)）正在后台下载。\n完成后会自动安装并启用。")
    }

    // MARK: - Float32 模型下载

    /// sherpa-onnx SenseVoice float32 模型下载 URL
    private static let float32ModelURL = "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17.tar.bz2"
    private static let float32ModelSize: Int64 = 894_000_000  // ~894MB

    private func downloadFloat32Model(to destPath: String) {
        // 下载到用户数据目录，不放 app bundle 内
        let actualDest = (SettingsManager.userModelDir as NSString).appendingPathComponent("model.onnx")
        SettingsManager.ensureAppSupportDir()
        let alert = NSAlert()
        alert.messageText = "下载 float32 模型"
        alert.informativeText = """
        float32 模型（894MB）尚未安装。

        float32 精度更高，但体积更大、速度稍慢。
        int8 模型精度损失 <1%，推荐日常使用。

        是否下载 float32 模型？
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "下载")
        alert.addButton(withTitle: "取消")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        Self.logger.info("开始下载 float32 模型...")

        let modelDir = SettingsManager.userModelDir

        // 确保目录存在
        try? FileManager.default.createDirectory(atPath: modelDir, withIntermediateDirectories: true)

        guard let url = URL(string: Self.float32ModelURL) else { return }

        let task = URLSession.shared.downloadTask(with: url) { [weak self] tempURL, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    Self.logger.error("❌ float32 下载失败: \(error.localizedDescription)")
                    self?.showAlert(title: "下载失败", message: error.localizedDescription)
                    return
                }

                guard let tempURL = tempURL else {
                    self?.showAlert(title: "下载失败", message: "临时文件为空")
                    return
                }

                // 解压 tar.bz2 → 提取 model.onnx
                Self.logger.info("下载完成，解压中...")

                let extractDir = FileManager.default.temporaryDirectory.appendingPathComponent("float32-extract")
                try? FileManager.default.removeItem(at: extractDir)
                try? FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)

                // 先移动到 .tar.bz2 文件
                let tarPath = extractDir.appendingPathComponent("model.tar.bz2")
                try? FileManager.default.moveItem(at: tempURL, to: tarPath)

                // 解压
                let tar = Process()
                tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
                tar.arguments = ["xjf", tarPath.path, "-C", extractDir.path]
                tar.currentDirectoryURL = extractDir
                try? tar.run()
                tar.waitUntilExit()

                // 查找 model.onnx
                let fm = FileManager.default
                if let enumerator = fm.enumerator(at: extractDir, includingPropertiesForKeys: nil) {
                    for case let fileURL as URL in enumerator {
                        if fileURL.lastPathComponent == "model.onnx" {
                            let attrs = try? fm.attributesOfItem(atPath: fileURL.path)
                            let size = (attrs?[.size] as? Int64) ?? 0

                            if size > 500_000_000 {  // 应该 >500MB
                                do {
                                    try? fm.removeItem(atPath: actualDest)
                                    try fm.copyItem(atPath: fileURL.path, toPath: actualDest)
                                    Self.logger.info("✅ float32 模型已安装: \(actualDest) (\(size / 1024 / 1024)MB)")

                                    // 切换到 float32 并重新加载
                                    self?.settings.modelType = "float32"
                                    self?.loadPipelineAsync()

                                    self?.showAlert(title: "模型下载完成",
                                        message: "float32 模型已安装（\(size / 1024 / 1024)MB），已自动切换。")
                                } catch {
                                    Self.logger.error("❌ 复制 model.onnx 失败: \(error.localizedDescription)")
                                    self?.showAlert(title: "安装失败", message: error.localizedDescription)
                                }
                            } else {
                                self?.showAlert(title: "安装失败", message: "model.onnx 文件异常（\(size) bytes）")
                            }

                            // 清理
                            try? fm.removeItem(at: extractDir)
                            return
                        }
                    }
                }

                self?.showAlert(title: "安装失败", message: "解压后未找到 model.onnx")
                try? fm.removeItem(at: extractDir)
            }
        }

        task.resume()
        showAlert(title: "正在下载", message: "float32 模型（894MB）正在后台下载，完成后会自动安装并切换。\n\n下载过程中可以继续使用 int8 模型。")
    }
}

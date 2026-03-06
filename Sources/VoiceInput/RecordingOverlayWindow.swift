// Sources/VoiceInput/RecordingOverlayWindow.swift
// 录音状态悬浮窗 — 显示录音波形和计时
// Phase 6: 录音反馈 UI
// Copyright (c) 2026 urDAO Investment

import Foundation
import AppKit

/// RecordingOverlayWindow 在录音时显示一个半透明悬浮窗
/// 包含：录音时间、音量波形、状态文字
final class RecordingOverlayWindow {

    // MARK: - Properties

    private var window: NSWindow?
    private var timerLabel: NSTextField?
    private var statusLabel: NSTextField?
    private var levelIndicator: NSLevelIndicator?
    private var waveformView: WaveformView?

    private var timer: DispatchSourceTimer?
    private var startTime: Date?

    // MARK: - Show / Hide

    /// 显示录音悬浮窗
    func show() {
        guard window == nil else { return }

        let width: CGFloat = 240
        let height: CGFloat = 80

        // 窗口位置：屏幕底部中央偏上
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - width / 2
        let y = screenFrame.minY + screenFrame.height * 0.15

        let w = NSWindow(
            contentRect: NSRect(x: x, y: y, width: width, height: height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        w.level = .floating
        w.backgroundColor = .clear
        w.isOpaque = false
        w.hasShadow = true
        w.ignoresMouseEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .stationary]

        // 容器视图（圆角半透明背景）
        let container = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        container.material = .hudWindow
        container.state = .active
        container.blendingMode = .behindWindow
        container.wantsLayer = true
        container.layer?.cornerRadius = 16
        container.layer?.masksToBounds = true

        // 🔴 录音指示器 + 状态文字
        let dotLabel = NSTextField(labelWithString: "🔴")
        dotLabel.font = .systemFont(ofSize: 14)
        dotLabel.frame = NSRect(x: 12, y: 48, width: 24, height: 20)
        container.addSubview(dotLabel)

        let status = NSTextField(labelWithString: "录音中...")
        status.font = .systemFont(ofSize: 14, weight: .medium)
        status.textColor = .labelColor
        status.frame = NSRect(x: 36, y: 48, width: 100, height: 20)
        container.addSubview(status)
        statusLabel = status

        // 计时器
        let timeLabel = NSTextField(labelWithString: "00:00")
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .regular)
        timeLabel.textColor = .secondaryLabelColor
        timeLabel.alignment = .right
        timeLabel.frame = NSRect(x: width - 70, y: 48, width: 58, height: 20)
        container.addSubview(timeLabel)
        timerLabel = timeLabel

        // 波形视图
        let waveform = WaveformView(frame: NSRect(x: 12, y: 10, width: width - 24, height: 32))
        container.addSubview(waveform)
        waveformView = waveform

        w.contentView = container
        window = w

        // 启动计时器
        startTime = Date()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: .milliseconds(100))
        t.setEventHandler { [weak self] in
            self?.updateTimer()
        }
        t.resume()
        timer = t

        // 淡入
        w.alphaValue = 0
        w.orderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            w.animator().alphaValue = 1
        }
    }

    /// 隐藏录音悬浮窗
    func hide() {
        timer?.cancel()
        timer = nil

        guard let w = window else { return }

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            w.animator().alphaValue = 0
        }) { [weak self] in
            w.orderOut(nil)
            self?.window = nil
            self?.waveformView = nil
            self?.timerLabel = nil
            self?.statusLabel = nil
        }
    }

    /// 更新音频电平（0.0~1.0）
    func updateLevel(_ level: Float) {
        DispatchQueue.main.async { [weak self] in
            self?.waveformView?.addLevel(level)
        }
    }

    /// 更新状态文字（如："识别中..."）
    func setStatus(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            self?.statusLabel?.stringValue = text
        }
    }

    // MARK: - Private

    private func updateTimer() {
        guard let start = startTime else { return }
        let elapsed = Date().timeIntervalSince(start)
        let minutes = Int(elapsed) / 60
        let seconds = Int(elapsed) % 60
        timerLabel?.stringValue = String(format: "%02d:%02d", minutes, seconds)
    }
}

// MARK: - WaveformView

/// 简易波形绘制视图
final class WaveformView: NSView {

    private var levels: [Float] = []
    private let maxBars = 40

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    func addLevel(_ level: Float) {
        levels.append(min(max(level, 0.02), 1.0))
        if levels.count > maxBars {
            levels.removeFirst(levels.count - maxBars)
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !levels.isEmpty else { return }

        let barWidth: CGFloat = bounds.width / CGFloat(maxBars)
        let gap: CGFloat = 1
        let maxHeight = bounds.height

        NSColor.systemRed.withAlphaComponent(0.7).setFill()

        for (i, level) in levels.enumerated() {
            let h = max(CGFloat(level) * maxHeight, 2)
            let x = CGFloat(i) * barWidth
            let y = (maxHeight - h) / 2
            let bar = NSRect(x: x + gap / 2, y: y, width: barWidth - gap, height: h)
            let path = NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5)
            path.fill()
        }
    }
}

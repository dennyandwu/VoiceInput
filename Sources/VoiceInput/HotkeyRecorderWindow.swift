// Sources/VoiceInput/HotkeyRecorderWindow.swift
// 快捷键录制窗口 — 用户按下任意键即录制为新热键
// Phase 6: 自定义快捷键
// Copyright (c) 2026 urDAO Investment

import Foundation
import AppKit
import CoreGraphics
import os

/// HotkeyRecorderWindow 弹出一个小窗口提示用户按键
/// 录制到按键后通过 onKeyRecorded 回调返回 keyCode
final class HotkeyRecorderWindow: NSObject {

    private static let logger = Logger(subsystem: "com.urdao.voiceinput", category: "HotkeyRecorderWindow")

    var onKeyRecorded: ((UInt16, String) -> Void)?

    private var window: NSWindow?
    private var monitor: Any?

    /// 显示快捷键录制窗口
    func show() {
        // 创建窗口
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 160),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = "设置热键"
        w.level = .floating
        w.center()
        w.isReleasedWhenClosed = false

        // 内容视图
        let contentView = NSView(frame: w.contentView!.bounds)
        contentView.wantsLayer = true

        // 图标
        let iconLabel = NSTextField(labelWithString: "⌨️")
        iconLabel.font = .systemFont(ofSize: 40)
        iconLabel.frame = NSRect(x: 155, y: 100, width: 50, height: 50)
        contentView.addSubview(iconLabel)

        // 提示文字
        let label = NSTextField(labelWithString: "请按下想要设置的快捷键...")
        label.font = .systemFont(ofSize: 16, weight: .medium)
        label.alignment = .center
        label.frame = NSRect(x: 20, y: 60, width: 320, height: 30)
        contentView.addSubview(label)

        // 提示文字2
        let hint = NSTextField(labelWithString: "支持: Option / Shift / Control / Command / F1-F12 / 其他按键")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.alignment = .center
        hint.frame = NSRect(x: 20, y: 35, width: 320, height: 20)
        contentView.addSubview(hint)

        // 取消按钮
        let cancelBtn = NSButton(title: "取消", target: self, action: #selector(cancel))
        cancelBtn.frame = NSRect(x: 140, y: 8, width: 80, height: 24)
        cancelBtn.bezelStyle = .rounded
        contentView.addSubview(cancelBtn)

        w.contentView = contentView

        // 安装全局事件监控
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            self?.handleKeyEvent(event)
            return nil  // 消费事件
        }

        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func handleKeyEvent(_ event: NSEvent) {
        let keyCode = event.keyCode

        if event.type == .flagsChanged {
            // 修饰键：只在按下时触发（不是松开）
            let flags = event.modifierFlags
            let isModifierPress: Bool
            switch keyCode {
            case 0x3D, 0x3A:  // Option
                isModifierPress = flags.contains(.option)
            case 0x38, 0x3C:  // Shift
                isModifierPress = flags.contains(.shift)
            case 0x3B, 0x3E:  // Control
                isModifierPress = flags.contains(.control)
            case 0x37, 0x36:  // Command
                isModifierPress = flags.contains(.command)
            default:
                return
            }
            guard isModifierPress else { return }
        }

        // Escape 取消
        if keyCode == 0x35 && event.type == .keyDown {
            cancel()
            return
        }

        let name = keyCodeName(keyCode)
        Self.logger.info("录制到按键: keyCode=0x\(String(keyCode, radix: 16)) (\(name))")

        dismiss()
        onKeyRecorded?(keyCode, name)
    }

    @objc private func cancel() {
        dismiss()
    }

    private func dismiss() {
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
        window?.close()
        window = nil
    }

    /// keyCode 转友好名称
    private func keyCodeName(_ code: UInt16) -> String {
        switch code {
        case 0x3D: return "右Option"
        case 0x3A: return "左Option"
        case 0x38: return "左Shift"
        case 0x3C: return "右Shift"
        case 0x3B: return "左Control"
        case 0x3E: return "右Control"
        case 0x37: return "左Command"
        case 0x36: return "右Command"
        case 0x31: return "Space"
        case 0x35: return "Escape"
        case 0x24: return "Return"
        case 0x30: return "Tab"
        case 0x33: return "Delete"
        case 0x7A: return "F1"
        case 0x78: return "F2"
        case 0x63: return "F3"
        case 0x76: return "F4"
        case 0x60: return "F5"
        case 0x61: return "F6"
        case 0x62: return "F7"
        case 0x64: return "F8"
        case 0x65: return "F9"
        case 0x6D: return "F10"
        case 0x67: return "F11"
        case 0x6F: return "F12"
        // 字母键
        case 0x00: return "A"
        case 0x0B: return "B"
        case 0x08: return "C"
        case 0x02: return "D"
        case 0x0E: return "E"
        case 0x03: return "F"
        case 0x05: return "G"
        case 0x04: return "H"
        case 0x22: return "I"
        case 0x26: return "J"
        case 0x28: return "K"
        case 0x25: return "L"
        case 0x2E: return "M"
        case 0x2D: return "N"
        case 0x1F: return "O"
        case 0x23: return "P"
        case 0x0C: return "Q"
        case 0x0F: return "R"
        case 0x01: return "S"
        case 0x11: return "T"
        case 0x20: return "U"
        case 0x09: return "V"
        case 0x0D: return "W"
        case 0x07: return "X"
        case 0x10: return "Y"
        case 0x06: return "Z"
        default:   return "Key(0x\(String(code, radix: 16)))"
        }
    }
}

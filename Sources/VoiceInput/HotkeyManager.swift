// Sources/VoiceInput/HotkeyManager.swift
// 全局热键管理 - 使用 CGEvent tap 监听全局键盘事件
// Phase 3 实现
// Copyright (c) 2026 urDAO Investment

import Foundation
import CoreGraphics
import AppKit

/// HotkeyManager 管理全局热键（无需应用获取焦点）
/// 使用 CGEvent tap 监听全局键盘事件（需辅助功能权限）
///
/// 支持两种模式：
/// - pushToTalk: 按住触发录音，松开停止
/// - toggle: 按一次开始录音，再按一次停止
class HotkeyManager {

    // MARK: - Types

    enum Mode {
        case pushToTalk  // 按住说话
        case toggle      // 切换模式
    }

    // MARK: - Properties

    var mode: Mode = .pushToTalk

    /// 触发热键的 keyCode，默认右 Option 键 (0x3D = 61)
    var triggerKeyCode: UInt16 = 0x3D

    /// 开始录音回调
    var onRecordStart: (() -> Void)?

    /// 停止录音回调
    var onRecordStop: (() -> Void)?

    // MARK: - Private State

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isListening = false

    /// toggle 模式下的当前录音状态
    private var isRecording = false

    /// PTT 模式下防止 keyDown 重复触发（长按会持续发 keyDown）
    private var pttActive = false

    // MARK: - Lifecycle

    deinit {
        stop()
    }

    // MARK: - Public API

    /// 开始监听全局热键
    /// - Returns: true 表示成功启动，false 表示权限不足或已在运行
    @discardableResult
    func start() -> Bool {
        guard !isListening else {
            fputs("[HotkeyManager] 已在监听中\n", stderr)
            return true
        }

        guard HotkeyManager.checkAccessibility() else {
            fputs("[HotkeyManager] ❌ 辅助功能权限未授予\n", stderr)
            HotkeyManager.requestAccessibility()
            return false
        }

        // 使用 Unmanaged 传递 self 给 C 回调
        let selfPtr = Unmanaged.passRetained(self).toOpaque()

        let eventMask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: hotkeyEventCallback,
            userInfo: selfPtr
        ) else {
            fputs("[HotkeyManager] ❌ 无法创建事件 tap（权限可能未生效，需重启应用）\n", stderr)
            Unmanaged<HotkeyManager>.fromOpaque(selfPtr).release()
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.eventTap = tap
        self.runLoopSource = source
        self.isListening = true

        fputs("[HotkeyManager] ✅ 开始监听，模式=\(mode == .pushToTalk ? "PTT" : "Toggle")，keyCode=0x\(String(triggerKeyCode, radix: 16))\n", stderr)
        return true
    }

    /// 停止监听全局热键
    func stop() {
        guard isListening else { return }

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }

        // 若录音中则触发停止
        if isRecording || pttActive {
            isRecording = false
            pttActive = false
            onRecordStop?()
        }

        eventTap = nil
        runLoopSource = nil
        isListening = false

        fputs("[HotkeyManager] 已停止监听\n", stderr)
    }

    // MARK: - Event Handling (called from C callback)

    /// 处理键盘事件，由 C 回调转发
    fileprivate func handleEvent(type: CGEventType, event: CGEvent) -> Bool {
        if type == .flagsChanged {
            return handleFlagsChanged(event: event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard keyCode == triggerKeyCode else { return false }

        switch mode {
        case .pushToTalk:
            handlePTT(type: type)
        case .toggle:
            handleToggle(type: type)
        }
        return true
    }

    /// 处理修饰键（Option/Shift/Command/Control）的按下/松开
    private func handleFlagsChanged(event: CGEvent) -> Bool {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard keyCode == triggerKeyCode else { return false }

        // 判断是按下还是松开：检查对应的 modifier flag
        let flags = event.flags
        let isPressed: Bool
        switch triggerKeyCode {
        case 0x3D, 0x3A:  // 右Option, 左Option
            isPressed = flags.contains(.maskAlternate)
        case 0x38, 0x3C:  // 左Shift, 右Shift
            isPressed = flags.contains(.maskShift)
        case 0x3B, 0x3E:  // 左Control, 右Control
            isPressed = flags.contains(.maskControl)
        case 0x37, 0x36:  // 左Command, 右Command
            isPressed = flags.contains(.maskCommand)
        default:
            return false
        }

        switch mode {
        case .pushToTalk:
            if isPressed {
                guard !pttActive else { return true }
                pttActive = true
                fputs("[HotkeyManager] PTT flagsChanged → 开始录音\n", stderr)
                onRecordStart?()
            } else {
                guard pttActive else { return true }
                pttActive = false
                fputs("[HotkeyManager] PTT flagsChanged → 停止录音\n", stderr)
                onRecordStop?()
            }
        case .toggle:
            if isPressed {
                if isRecording {
                    isRecording = false
                    fputs("[HotkeyManager] Toggle flagsChanged → 停止录音\n", stderr)
                    onRecordStop?()
                } else {
                    isRecording = true
                    fputs("[HotkeyManager] Toggle flagsChanged → 开始录音\n", stderr)
                    onRecordStart?()
                }
            }
        }
        return true
    }

    private func handlePTT(type: CGEventType) {
        switch type {
        case .keyDown:
            guard !pttActive else { return }  // 忽略长按重复
            pttActive = true
            fputs("[HotkeyManager] PTT keyDown → 开始录音\n", stderr)
            onRecordStart?()

        case .keyUp:
            guard pttActive else { return }
            pttActive = false
            fputs("[HotkeyManager] PTT keyUp → 停止录音\n", stderr)
            onRecordStop?()

        default:
            break
        }
    }

    private func handleToggle(type: CGEventType) {
        guard type == .keyDown else { return }

        if isRecording {
            isRecording = false
            fputs("[HotkeyManager] Toggle → 停止录音\n", stderr)
            onRecordStop?()
        } else {
            isRecording = true
            fputs("[HotkeyManager] Toggle → 开始录音\n", stderr)
            onRecordStart?()
        }
    }

    // MARK: - Accessibility

    /// 检查辅助功能权限
    static func checkAccessibility() -> Bool {
        return AXIsProcessTrusted()
    }

    /// 引导用户开启辅助功能权限
    static func requestAccessibility() {
        fputs("""
        [HotkeyManager] 需要辅助功能权限才能监听全局热键。
        请前往：系统设置 → 隐私与安全性 → 辅助功能
        将运行本程序的终端（如 Terminal.app）添加到允许列表。
        修改后重启本程序。
        \n
        """, stderr)

        // 触发系统权限请求对话框
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true]
        AXIsProcessTrustedWithOptions(options)
    }
}

// MARK: - CGEvent Tap C Callback

/// CGEvent tap 全局 C 回调
/// 注意：此函数在事件 tap 的线程上调用（通常是主线程）
private func hotkeyEventCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon = refcon else {
        return Unmanaged.passUnretained(event)
    }

    let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()

    // 处理 keyDown / keyUp / flagsChanged
    guard type == .keyDown || type == .keyUp || type == .flagsChanged else {
        return Unmanaged.passUnretained(event)
    }

    let handled = manager.handleEvent(type: type, event: event)

    // PTT 模式下吞掉热键事件，避免触发其他应用
    if handled && manager.mode == .pushToTalk {
        return nil
    }

    return Unmanaged.passUnretained(event)
}

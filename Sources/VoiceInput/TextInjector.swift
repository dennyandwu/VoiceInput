// Sources/VoiceInput/TextInjector.swift
// 文本注入 - 将识别结果注入当前聚焦应用
// Phase 3 实现
// Copyright (c) 2026 urDAO Investment

import Foundation
import AppKit
import CoreGraphics
import ApplicationServices
import os

/// TextInjector 将识别文本注入当前活跃窗口
///
/// 支持两种方案：
/// - clipboard（主方案）：保存剪贴板 → 写入识别文本 → 模拟 Cmd+V → 恢复剪贴板
/// - accessibility（备选）：通过 AXUIElement 直接写入焦点元素
class TextInjector {

    private static let logger = Logger(subsystem: "com.urdao.voiceinput", category: "TextInjector")

    // MARK: - Types

    enum Method {
        case keyboard      // CGEventKeyboardSetUnicodeString（推荐，不污染剪贴板）
        case clipboard     // Pasteboard + Cmd+V（兼容性好）
        case accessibility // AXUIElement（部分 app 可用）
    }

    // MARK: - Properties

    var method: Method = .keyboard

    /// Cmd+V 发送后等待应用处理的延迟（ms）
    var pasteDelayMs: Int = 100

    /// 恢复剪贴板前的延迟（ms），需比 pasteDelay 长
    var restoreDelayMs: Int = 150

    // MARK: - Public API

    /// 将文本注入当前焦点窗口
    /// - Parameter text: 要注入的文本
    /// - Returns: true 表示注入成功（或已发出注入指令）
    @discardableResult
    func inject(text: String) -> Bool {
        guard !text.isEmpty else { return true }

        switch method {
        case .keyboard:
            let success = injectViaKeyboardSimulation(text: text)
            if !success {
                Self.logger.warning("Keyboard 注入失败，降级到 clipboard")
                return injectViaClipboard(text: text)
            }
            return true
        case .clipboard:
            return injectViaClipboard(text: text)
        case .accessibility:
            let success = injectViaAccessibility(text: text)
            if !success {
                Self.logger.warning("Accessibility 注入失败，降级到 clipboard")
                return injectViaClipboard(text: text)
            }
            return true
        }
    }

    /// 检查所需权限
    func checkPermission() -> Bool {
        return AXIsProcessTrusted()
    }

    // MARK: - Clipboard 方案

    private func injectViaClipboard(text: String) -> Bool {
        let pasteboard = NSPasteboard.general

        // 1. 保存当前剪贴板所有内容
        let savedItems = saveClipboard(pasteboard: pasteboard)
        Self.logger.info("剪贴板已保存（\(savedItems.count) 项）")

        // 2. 清空剪贴板，写入识别文本
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        Self.logger.info("写入识别文本到剪贴板")

        // 3. 短暂等待确保剪贴板就绪
        Thread.sleep(forTimeInterval: 0.05)

        // 4. 模拟 Cmd+V
        let didPost = postCmdV()
        if !didPost {
            Self.logger.warning("⚠️ Cmd+V 发送失败")
        } else {
            Self.logger.info("✅ Cmd+V 已发送")
        }

        // 5. 延迟恢复剪贴板（给目标应用时间处理粘贴）
        let restoreMs = restoreDelayMs
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(restoreMs)) { [weak self] in
            self?.restoreClipboard(pasteboard: pasteboard, items: savedItems)
            Self.logger.info("剪贴板已恢复")
        }

        return didPost
    }

    // MARK: - CGEvent Unicode 方案（推荐，不污染剪贴板）

    /// 通过 CGEventKeyboardSetUnicodeString 直接模拟键入
    /// 参考 open-typeless 的实现，每次最多 20 个 Unicode 字符
    private func injectViaKeyboardSimulation(text: String) -> Bool {
        // H10: 焦点检查 — 确认有前台应用
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            Self.logger.warning("⚠️ 无前台应用，跳过注入")
            return false
        }
        Self.logger.info("使用 CGEvent Unicode 注入 → \(frontApp.localizedName ?? "unknown")")

        let utf16 = Array(text.utf16)
        let chunkSize = 20  // CGEvent 限制每次最多 ~20 个 UTF-16 code unit

        for start in stride(from: 0, to: utf16.count, by: chunkSize) {
            let end = min(start + chunkSize, utf16.count)
            let chunk = Array(utf16[start..<end])

            guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
                Self.logger.error("❌ CGEvent 创建失败")
                return false
            }

            var chars = chunk
            keyDown.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
            keyUp.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)

            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)

            // 短暂间隔避免事件丢失
            Thread.sleep(forTimeInterval: 0.01)
        }

        Self.logger.info("✅ Unicode 注入完成 (\(utf16.count) chars)")
        return true
    }

    // MARK: - Clipboard Save / Restore

    /// 保存剪贴板内容（支持所有类型：文本、图片、文件等）
    private func saveClipboard(pasteboard: NSPasteboard) -> [SavedPasteboardItem] {
        guard let items = pasteboard.pasteboardItems else { return [] }

        return items.compactMap { item -> SavedPasteboardItem? in
            var typeDataMap: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    typeDataMap[type] = data
                }
            }
            return typeDataMap.isEmpty ? nil : SavedPasteboardItem(typeDataMap: typeDataMap)
        }
    }

    /// 恢复剪贴板内容
    private func restoreClipboard(pasteboard: NSPasteboard, items: [SavedPasteboardItem]) {
        pasteboard.clearContents()

        if items.isEmpty {
            // 原来剪贴板是空的，清空即可
            return
        }

        let newItems = items.map { saved -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in saved.typeDataMap {
                item.setData(data, forType: type)
            }
            return item
        }

        pasteboard.writeObjects(newItems)
    }

    // MARK: - CGEvent Simulate Cmd+V

    /// 模拟 Cmd+V 按键
    /// keyCode 0x09 = 'v' on US keyboard
    private func postCmdV() -> Bool {
        let vKeyCode: CGKeyCode = 0x09

        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: true),
              let keyUp   = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: false)
        else {
            Self.logger.error("CGEvent 创建失败")
            return false
        }

        keyDown.flags = .maskCommand
        keyUp.flags   = .maskCommand

        keyDown.post(tap: .cghidEventTap)

        // 短暂等待确保 keyDown 先被处理
        Thread.sleep(forTimeInterval: Double(pasteDelayMs) / 1000.0)

        keyUp.post(tap: .cghidEventTap)

        return true
    }

    // MARK: - Accessibility 方案

    /// 通过 AXUIElement 直接向焦点元素写入文本
    private func injectViaAccessibility(text: String) -> Bool {
        guard AXIsProcessTrusted() else {
            Self.logger.warning("辅助功能权限未授予")
            return false
        }

        let systemWide = AXUIElementCreateSystemWide()

        // 获取当前焦点 UI 元素
        var focusedElement: AnyObject?
        let result = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )

        guard result == .success, let element = focusedElement else {
            Self.logger.warning("无法获取焦点元素：\(result.rawValue)")
            return false
        }

        let axElement = element as! AXUIElement  // swiftlint:disable:this force_cast

        // 尝试设置 value 属性
        let setValue = AXUIElementSetAttributeValue(
            axElement,
            kAXValueAttribute as CFString,
            text as CFTypeRef
        )

        if setValue == .success {
            Self.logger.info("✅ Accessibility 注入成功")
            return true
        }

        // 若不支持直接设置值，尝试插入文本（部分 app 支持）
        let insertResult = AXUIElementSetAttributeValue(
            axElement,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )

        if insertResult == .success {
            Self.logger.info("✅ Accessibility 插入文本成功")
            return true
        }

        Self.logger.warning("Accessibility 注入失败：value=\(setValue.rawValue), selectedText=\(insertResult.rawValue)")
        return false
    }
}

// MARK: - Helper Types

/// 保存的剪贴板条目（含所有数据类型）
private struct SavedPasteboardItem {
    let typeDataMap: [NSPasteboard.PasteboardType: Data]
}

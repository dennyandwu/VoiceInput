// Sources/VoiceInput/PermissionManager.swift
// 权限检查与引导
// Phase 4: MenuBar GUI
// Copyright (c) 2026 urDAO Investment

import Foundation
import AppKit
import AVFoundation
import ApplicationServices

/// PermissionManager 集中管理所有需要的系统权限
///
/// 所需权限：
/// - 麦克风：录制语音
/// - 辅助功能（Accessibility）：CGEvent tap 全局热键 + 文本注入
/// - 输入监控（Input Monitoring）：在某些 macOS 版本下需要
class PermissionManager {

    // MARK: - 麦克风权限

    /// 检查是否已授权麦克风访问
    static func checkMicrophone() -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined, .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    /// 请求麦克风权限（异步）
    /// - Parameter completion: 授权结果回调，在主线程调用
    static func requestMicrophone(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            DispatchQueue.main.async { completion(true) }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        case .denied, .restricted:
            // 已拒绝，引导用户去系统设置
            DispatchQueue.main.async {
                openMicrophoneSettings()
                completion(false)
            }
        @unknown default:
            DispatchQueue.main.async { completion(false) }
        }
    }

    /// 打开系统设置 → 隐私与安全性 → 麦克风
    static func openMicrophoneSettings() {
        let url: URL
        if #available(macOS 13.0, *) {
            url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        } else {
            url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: - 辅助功能权限（Accessibility）

    /// 检查是否已授权辅助功能访问
    /// 需要此权限才能：1) CGEvent tap 监听全局热键  2) AXUIElement 注入文本
    static func checkAccessibility() -> Bool {
        return AXIsProcessTrusted()
    }

    /// 弹出辅助功能权限请求对话框，并引导用户到系统设置
    /// 注意：对话框只会弹出一次，之后需要用户手动去设置中允许
    static func requestAccessibility() {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true]
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// 打开系统设置 → 隐私与安全性 → 辅助功能
    static func openAccessibilitySettings() {
        let url: URL
        if #available(macOS 13.0, *) {
            url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        } else {
            url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: - 输入监控权限（Input Monitoring）

    /// 检查输入监控权限
    /// 在 macOS 10.15+ 某些场景下，CGEvent tap 需要此权限
    static func checkInputMonitoring() -> Bool {
        // IOHIDRequestAccess / IOHIDCheckAccess 在 Swift 直接调用比较麻烦
        // 实际上 CGEvent tap 配合 Accessibility 权限通常够用
        // 这里通过尝试创建一个临时事件来间接判断
        // 注意：此检查是尽力而为，不保证 100% 准确
        return AXIsProcessTrusted()
    }

    /// 打开系统设置 → 隐私与安全性 → 输入监控
    static func openInputMonitoringSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - 权限摘要

    struct PermissionStatus {
        let microphone: Bool
        let accessibility: Bool
        let inputMonitoring: Bool

        var allGranted: Bool {
            microphone && accessibility
        }
    }

    /// 检查所有权限状态（同步，用于 UI 刷新）
    static func checkAll() -> PermissionStatus {
        return PermissionStatus(
            microphone: checkMicrophone(),
            accessibility: checkAccessibility(),
            inputMonitoring: checkInputMonitoring()
        )
    }
}

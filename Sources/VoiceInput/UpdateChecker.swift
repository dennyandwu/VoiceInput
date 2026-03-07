// Sources/VoiceInput/UpdateChecker.swift
// GitHub Releases 自动更新检查 + 一键自动替换
// Copyright (c) 2026 urDAO Investment

import Foundation
import AppKit

/// UpdateChecker 检查 GitHub Releases 获取最新版本
/// 支持自动下载 DMG → 挂载 → 替换 app → 重启
final class UpdateChecker {

    // MARK: - Config

    /// GitHub 仓库（owner/repo）
    static let repo = "dennyandwu/VoiceInput"
    static let releasesAPI = "https://api.github.com/repos/\(repo)/releases/latest"
    static let releasesURL = "https://github.com/\(repo)/releases"

    /// DMG 最小合法大小（字节），低于此值视为下载损坏
    static let minDMGSize: Int64 = 50_000_000  // 50MB

    // MARK: - Types

    struct ReleaseInfo {
        let version: String    // e.g. "1.0.5-beta"
        let tagName: String    // e.g. "v1.0.5-beta"
        let body: String       // release notes
        let dmgURL: String?    // DMG download URL
        let dmgSize: Int64     // DMG expected size (bytes)
        let publishedAt: String
    }

    // MARK: - Public API

    /// 当前 app 版本
    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// 当前 app 路径
    static var currentAppPath: String {
        Bundle.main.bundlePath
    }

    /// 检查更新（异步）
    static func checkForUpdate(completion: @escaping (ReleaseInfo?, Error?) -> Void) {
        guard let url = URL(string: releasesAPI) else {
            completion(nil, makeError("无效的 API URL"))
            return
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.setValue("VoiceInput/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                fputs("[UpdateChecker] API 请求失败: \(error.localizedDescription)\n", stderr)
                completion(nil, error)
                return
            }

            // 检查 HTTP 状态码
            if let httpResponse = response as? HTTPURLResponse {
                fputs("[UpdateChecker] API 状态码: \(httpResponse.statusCode)\n", stderr)
                if httpResponse.statusCode != 200 {
                    completion(nil, makeError("GitHub API 返回 \(httpResponse.statusCode)（仓库可能是私有的或不存在）"))
                    return
                }
            }

            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(nil, makeError("无法解析 GitHub API 响应"))
                return
            }

            let tagName = json["tag_name"] as? String ?? ""
            let body = json["body"] as? String ?? ""
            let publishedAt = json["published_at"] as? String ?? ""

            // 从 tag_name 提取版本号（去掉 v 前缀）
            let version = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName

            // 查找 DMG asset
            var dmgURL: String?
            var dmgSize: Int64 = 0
            if let assets = json["assets"] as? [[String: Any]] {
                for asset in assets {
                    if let name = asset["name"] as? String,
                       name.hasSuffix(".dmg"),
                       let downloadURL = asset["browser_download_url"] as? String {
                        dmgURL = downloadURL
                        dmgSize = (asset["size"] as? Int64) ?? (asset["size"] as? Int).map { Int64($0) } ?? 0
                        fputs("[UpdateChecker] DMG: \(name), 大小: \(dmgSize) bytes, URL: \(downloadURL)\n", stderr)
                        break
                    }
                }
            }

            let info = ReleaseInfo(
                version: version,
                tagName: tagName,
                body: body,
                dmgURL: dmgURL,
                dmgSize: dmgSize,
                publishedAt: publishedAt
            )

            completion(info, nil)
        }.resume()
    }

    /// 比较版本号：是否有新版本
    static func isNewerVersion(_ remote: String, than local: String) -> Bool {
        func numericParts(_ v: String) -> [Int] {
            let base = v.split(separator: "-").first ?? Substring(v)
            return base.split(separator: ".").compactMap { Int($0) }
        }

        let r = numericParts(remote)
        let l = numericParts(local)

        for i in 0..<max(r.count, l.count) {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv > lv { return true }
            if rv < lv { return false }
        }
        return false
    }

    // MARK: - 自动更新流程

    /// 下载 DMG → 挂载 → 替换 app → 重启
    /// 全自动，用户只需确认一次
    static func autoUpdate(dmgURL: String, expectedSize: Int64,
                           progress: @escaping (Double, String) -> Void,
                           completion: @escaping (Bool, Error?) -> Void) {

        fputs("[UpdateChecker] 开始自动更新: \(dmgURL)\n", stderr)
        progress(0, "下载更新中...")

        downloadDMG(url: dmgURL, expectedSize: expectedSize, progress: { pct in
            progress(pct * 0.7, "下载更新中... \(Int(pct * 100))%")
        }) { dmgPath, error in
            if let error = error {
                completion(false, error)
                return
            }

            guard let dmgPath = dmgPath else {
                completion(false, makeError("下载路径为空"))
                return
            }

            progress(0.7, "安装更新中...")

            // 挂载 → 复制 → 卸载 → 重启
            installFromDMG(dmgPath: dmgPath) { success, installError in
                // 清理下载的 DMG
                try? FileManager.default.removeItem(atPath: dmgPath)

                if success {
                    progress(1.0, "更新完成，正在重启...")
                    fputs("[UpdateChecker] ✅ 更新完成，准备重启\n", stderr)

                    // 延迟重启，让 UI 更新
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        relaunchApp()
                    }
                }

                completion(success, installError)
            }
        }
    }

    // MARK: - 下载 DMG

    private static func downloadDMG(url: String, expectedSize: Int64,
                                     progress: @escaping (Double) -> Void,
                                     completion: @escaping (String?, Error?) -> Void) {
        guard let downloadURL = URL(string: url) else {
            completion(nil, makeError("无效的下载 URL"))
            return
        }

        let tempDir = FileManager.default.temporaryDirectory
        let destPath = tempDir.appendingPathComponent("VoiceInput-update.dmg").path
        let destURL = URL(fileURLWithPath: destPath)

        // 清理旧文件
        try? FileManager.default.removeItem(at: destURL)

        let session = URLSession(configuration: .default, delegate: DownloadDelegate(
            destination: destURL,
            expectedSize: expectedSize,
            progress: { pct in
                DispatchQueue.main.async { progress(pct) }
            },
            completion: { success, error in
                if success {
                    // 验证文件大小
                    let attrs = try? FileManager.default.attributesOfItem(atPath: destPath)
                    let actualSize = (attrs?[.size] as? Int64) ?? 0
                    fputs("[UpdateChecker] DMG 下载完成: \(actualSize) bytes\n", stderr)

                    if expectedSize > 0 && actualSize < expectedSize / 2 {
                        fputs("[UpdateChecker] ⚠️ DMG 大小异常: 期望 \(expectedSize), 实际 \(actualSize)\n", stderr)
                        completion(nil, makeError("下载文件不完整（\(actualSize / 1024 / 1024)MB / \(expectedSize / 1024 / 1024)MB）"))
                        return
                    }

                    if actualSize < minDMGSize {
                        completion(nil, makeError("下载文件太小（\(actualSize / 1024 / 1024)MB），可能损坏"))
                        return
                    }

                    completion(destPath, nil)
                } else {
                    completion(nil, error ?? makeError("下载失败"))
                }
            }
        ), delegateQueue: nil)

        session.downloadTask(with: downloadURL).resume()
    }

    // MARK: - 挂载 DMG + 复制 app

    private static func installFromDMG(dmgPath: String, completion: @escaping (Bool, Error?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            // 1. 挂载 DMG
            let mountPoint = "/tmp/VoiceInput-update-mount"
            try? FileManager.default.removeItem(atPath: mountPoint)

            let mountProcess = Process()
            mountProcess.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            mountProcess.arguments = ["attach", dmgPath, "-mountpoint", mountPoint, "-noverify", "-nobrowse", "-noautoopen"]

            let mountPipe = Pipe()
            mountProcess.standardOutput = mountPipe
            mountProcess.standardError = mountPipe

            do {
                try mountProcess.run()
                mountProcess.waitUntilExit()
            } catch {
                DispatchQueue.main.async {
                    completion(false, makeError("挂载 DMG 失败: \(error.localizedDescription)"))
                }
                return
            }

            guard mountProcess.terminationStatus == 0 else {
                let output = String(data: mountPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                fputs("[UpdateChecker] hdiutil 失败: \(output)\n", stderr)
                DispatchQueue.main.async {
                    completion(false, makeError("挂载 DMG 失败（exit \(mountProcess.terminationStatus)）"))
                }
                return
            }

            fputs("[UpdateChecker] DMG 已挂载到 \(mountPoint)\n", stderr)

            // 2. 查找 .app
            let fm = FileManager.default
            guard let contents = try? fm.contentsOfDirectory(atPath: mountPoint),
                  let appName = contents.first(where: { $0.hasSuffix(".app") }) else {
                detachDMG(mountPoint: mountPoint)
                DispatchQueue.main.async {
                    completion(false, makeError("DMG 中未找到 .app"))
                }
                return
            }

            let sourceApp = "\(mountPoint)/\(appName)"
            let destApp = currentAppPath

            fputs("[UpdateChecker] 替换: \(sourceApp) → \(destApp)\n", stderr)

            // 3. 验证新 app 的 tokens.txt 完整性
            let tokensPath = "\(sourceApp)/Contents/Resources/models/sense-voice/tokens.txt"
            if let attrs = try? fm.attributesOfItem(atPath: tokensPath),
               let size = attrs[.size] as? Int64, size < 1000 {
                detachDMG(mountPoint: mountPoint)
                DispatchQueue.main.async {
                    completion(false, makeError("新版本 tokens.txt 损坏（\(size) bytes），更新取消"))
                }
                return
            }

            // 4. 备份当前 app
            let backupPath = destApp + ".backup"
            try? fm.removeItem(atPath: backupPath)

            do {
                try fm.moveItem(atPath: destApp, toPath: backupPath)
            } catch {
                detachDMG(mountPoint: mountPoint)
                DispatchQueue.main.async {
                    completion(false, makeError("备份当前版本失败: \(error.localizedDescription)"))
                }
                return
            }

            // 5. 复制新 app
            do {
                try fm.copyItem(atPath: sourceApp, toPath: destApp)
                fputs("[UpdateChecker] ✅ 新版本已复制到 \(destApp)\n", stderr)

                // 移除隔离属性
                let xattr = Process()
                xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
                xattr.arguments = ["-r", "-d", "com.apple.quarantine", destApp]
                try? xattr.run()
                xattr.waitUntilExit()

                // 删除备份
                try? fm.removeItem(atPath: backupPath)
            } catch {
                // 恢复备份
                fputs("[UpdateChecker] ❌ 复制失败，恢复备份: \(error.localizedDescription)\n", stderr)
                try? fm.removeItem(atPath: destApp)
                try? fm.moveItem(atPath: backupPath, toPath: destApp)

                detachDMG(mountPoint: mountPoint)
                DispatchQueue.main.async {
                    completion(false, makeError("安装新版本失败: \(error.localizedDescription)"))
                }
                return
            }

            // 6. 卸载 DMG
            detachDMG(mountPoint: mountPoint)

            DispatchQueue.main.async {
                completion(true, nil)
            }
        }
    }

    // MARK: - 卸载 DMG

    private static func detachDMG(mountPoint: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["detach", mountPoint, "-force"]
        try? process.run()
        process.waitUntilExit()
    }

    // MARK: - 重启 app

    private static func relaunchApp() {
        let appPath = currentAppPath
        fputs("[UpdateChecker] 重启: \(appPath)\n", stderr)

        // 用 open 命令启动新版本
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", appPath]
        try? process.run()

        // 退出当前进程
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.terminate(nil)
        }
    }

    /// 打开 GitHub Releases 页面
    static func openReleasesPage() {
        if let url = URL(string: releasesURL) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Helpers

    private static func makeError(_ message: String) -> NSError {
        NSError(domain: "UpdateChecker", code: -1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}

// MARK: - Download Delegate

private class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let destination: URL
    let expectedSize: Int64
    let progressHandler: (Double) -> Void
    let completionHandler: (Bool, Error?) -> Void

    init(destination: URL, expectedSize: Int64, progress: @escaping (Double) -> Void, completion: @escaping (Bool, Error?) -> Void) {
        self.destination = destination
        self.expectedSize = expectedSize
        self.progressHandler = progress
        self.completionHandler = completion
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            DispatchQueue.main.async { [self] in
                completionHandler(true, nil)
            }
        } catch {
            DispatchQueue.main.async { [self] in
                completionHandler(false, error)
            }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expectedSize
        if total > 0 {
            let progress = Double(totalBytesWritten) / Double(total)
            DispatchQueue.main.async { [self] in
                progressHandler(min(progress, 1.0))
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            DispatchQueue.main.async { [self] in
                completionHandler(false, error)
            }
        }
    }
}

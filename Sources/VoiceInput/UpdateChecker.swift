// Sources/VoiceInput/UpdateChecker.swift
// GitHub Releases 自动更新检查
// Phase 6: 自动更新
// Copyright (c) 2026 urDAO Investment

import Foundation
import AppKit

/// UpdateChecker 检查 GitHub Releases 获取最新版本
/// 支持一键下载更新
final class UpdateChecker {

    // MARK: - Config

    /// GitHub 仓库（owner/repo）
    static let repo = "dennyandwu/VoiceInput"
    static let releasesAPI = "https://api.github.com/repos/\(repo)/releases/latest"
    static let releasesURL = "https://github.com/\(repo)/releases"

    // MARK: - Types

    struct ReleaseInfo {
        let version: String    // e.g. "v0.3.0"
        let tagName: String
        let body: String       // release notes
        let dmgURL: String?    // DMG download URL
        let publishedAt: String
    }

    // MARK: - Public API

    /// 当前 app 版本
    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.2.0"
    }

    /// 检查更新（异步）
    static func checkForUpdate(completion: @escaping (ReleaseInfo?, Error?) -> Void) {
        guard let url = URL(string: releasesAPI) else {
            completion(nil, NSError(domain: "UpdateChecker", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "无效的 API URL"]))
            return
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.setValue("VoiceInput/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(nil, error)
                return
            }

            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(nil, NSError(domain: "UpdateChecker", code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "无法解析 GitHub API 响应"]))
                return
            }

            let tagName = json["tag_name"] as? String ?? ""
            let body = json["body"] as? String ?? ""
            let publishedAt = json["published_at"] as? String ?? ""

            // 从 tag_name 提取版本号（去掉 v 前缀）
            let version = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName

            // 查找 DMG asset
            var dmgURL: String?
            if let assets = json["assets"] as? [[String: Any]] {
                for asset in assets {
                    if let name = asset["name"] as? String,
                       name.hasSuffix(".dmg"),
                       let downloadURL = asset["browser_download_url"] as? String {
                        dmgURL = downloadURL
                        break
                    }
                }
            }

            let info = ReleaseInfo(
                version: version,
                tagName: tagName,
                body: body,
                dmgURL: dmgURL,
                publishedAt: publishedAt
            )

            completion(info, nil)
        }.resume()
    }

    /// 比较版本号：是否有新版本
    static func isNewerVersion(_ remote: String, than local: String) -> Bool {
        // 去掉 pre-release 后缀（-beta, -alpha, -rc.1 等）再比较数字部分
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

    /// 下载 DMG 到 ~/Downloads 并打开
    static func downloadAndInstall(dmgURL: String, progress: @escaping (Double) -> Void, completion: @escaping (Bool, Error?) -> Void) {
        guard let url = URL(string: dmgURL) else {
            completion(false, NSError(domain: "UpdateChecker", code: -3,
                userInfo: [NSLocalizedDescriptionKey: "无效的下载 URL"]))
            return
        }

        let downloadsDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        let destURL = downloadsDir.appendingPathComponent(url.lastPathComponent)

        // 如果已存在，先删除
        try? FileManager.default.removeItem(at: destURL)

        let session = URLSession(configuration: .default, delegate: DownloadDelegate(
            destination: destURL,
            progress: progress,
            completion: completion
        ), delegateQueue: nil)

        session.downloadTask(with: url).resume()
    }

    /// 打开 GitHub Releases 页面
    static func openReleasesPage() {
        if let url = URL(string: releasesURL) {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Download Delegate

private class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let destination: URL
    let progressHandler: (Double) -> Void
    let completionHandler: (Bool, Error?) -> Void

    init(destination: URL, progress: @escaping (Double) -> Void, completion: @escaping (Bool, Error?) -> Void) {
        self.destination = destination
        self.progressHandler = progress
        self.completionHandler = completion
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        do {
            try FileManager.default.moveItem(at: location, to: destination)

            DispatchQueue.main.async { [self] in
                // 打开 DMG
                NSWorkspace.shared.open(destination)
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
        if totalBytesExpectedToWrite > 0 {
            let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            DispatchQueue.main.async { [self] in
                progressHandler(progress)
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

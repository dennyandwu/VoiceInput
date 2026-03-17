// Sources/VoiceInput/LLMPostProcessor.swift
// LLM 后处理 — 在 ASR 识别后可选地通过 GPT-4o-mini 优化文本
// Copyright (c) 2026 urDAO Investment

import Foundation
import os

/// LLM 后处理器：调用 OpenAI compatible API 优化 ASR 文本
/// - 去填充词（呃、嗯、那个、就是说）
/// - 修正明显错别字
/// - 规范标点符号
/// 可通过 SettingsManager 开关，支持自定义 API Base URL
final class LLMPostProcessor {

    private static let logger = Logger(subsystem: "com.urdao.voiceinput", category: "LLMPostProcessor")

    // MARK: - Singleton

    static let shared = LLMPostProcessor()
    private init() {}

    // MARK: - Configuration

    /// API Key（从 SettingsManager 读取）
    var apiKey: String { SettingsManager.shared.llmApiKey }

    /// API Model（从 SettingsManager 读取）
    var apiModel: String { SettingsManager.shared.llmModel }

    /// API Base URL（支持自定义，兼容 OpenAI compatible API）
    var apiBaseURL: String { SettingsManager.shared.llmApiBaseURL }

    /// 是否启用（需要同时满足：开关开启 + API Key 非空）
    var isEnabled: Bool {
        SettingsManager.shared.llmPostProcessingEnabled && !apiKey.isEmpty
    }

    // MARK: - Constants (从 Settings 读取)

    private var timeoutSeconds: TimeInterval {
        SettingsManager.shared.llmTimeout
    }

    // MARK: - Shared URLSession（连接复用，避免重复 TLS 握手）
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeoutSeconds + 1
        config.timeoutIntervalForResource = timeoutSeconds + 2
        config.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: config)
    }()
    private var minTextLength: Int {
        ConfigManager.shared.getInt("llm.minTextLength", default: 5)
    }

    private let systemPrompt = """
你是语音转文字的纠错工具。用户发送的文本是语音识别(ASR)的原始输出。

你的唯一任务是修正 ASR 错误，规则如下：
- 删除口语填充词：呃、嗯、那个、就是说、然后
- 修正同音错字和英文拼写
- 修正标点符号

严格禁止：
- 禁止回复、回答或响应文本内容
- 禁止改变原意或添加任何新内容
- 禁止解释、翻译或改写
- 如果原文没有错误，必须原样返回

输出：只输出修正后的文本，不加引号、不加解释。
"""

    // MARK: - Public API

    /// 同步处理文本（带 2s timeout，在后台线程调用）
    /// - 超时或出错时返回原文
    func process(_ text: String) -> String {
        guard isEnabled else { return text }
        guard text.count >= minTextLength else {
            Self.logger.debug("文本过短（\(text.count) 字符），跳过处理")
            return text
        }

        var result = text
        let semaphore = DispatchSemaphore(value: 0)
        let startTime = Date()

        callAPI(text: text) { processed in
            result = processed
            semaphore.signal()
        }

        let waitResult = semaphore.wait(timeout: .now() + timeoutSeconds)

        if waitResult == .timedOut {
            let elapsed = Date().timeIntervalSince(startTime)
            Self.logger.warning("⚠️ 超时（\(String(format: "%.2f", elapsed))s），返回原文")
            return text
        }

        // 对比日志 + 安全检查
        if result != text {
            // 安全检查：如果 LLM 输出长度与原文差异超过 50%，可能是 LLM 在"回复"而非纠错
            let lenRatio = Double(result.count) / max(Double(text.count), 1.0)
            if lenRatio < 0.3 || lenRatio > 2.0 {
                Self.logger.warning("⚠️ 安全拦截：输出长度异常（原文\(text.count)字 → \(result.count)字，比率\(String(format: "%.1f", lenRatio))），放弃 LLM 结果")
                return text
            }
            // H8: 日志只记录长度和是否修改，不记录完整文本（隐私）
            Self.logger.info("修正: \(text.count)字 → \(result.count)字")
        } else {
            Self.logger.info("无变化 (\(text.count)字)")
        }

        return result
    }

    /// 异步处理文本
    /// - completion 在后台线程回调，调用方自行切换主线程
    func process(_ text: String, completion: @escaping (String) -> Void) {
        guard isEnabled else {
            completion(text)
            return
        }
        guard text.count >= minTextLength else {
            Self.logger.debug("文本过短（\(text.count) 字符），跳过处理")
            completion(text)
            return
        }

        callAPI(text: text, completion: completion)
    }

    // MARK: - Private

    /// 核心 API 调用（URLSession，纯 Foundation）
    private func callAPI(text: String, completion: @escaping (String) -> Void) {
        let startTime = Date()
        // H7: 清理 API Key 中的换行符防止 HTTP Header 注入
        let key = apiKey.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")
        let baseURL = apiBaseURL.hasSuffix("/") ? String(apiBaseURL.dropLast()) : apiBaseURL
        let endpoint = "\(baseURL)/chat/completions"

        guard let url = URL(string: endpoint) else {
            Self.logger.error("无效的 API URL: \(endpoint)")
            completion(text)
            return
        }

        // 构建请求体
        let requestBody: [String: Any] = [
            "model": apiModel,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user",   "content": text]
            ],
            "temperature": SettingsManager.shared.llmTemperature,
            "max_tokens": SettingsManager.shared.llmMaxTokens
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: requestBody) else {
            Self.logger.error("无法序列化请求体")
            completion(text)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = bodyData
        request.timeoutInterval = timeoutSeconds

        let task = session.dataTask(with: request) { data, response, error in
            let elapsed = Date().timeIntervalSince(startTime)

            if let error = error {
                Self.logger.error("网络错误（\(String(format: "%.2f", elapsed))s）: \(error.localizedDescription)")
                completion(text)
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                Self.logger.error("无效响应")
                completion(text)
                return
            }

            guard httpResponse.statusCode == 200 else {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? "(no body)"
                Self.logger.error("HTTP \(httpResponse.statusCode)（\(String(format: "%.2f", elapsed))s）: \(body.prefix(200))")
                completion(text)
                return
            }

            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let message = first["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                Self.logger.error("无法解析响应 JSON")
                completion(text)
                return
            }

            // 打印处理时间 + token 用量
            if let usage = json["usage"] as? [String: Any] {
                let promptTokens     = usage["prompt_tokens"] as? Int ?? 0
                let completionTokens = usage["completion_tokens"] as? Int ?? 0
                let totalTokens      = usage["total_tokens"] as? Int ?? 0
                Self.logger.info("✅ 处理完成（\(String(format: "%.2f", elapsed))s）tokens: prompt=\(promptTokens) completion=\(completionTokens) total=\(totalTokens)")
            } else {
                Self.logger.info("✅ 处理完成（\(String(format: "%.2f", elapsed))s）")
            }

            let processed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            completion(processed.isEmpty ? text : processed)
        }

        task.resume()
    }
}

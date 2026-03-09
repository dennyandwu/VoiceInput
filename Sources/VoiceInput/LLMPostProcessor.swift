// Sources/VoiceInput/LLMPostProcessor.swift
// LLM 后处理 — 在 ASR 识别后可选地通过 GPT-4o-mini 优化文本
// Copyright (c) 2026 urDAO Investment

import Foundation

/// LLM 后处理器：调用 OpenAI compatible API 优化 ASR 文本
/// - 去填充词（呃、嗯、那个、就是说）
/// - 修正明显错别字
/// - 规范标点符号
/// 可通过 SettingsManager 开关，支持自定义 API Base URL
final class LLMPostProcessor {

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

    // MARK: - Constants

    private let timeoutSeconds: TimeInterval = 2.0
    private let minTextLength = 5

    private let systemPrompt = """
你是语音识别(ASR)后处理助手。输入是 ASR 原始输出，可能包含错误。请执行：
1) 删除口语填充词（呃、嗯、那个、就是说、然后、对对对、是的是的）
2) 修正 ASR 常见错误：音近字替换、英文单词拼写错误、品牌名纠正（如 deeps/deep seek→DeepSeek, open claw→OpenClaw, chat gpt→ChatGPT）
3) 修正标点符号
4) 不改变原意，不添加内容，不翻译
只输出修正后的纯文本，不要任何解释或引号。
"""

    // MARK: - Public API

    /// 同步处理文本（带 2s timeout，在后台线程调用）
    /// - 超时或出错时返回原文
    func process(_ text: String) -> String {
        guard isEnabled else { return text }
        guard text.count >= minTextLength else {
            fputs("[LLM] 文本过短（\(text.count) 字符），跳过处理\n", stderr)
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
            fputs("[LLM] ⚠️ 超时（\(String(format: "%.2f", elapsed))s），返回原文\n", stderr)
            return text
        }

        // 对比日志
        if result != text {
            fputs("[LLM] 修正: \"\(text)\" → \"\(result)\"\n", stderr)
        } else {
            fputs("[LLM] 无变化: \"\(text)\"\n", stderr)
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
            fputs("[LLM] 文本过短（\(text.count) 字符），跳过处理\n", stderr)
            completion(text)
            return
        }

        callAPI(text: text, completion: completion)
    }

    // MARK: - Private

    /// 核心 API 调用（URLSession，纯 Foundation）
    private func callAPI(text: String, completion: @escaping (String) -> Void) {
        let startTime = Date()
        let key = apiKey
        let baseURL = apiBaseURL.hasSuffix("/") ? String(apiBaseURL.dropLast()) : apiBaseURL
        let endpoint = "\(baseURL)/chat/completions"

        guard let url = URL(string: endpoint) else {
            fputs("[LLM] ERROR: 无效的 API URL: \(endpoint)\n", stderr)
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
            "temperature": 0.1,
            "max_tokens": 500
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: requestBody) else {
            fputs("[LLM] ERROR: 无法序列化请求体\n", stderr)
            completion(text)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = bodyData
        request.timeoutInterval = timeoutSeconds

        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: request) { data, response, error in
            let elapsed = Date().timeIntervalSince(startTime)

            if let error = error {
                fputs("[LLM] ERROR: 网络错误（\(String(format: "%.2f", elapsed))s）: \(error.localizedDescription)\n", stderr)
                completion(text)
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                fputs("[LLM] ERROR: 无效响应\n", stderr)
                completion(text)
                return
            }

            guard httpResponse.statusCode == 200 else {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? "(no body)"
                fputs("[LLM] ERROR: HTTP \(httpResponse.statusCode)（\(String(format: "%.2f", elapsed))s）: \(body.prefix(200))\n", stderr)
                completion(text)
                return
            }

            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let message = first["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                fputs("[LLM] ERROR: 无法解析响应 JSON\n", stderr)
                completion(text)
                return
            }

            // 打印处理时间 + token 用量
            if let usage = json["usage"] as? [String: Any] {
                let promptTokens     = usage["prompt_tokens"] as? Int ?? 0
                let completionTokens = usage["completion_tokens"] as? Int ?? 0
                let totalTokens      = usage["total_tokens"] as? Int ?? 0
                fputs("[LLM] ✅ 处理完成（\(String(format: "%.2f", elapsed))s）tokens: prompt=\(promptTokens) completion=\(completionTokens) total=\(totalTokens)\n", stderr)
            } else {
                fputs("[LLM] ✅ 处理完成（\(String(format: "%.2f", elapsed))s）\n", stderr)
            }

            let processed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            completion(processed.isEmpty ? text : processed)
        }

        task.resume()
    }
}

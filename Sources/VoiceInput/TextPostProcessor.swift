// Sources/VoiceInput/TextPostProcessor.swift
// 识别结果后处理 — 清理、规范化、过滤
// Phase 6: Beta 优化
// Copyright (c) 2026 urDAO Investment

import Foundation

/// TextPostProcessor 对 ASR 原始输出进行清理和规范化
struct TextPostProcessor {

    /// 清理识别结果文本
    /// - Parameter raw: ASR 原始输出
    /// - Returns: 清理后的文本（可能为空，表示应丢弃）
    static func clean(_ raw: String) -> String {
        var text = raw

        // 1. 去除首尾空白
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // 2. 去除 SenseVoice 的特殊 token（如 <|zh|>, <|en|>, <|NEUTRAL|> 等）
        let tokenPattern = #"<\|[^|]+\|>"#
        text = text.replacingOccurrences(of: tokenPattern, with: "", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // 3. 过滤纯标点 / 无意义输出
        let meaningless = Set([".", "。", ",", "，", "!", "！", "?", "？", "...", "…",
                               "嗯", "呃", "啊", "哦", "嗯嗯", "呃呃", "啊啊"])
        if meaningless.contains(text) {
            return ""
        }

        // 4. 过滤过短文本（单个字符且非中文/日文/韩文）
        if text.count == 1 {
            let scalar = text.unicodeScalars.first!
            // CJK 统一表意文字范围
            let isCJK = (0x4E00...0x9FFF).contains(scalar.value) ||
                        (0x3400...0x4DBF).contains(scalar.value) ||
                        (0x3040...0x30FF).contains(scalar.value) || // 日文
                        (0xAC00...0xD7AF).contains(scalar.value)   // 韩文
            if !isCJK { return "" }
        }

        // 5. 中文文本：确保句末有标点
        if !text.isEmpty {
            let lastChar = text.last!
            let hasPunctuation = "。！？…，；：、」）】》".contains(lastChar) ||
                                ".!?,;:)]\">".contains(lastChar)
            // 不强制加标点，保持自然
            _ = hasPunctuation
        }

        // 6. 英文文本：首字母大写
        if !text.isEmpty && text.first!.isASCII && text.first!.isLowercase {
            text = text.prefix(1).uppercased() + text.dropFirst()
        }

        return text
    }

    /// 从 SenseVoice 输出中提取语言标签
    static func extractLanguage(_ raw: String) -> String {
        // SenseVoice 格式: <|zh|><|NEUTRAL|><|Speech|><|woitn|>实际文本
        let pattern = #"<\|(zh|en|ja|ko|yue)\|>"#
        if let match = raw.range(of: pattern, options: .regularExpression) {
            let tag = raw[match]
            let lang = tag.replacingOccurrences(of: "<|", with: "")
                         .replacingOccurrences(of: "|>", with: "")
            return lang
        }
        return ""
    }

    /// 语言代码转友好名称
    static func languageName(_ code: String) -> String {
        switch code {
        case "zh": return "中文"
        case "en": return "English"
        case "ja": return "日本語"
        case "ko": return "한국어"
        case "yue": return "粤语"
        default: return code
        }
    }
}

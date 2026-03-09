// Sources/VoiceInput/TextPostProcessor.swift
// 识别结果后处理 — 清理、规范化、过滤
// Phase 6: Beta 优化 | Phase 3: 中英混合增强
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

    /// 检查检测到的语言是否在白名单内
    /// 如果不在白名单，尝试将结果映射到最可能的白名单语言
    /// 即使检测语言在白名单中，也会清理不属于白名单语言的字符（如日语假名混入中文）
    static func filterByLanguage(_ text: String, detectedLang: String, allowed: Set<String>) -> (text: String, lang: String) {

        // 无论检测语言是否在白名单中，都清理不属于白名单语言的字符
        var cleanedText = text

        // 日语假名清理（当 "ja" 不在白名单中）
        if !allowed.contains("ja") {
            let beforeClean = cleanedText
            // 移除平假名 U+3040-U+309F 和片假名 U+30A0-U+30FF
            cleanedText = String(cleanedText.unicodeScalars.filter { scalar in
                !((0x3040...0x309F).contains(scalar.value) ||
                  (0x30A0...0x30FF).contains(scalar.value))
            })
            if cleanedText != beforeClean {
                fputs("[PostProcessor] 清理日语假名: \"\(beforeClean)\" → \"\(cleanedText)\"\n", stderr)
            }
        }

        // 韩文清理（当 "ko" 不在白名单中）
        if !allowed.contains("ko") {
            let beforeClean = cleanedText
            cleanedText = String(cleanedText.unicodeScalars.filter { scalar in
                !(0xAC00...0xD7AF).contains(scalar.value)
            })
            if cleanedText != beforeClean {
                fputs("[PostProcessor] 清理韩文字符: \"\(beforeClean)\" → \"\(cleanedText)\"\n", stderr)
            }
        }

        cleanedText = cleanedText.trimmingCharacters(in: .whitespacesAndNewlines)

        // 清理后为空，说明整段都是非白名单语言
        if cleanedText.isEmpty {
            fputs("[PostProcessor] 清理后文本为空，丢弃\n", stderr)
            return ("", detectedLang)
        }

        // 如果在白名单内，返回清理后的文本
        if allowed.contains(detectedLang) {
            return (cleanedText, detectedLang)
        }

        // 以下处理检测语言不在白名单的情况
        let hasJapaneseKana = cleanedText.unicodeScalars.contains { scalar in
            (0x3040...0x309F).contains(scalar.value) ||
            (0x30A0...0x30FF).contains(scalar.value)
        }

        if hasJapaneseKana && !allowed.contains("ja") {
            fputs("[PostProcessor] 检测到日文假名字符，结果无效，丢弃\n", stderr)
            return ("", detectedLang)
        }

        // 日语误判处理：文本是汉字（中日共享），重映射为中文
        if detectedLang == "ja" && allowed.contains("zh") {
            fputs("[PostProcessor] 语言重映射: ja → zh（纯汉字内容）\n", stderr)
            return (cleanedText, "zh")
        }

        // 粤语误判处理
        if detectedLang == "yue" && allowed.contains("zh") {
            fputs("[PostProcessor] 语言重映射: yue → zh\n", stderr)
            return (cleanedText, "zh")
        }

        // 韩语误判处理
        if detectedLang == "ko" && !allowed.contains("ko") {
            let hasKorean = cleanedText.unicodeScalars.contains { (0xAC00...0xD7AF).contains($0.value) }
            if hasKorean {
                fputs("[PostProcessor] 检测到韩文字符，结果无效，丢弃\n", stderr)
                return ("", detectedLang)
            }
            let fallback = allowed.contains("zh") ? "zh" : (allowed.first ?? "en")
            return (cleanedText, fallback)
        }

        // 其他情况
        let fallback = allowed.contains("zh") ? "zh" : (allowed.first ?? "en")
        fputs("[PostProcessor] 语言重映射: \(detectedLang) → \(fallback)\n", stderr)
        return (cleanedText, fallback)
    }

    // MARK: - Phase 3: 中英混合增强

    /// 修复中英混合标点
    ///
    /// 规则：
    /// - 前后都是中文字符时，英文逗号 `,` → `，`
    /// - 句末且前面是中文字符时，英文句号 `.` → `。`
    static func fixMixedPunctuation(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        var chars = Array(text)
        var result = [Character]()
        result.reserveCapacity(chars.count)

        /// 判断 Unicode Scalar 是否为 CJK 汉字
        func isChinese(_ c: Character) -> Bool {
            guard let scalar = c.unicodeScalars.first else { return false }
            return (0x4E00...0x9FFF).contains(scalar.value) ||
                   (0x3400...0x4DBF).contains(scalar.value) ||
                   (0x3040...0x30FF).contains(scalar.value) ||
                   (0xAC00...0xD7AF).contains(scalar.value)
        }

        for i in 0..<chars.count {
            let c = chars[i]

            if c == "," {
                // 前一字符存在且为中文，后一字符存在且为中文 → 替换
                let prevChinese = i > 0 && isChinese(chars[i - 1])
                let nextChinese = i < chars.count - 1 && isChinese(chars[i + 1])
                if prevChinese && nextChinese {
                    result.append("，")
                } else {
                    result.append(c)
                }
            } else if c == "." {
                // 句末（最后一字符）且前面是中文 → 替换为句号
                let isEnd = i == chars.count - 1
                let prevChinese = i > 0 && isChinese(chars[i - 1])
                // 也处理 ".<space>$" 的情况（尾部空格）
                let isNearEnd = i == chars.count - 1 ||
                    (i == chars.count - 2 && chars[i + 1] == " ")
                if prevChinese && (isEnd || isNearEnd) {
                    result.append("。")
                } else {
                    result.append(c)
                }
            } else {
                result.append(c)
            }
        }

        return String(result)
    }

    /// 应用所有后处理：clean + fixMixedPunctuation + 语言过滤
    ///
    /// - Parameters:
    ///   - raw: ASR 原始输出（可含 SenseVoice token）
    ///   - allowedLanguages: 允许的语言白名单（空集合 = 不过滤）
    /// - Returns: `(text, lang)` 元组，text 为空表示应丢弃
    static func process(_ raw: String, allowedLanguages: Set<String>) -> (text: String, lang: String) {
        // Step 1: 提取语言
        let detectedLang = extractLanguage(raw).isEmpty ? "zh" : extractLanguage(raw)

        // Step 2: 清理文本（去 token、去噪）
        var text = clean(raw)
        guard !text.isEmpty else {
            return ("", detectedLang)
        }

        // Step 3: 修复中英混合标点
        text = fixMixedPunctuation(text)

        // Step 4: 语言过滤（空白名单 = 不过滤）
        if allowedLanguages.isEmpty {
            return (text, detectedLang)
        }
        return filterByLanguage(text, detectedLang: detectedLang, allowed: allowedLanguages)
    }
}

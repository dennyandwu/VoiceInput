// Sources/VoiceInput/WordLibraryManager.swift
// 本地 SQLite 词库管理 — 识别结果文本修正与热词加权
// Phase 1: SQLite 词库系统
// Copyright (c) 2026 urDAO Investment

import Foundation
import SQLite3

/// WordLibraryManager 提供本地 SQLite 词库，支持识别结果修正、热词加权、使用历史记录
final class WordLibraryManager {

    // MARK: - Singleton

    static let shared = WordLibraryManager()

    // MARK: - Private State

    private var db: OpaquePointer?
    private let lock = NSLock()

    /// 数据库文件路径：~/Library/Application Support/VoiceInput/wordlibrary.sqlite
    private let dbPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/VoiceInput/wordlibrary.sqlite"
    }()

    // MARK: - Init / Deinit

    private init() {
        ensureDirectoryExists()
        openDatabase()
        createTablesIfNeeded()
    }

    deinit {
        if db != nil {
            sqlite3_close(db)
            db = nil
        }
    }

    // MARK: - Setup

    private func ensureDirectoryExists() {
        let dir = (dbPath as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(
                atPath: dir,
                withIntermediateDirectories: true,
                attributes: nil
            )
        } catch {
            fputs("[WordLibrary] Failed to create directory \(dir): \(error)\n", stderr)
        }
    }

    private func openDatabase() {
        let result = sqlite3_open(dbPath, &db)
        if result != SQLITE_OK {
            let msg = db != nil ? String(cString: sqlite3_errmsg(db)) : "unknown error"
            fputs("[WordLibrary] Failed to open database at \(dbPath): \(msg)\n", stderr)
            db = nil
        } else {
            fputs("[WordLibrary] Database opened at \(dbPath)\n", stderr)
            // 开启 WAL 模式提升并发写入性能
            execute("PRAGMA journal_mode=WAL;")
            // 外键约束
            execute("PRAGMA foreign_keys=ON;")
        }
    }

    private func createTablesIfNeeded() {
        // 词库表
        execute("""
            CREATE TABLE IF NOT EXISTS words (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                original TEXT NOT NULL,
                correction TEXT NOT NULL,
                weight INTEGER DEFAULT 1,
                created_at INTEGER,
                updated_at INTEGER
            );
        """)

        // 使用历史
        execute("""
            CREATE TABLE IF NOT EXISTS usage_log (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                original TEXT NOT NULL,
                correction TEXT NOT NULL,
                used_at INTEGER
            );
        """)

        // 用户自定义热词
        execute("""
            CREATE TABLE IF NOT EXISTS hotwords (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                word TEXT NOT NULL UNIQUE,
                weight INTEGER DEFAULT 1
            );
        """)

        // 索引：按 original 快速查找
        execute("CREATE INDEX IF NOT EXISTS idx_words_original ON words(original);")
        execute("CREATE INDEX IF NOT EXISTS idx_words_weight ON words(weight DESC);")
    }

    // MARK: - Core SQL Helpers

    /// 执行无返回值的 SQL 语句（DDL / DML）
    @discardableResult
    private func execute(_ sql: String) -> Bool {
        guard let db = db else { return false }
        var errMsg: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if result != SQLITE_OK {
            let msg = errMsg != nil ? String(cString: errMsg!) : "unknown"
            fputs("[WordLibrary] SQL error (\(result)): \(msg)\nSQL: \(sql)\n", stderr)
            sqlite3_free(errMsg)
            return false
        }
        return true
    }

    /// 准备一条 SQL 语句
    private func prepare(_ sql: String) -> OpaquePointer? {
        guard let db = db else { return nil }
        var stmt: OpaquePointer?
        let result = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        if result != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            fputs("[WordLibrary] Failed to prepare statement: \(msg)\nSQL: \(sql)\n", stderr)
            return nil
        }
        return stmt
    }

    // MARK: - Public: Corrections

    /// 对识别结果应用词库修正（按 weight DESC 排序，避免短词替换冲突）
    func applyCorrections(to text: String) -> String {
        lock.lock()
        defer { lock.unlock() }

        let corrections = fetchAllCorrectionsInternal()
        guard !corrections.isEmpty else { return text }

        var result = text
        for (original, correction, _) in corrections {
            guard !original.isEmpty else { continue }
            result = result.replacingOccurrences(of: original, with: correction)
        }
        return result
    }

    /// 添加或更新修正条目（original → correction）
    /// 若 original 已存在则更新 correction 并重置 updated_at
    func addCorrection(original: String, correction: String) {
        lock.lock()
        defer { lock.unlock() }

        let now = Int(Date().timeIntervalSince1970)

        // UPSERT: 若 original 已存在则更新
        let sql = """
            INSERT INTO words (original, correction, weight, created_at, updated_at)
            VALUES (?, ?, 1, ?, ?)
            ON CONFLICT(original) DO UPDATE SET
                correction = excluded.correction,
                updated_at = excluded.updated_at;
        """
        // SQLite ON CONFLICT for non-UNIQUE columns needs a workaround — use manual check
        let checkSql = "SELECT id FROM words WHERE original = ?;"
        guard let checkStmt = prepare(checkSql) else { return }
        defer { sqlite3_finalize(checkStmt) }

        sqlite3_bind_text(checkStmt, 1, original, -1, SQLITE_TRANSIENT)
        let exists = sqlite3_step(checkStmt) == SQLITE_ROW

        if exists {
            let updateSql = "UPDATE words SET correction = ?, updated_at = ? WHERE original = ?;"
            guard let stmt = prepare(updateSql) else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, correction, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 2, Int64(now))
            sqlite3_bind_text(stmt, 3, original, -1, SQLITE_TRANSIENT)
            if sqlite3_step(stmt) != SQLITE_DONE {
                fputs("[WordLibrary] Failed to update correction for '\(original)'\n", stderr)
            }
        } else {
            let insertSql = "INSERT INTO words (original, correction, weight, created_at, updated_at) VALUES (?, ?, 1, ?, ?);"
            guard let stmt = prepare(insertSql) else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, original, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, correction, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 3, Int64(now))
            sqlite3_bind_int64(stmt, 4, Int64(now))
            if sqlite3_step(stmt) != SQLITE_DONE {
                fputs("[WordLibrary] Failed to insert correction for '\(original)'\n", stderr)
            }
        }
    }

    /// 记录一次使用：插入 usage_log 并将 words 表对应条目的 weight +1
    func recordUsage(original: String, correction: String) {
        lock.lock()
        defer { lock.unlock() }

        let now = Int(Date().timeIntervalSince1970)

        // 插入使用日志
        let logSql = "INSERT INTO usage_log (original, correction, used_at) VALUES (?, ?, ?);"
        guard let logStmt = prepare(logSql) else { return }
        defer { sqlite3_finalize(logStmt) }
        sqlite3_bind_text(logStmt, 1, original, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(logStmt, 2, correction, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(logStmt, 3, Int64(now))
        if sqlite3_step(logStmt) != SQLITE_DONE {
            fputs("[WordLibrary] Failed to insert usage_log for '\(original)'\n", stderr)
        }

        // 提升 words 表权重
        let updateSql = "UPDATE words SET weight = weight + 1, updated_at = ? WHERE original = ?;"
        guard let updateStmt = prepare(updateSql) else { return }
        defer { sqlite3_finalize(updateStmt) }
        sqlite3_bind_int64(updateStmt, 1, Int64(now))
        sqlite3_bind_text(updateStmt, 2, original, -1, SQLITE_TRANSIENT)
        if sqlite3_step(updateStmt) != SQLITE_DONE {
            fputs("[WordLibrary] Failed to update weight for '\(original)'\n", stderr)
        }
    }

    /// 删除修正条目
    func removeCorrection(original: String) {
        lock.lock()
        defer { lock.unlock() }

        let sql = "DELETE FROM words WHERE original = ?;"
        guard let stmt = prepare(sql) else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, original, -1, SQLITE_TRANSIENT)
        if sqlite3_step(stmt) != SQLITE_DONE {
            fputs("[WordLibrary] Failed to delete correction for '\(original)'\n", stderr)
        }
    }

    // MARK: - Public: Hotwords

    /// 添加热词（若已存在则 weight +1）
    func addHotword(_ word: String) {
        lock.lock()
        defer { lock.unlock() }

        // 先检查是否存在
        let checkSql = "SELECT id FROM hotwords WHERE word = ?;"
        guard let checkStmt = prepare(checkSql) else { return }
        defer { sqlite3_finalize(checkStmt) }
        sqlite3_bind_text(checkStmt, 1, word, -1, SQLITE_TRANSIENT)
        let exists = sqlite3_step(checkStmt) == SQLITE_ROW

        if exists {
            let updateSql = "UPDATE hotwords SET weight = weight + 1 WHERE word = ?;"
            guard let stmt = prepare(updateSql) else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, word, -1, SQLITE_TRANSIENT)
            if sqlite3_step(stmt) != SQLITE_DONE {
                fputs("[WordLibrary] Failed to update hotword weight for '\(word)'\n", stderr)
            }
        } else {
            let insertSql = "INSERT INTO hotwords (word, weight) VALUES (?, 1);"
            guard let stmt = prepare(insertSql) else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, word, -1, SQLITE_TRANSIENT)
            if sqlite3_step(stmt) != SQLITE_DONE {
                fputs("[WordLibrary] Failed to insert hotword '\(word)'\n", stderr)
            }
        }
    }

    /// 删除热词
    func removeHotword(_ word: String) {
        lock.lock()
        defer { lock.unlock() }

        let sql = "DELETE FROM hotwords WHERE word = ?;"
        guard let stmt = prepare(sql) else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, word, -1, SQLITE_TRANSIENT)
        if sqlite3_step(stmt) != SQLITE_DONE {
            fputs("[WordLibrary] Failed to delete hotword '\(word)'\n", stderr)
        }
    }

    /// 获取所有热词（按 weight DESC）
    func getAllHotwords() -> [(word: String, weight: Int)] {
        lock.lock()
        defer { lock.unlock() }

        let sql = "SELECT word, weight FROM hotwords ORDER BY weight DESC;"
        guard let stmt = prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }

        var results: [(word: String, weight: Int)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let word = String(cString: sqlite3_column_text(stmt, 0))
            let weight = Int(sqlite3_column_int(stmt, 1))
            results.append((word: word, weight: weight))
        }
        return results
    }

    // MARK: - Public: Query

    /// 获取所有修正条目（按 weight DESC）
    func getAllCorrections() -> [(original: String, correction: String, weight: Int)] {
        lock.lock()
        defer { lock.unlock() }
        return fetchAllCorrectionsInternal()
    }

    /// 搜索修正条目（original 或 correction 包含 query）
    func searchCorrections(query: String) -> [(original: String, correction: String, weight: Int)] {
        lock.lock()
        defer { lock.unlock() }

        let sql = """
            SELECT original, correction, weight
            FROM words
            WHERE original LIKE ? OR correction LIKE ?
            ORDER BY weight DESC;
        """
        guard let stmt = prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }

        let pattern = "%\(query)%"
        sqlite3_bind_text(stmt, 1, pattern, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, pattern, -1, SQLITE_TRANSIENT)

        var results: [(original: String, correction: String, weight: Int)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let original = String(cString: sqlite3_column_text(stmt, 0))
            let correction = String(cString: sqlite3_column_text(stmt, 1))
            let weight = Int(sqlite3_column_int(stmt, 2))
            results.append((original: original, correction: correction, weight: weight))
        }
        return results
    }

    // MARK: - Private Helpers

    /// 内部查询所有修正（调用前需持锁）
    private func fetchAllCorrectionsInternal() -> [(original: String, correction: String, weight: Int)] {
        let sql = "SELECT original, correction, weight FROM words ORDER BY weight DESC;"
        guard let stmt = prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }

        var results: [(original: String, correction: String, weight: Int)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let original = String(cString: sqlite3_column_text(stmt, 0))
            let correction = String(cString: sqlite3_column_text(stmt, 1))
            let weight = Int(sqlite3_column_int(stmt, 2))
            results.append((original: original, correction: correction, weight: weight))
        }
        return results
    }
}

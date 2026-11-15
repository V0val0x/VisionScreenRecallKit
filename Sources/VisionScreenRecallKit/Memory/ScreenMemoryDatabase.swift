import Foundation
import SQLite3

/// A single search hit or recent entry returned by `ScreenMemoryDatabase`.
public struct ScreenMemorySearchResult: Identifiable, Sendable, Equatable {
    public let id: Int64
    public let timestamp: Date
    public let sourceName: String
    public let sourceIdentifier: String
    public let extractedText: String
    public let highlightedSnippet: String
    public let thumbnailURL: URL

    public init(
        id: Int64,
        timestamp: Date,
        sourceName: String,
        sourceIdentifier: String = "",
        extractedText: String,
        highlightedSnippet: String,
        thumbnailURL: URL
    ) {
        self.id = id
        self.timestamp = timestamp
        self.sourceName = sourceName
        self.sourceIdentifier = sourceIdentifier
        self.extractedText = extractedText
        self.highlightedSnippet = highlightedSnippet
        self.thumbnailURL = thumbnailURL
    }

    /// Reads the JPEG thumbnail bytes from disk if the file still exists.
    public func loadThumbnailData() -> Data? {
        try? Data(contentsOf: thumbnailURL)
    }
}

/// Storage and index statistics reported by `ScreenMemoryDatabase`.
public struct ScreenMemoryDatabaseStats: Sendable, Equatable {
    public let count: Int
    public let thumbnailBytes: Int64
    public let databaseBytes: Int64

    public var totalBytes: Int64 {
        thumbnailBytes + databaseBytes
    }

    public init(count: Int, thumbnailBytes: Int64, databaseBytes: Int64) {
        self.count = count
        self.thumbnailBytes = thumbnailBytes
        self.databaseBytes = databaseBytes
    }
}

/// Thread-safe on-device SQLite3 + FTS5 database for Semantic Screen Memory ("Recall").
public final class ScreenMemoryDatabase: @unchecked Sendable {
    public static let shared = ScreenMemoryDatabase()

    public static let defaultRetentionDays: Int = 7
    public static let defaultMaxDiskCapMB: Int = 250

    public let baseDirectoryURL: URL
    public let thumbnailsDirectoryURL: URL
    public let databaseURL: URL
    public let retentionDays: Int
    public let maxDiskCapMB: Int

    private let queue = DispatchQueue(label: "com.visionscreenrecallkit.screenmemory.db", qos: .utility)
    private var db: OpaquePointer?

    public static var defaultBaseDirectoryURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport
            .appendingPathComponent("VisionScreenRecallKit", isDirectory: true)
            .appendingPathComponent("Memory", isDirectory: true)
    }

    public static var defaultDatabaseURL: URL {
        defaultBaseDirectoryURL.appendingPathComponent("memory.sqlite", isDirectory: false)
    }

    /// Initializes a database at a custom or default SQLite file URL, storing JPEG thumbnails alongside it.
    public init(
        databaseURL: URL = ScreenMemoryDatabase.defaultDatabaseURL,
        thumbnailsDirectoryURL: URL? = nil,
        retentionDays: Int = ScreenMemoryDatabase.defaultRetentionDays,
        maxDiskCapMB: Int = ScreenMemoryDatabase.defaultMaxDiskCapMB
    ) {
        let resolvedBase = databaseURL.deletingLastPathComponent()
        self.databaseURL = databaseURL
        self.baseDirectoryURL = resolvedBase
        self.thumbnailsDirectoryURL = thumbnailsDirectoryURL
            ?? resolvedBase.appendingPathComponent("thumbnails", isDirectory: true)
        self.retentionDays = max(1, retentionDays)
        self.maxDiskCapMB = max(1, maxDiskCapMB)

        queue.sync {
            openAndMigrateLocked()
        }
    }

    /// Convenience initializer targeting a base directory (creating `memory.sqlite` and `thumbnails/` inside).
    public convenience init(
        baseDirectoryURL: URL,
        retentionDays: Int = ScreenMemoryDatabase.defaultRetentionDays,
        maxDiskCapMB: Int = ScreenMemoryDatabase.defaultMaxDiskCapMB
    ) {
        self.init(
            databaseURL: baseDirectoryURL.appendingPathComponent("memory.sqlite", isDirectory: false),
            thumbnailsDirectoryURL: baseDirectoryURL.appendingPathComponent("thumbnails", isDirectory: true),
            retentionDays: retentionDays,
            maxDiskCapMB: maxDiskCapMB
        )
    }

    deinit {
        queue.sync {
            if let db {
                sqlite3_close(db)
            }
            self.db = nil
        }
    }

    /// Inserts a snapshot using an already-written JPEG filename in `thumbnailsDirectoryURL` and returns its row ID.
    @discardableResult
    public func insertSnapshot(
        timestamp: Date = Date(),
        sourceName: String,
        sourceIdentifier: String = "",
        extractedText: String,
        thumbnailFilename: String,
        frameHash: UInt64
    ) -> Int64? {
        queue.sync {
            insertSnapshotLocked(
                timestamp: timestamp,
                sourceName: sourceName,
                sourceIdentifier: sourceIdentifier,
                extractedText: extractedText,
                thumbnailFilename: thumbnailFilename,
                frameHash: frameHash
            )
        }
    }

    /// Writes `thumbnailJPEGData` to `thumbnailsDirectoryURL` and inserts the snapshot record into SQLite FTS5.
    @discardableResult
    public func insertSnapshot(
        timestamp: Date = Date(),
        sourceName: String,
        sourceIdentifier: String = "",
        extractedText: String,
        thumbnailJPEGData: Data,
        frameHash: UInt64
    ) -> Int64? {
        let thumbFilename = "\(Int(timestamp.timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).jpg"
        let thumbURL = thumbnailsDirectoryURL.appendingPathComponent(thumbFilename, isDirectory: false)
        do {
            try FileManager.default.createDirectory(at: thumbnailsDirectoryURL, withIntermediateDirectories: true)
            try thumbnailJPEGData.write(to: thumbURL, options: .atomic)
        } catch {
            return nil
        }

        let rowId = queue.sync {
            insertSnapshotLocked(
                timestamp: timestamp,
                sourceName: sourceName,
                sourceIdentifier: sourceIdentifier,
                extractedText: extractedText,
                thumbnailFilename: thumbFilename,
                frameHash: frameHash
            )
        }
        if rowId == nil {
            try? FileManager.default.removeItem(at: thumbURL)
        }
        return rowId
    }

    /// Performs real-time FTS5 search with `snippet()` highlighting, or returns recent snapshots when `query` is empty.
    public func search(query: String, limit: Int = 40) -> [ScreenMemorySearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return queue.sync {
            guard let db else { return [] }
            if trimmed.isEmpty {
                return fetchRecentLocked(db: db, limit: min(limit, 25))
            }
            guard let ftsQuery = Self.buildSafeFTS5Query(from: trimmed) else {
                return []
            }

            let sql = """
            SELECT s.id, s.timestamp, s.source_name, s.source_identifier, s.extracted_text,
                   snippet(snapshots_fts, 0, '«', '»', '…', 14), s.thumbnail_path
            FROM snapshots_fts
            JOIN snapshots s ON s.id = snapshots_fts.rowid
            WHERE snapshots_fts MATCH ?
            ORDER BY s.timestamp DESC
            LIMIT ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, ftsQuery, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 2, Int32(limit))

            var results: [ScreenMemorySearchResult] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(stmt, 0)
                let ts = sqlite3_column_double(stmt, 1)
                let source = columnString(stmt, index: 2)
                let identifier = columnString(stmt, index: 3)
                let text = columnString(stmt, index: 4)
                let snippetText = columnString(stmt, index: 5)
                let thumbRel = columnString(stmt, index: 6)
                results.append(ScreenMemorySearchResult(
                    id: id,
                    timestamp: Date(timeIntervalSince1970: ts),
                    sourceName: source,
                    sourceIdentifier: identifier,
                    extractedText: text,
                    highlightedSnippet: snippetText.isEmpty ? String(text.prefix(160)) : snippetText,
                    thumbnailURL: resolveThumbnailURL(thumbRel)
                ))
            }
            return results
        }
    }

    /// Enforces retention days and `maxDiskCapMB` cap, deleting expired rows and `.jpg` files.
    @discardableResult
    public func pruneRetention(
        now: Date = Date(),
        olderThanDays: Int? = nil,
        maxDiskCapMB: Int? = nil
    ) -> Int {
        let capMB = maxDiskCapMB ?? self.maxDiskCapMB
        let capBytes = Int64(max(0, capMB)) * 1024 * 1024
        return pruneRetention(
            now: now,
            olderThanDays: olderThanDays,
            maxThumbnailBytes: capBytes
        )
    }

    /// Enforces retention days and byte-exact `maxThumbnailBytes` cap, deleting expired rows and `.jpg` files.
    @discardableResult
    public func pruneRetention(
        now: Date = Date(),
        olderThanDays: Int? = nil,
        maxThumbnailBytes: Int64
    ) -> Int {
        let effectiveDays = olderThanDays ?? self.retentionDays
        return queue.sync {
            guard let db else { return 0 }
            var deletedCount = 0
            let cutoff = now.addingTimeInterval(-TimeInterval(effectiveDays * 86_400)).timeIntervalSince1970

            // 1. Delete rows older than retention window
            let expired = selectRows(
                db: db,
                sql: "SELECT id, thumbnail_path FROM snapshots WHERE timestamp < ?;",
                bindDouble: cutoff
            )
            for row in expired {
                if deleteRowLocked(db: db, id: row.id, thumbnailPath: row.thumb) {
                    deletedCount += 1
                }
            }

            // 2. Enforce thumbnail disk cap by pruning oldest snapshots first
            var totalBytes = directorySizeBytes(thumbnailsDirectoryURL)
            if totalBytes > maxThumbnailBytes {
                let oldest = selectRows(
                    db: db,
                    sql: "SELECT id, thumbnail_path FROM snapshots ORDER BY timestamp ASC;",
                    bindDouble: nil
                )
                for row in oldest {
                    guard totalBytes > maxThumbnailBytes else { break }
                    let fileURL = resolveThumbnailURL(row.thumb)
                    let fileSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                    if deleteRowLocked(db: db, id: row.id, thumbnailPath: row.thumb) {
                        totalBytes = max(0, totalBytes - fileSize)
                        deletedCount += 1
                    }
                }
            }

            if deletedCount > 0 {
                _ = execSQL(db: db, "PRAGMA optimize;")
            }
            return deletedCount
        }
    }

    /// Deletes all indexed screen memory records and thumbnails.
    public func clearAll() {
        queue.sync {
            guard let db else { return }
            _ = execSQL(db: db, "DELETE FROM snapshots;")
            _ = execSQL(db: db, "VACUUM;")
            let fm = FileManager.default
            if let files = try? fm.contentsOfDirectory(at: thumbnailsDirectoryURL, includingPropertiesForKeys: nil) {
                for url in files {
                    try? fm.removeItem(at: url)
                }
            }
        }
    }

    /// Returns total snapshot count, thumbnail storage size, and SQLite database file size in bytes.
    public func stats() -> ScreenMemoryDatabaseStats {
        queue.sync {
            guard let db else {
                return ScreenMemoryDatabaseStats(count: 0, thumbnailBytes: 0, databaseBytes: 0)
            }
            var stmt: OpaquePointer?
            var count = 0
            if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM snapshots;", -1, &stmt, nil) == SQLITE_OK {
                if sqlite3_step(stmt) == SQLITE_ROW {
                    count = Int(sqlite3_column_int64(stmt, 0))
                }
            }
            sqlite3_finalize(stmt)

            let thumbBytes = directorySizeBytes(thumbnailsDirectoryURL)
            let dbBytes = fileSizeBytes(databaseURL)
                + fileSizeBytes(URL(fileURLWithPath: databaseURL.path + "-wal"))
            return ScreenMemoryDatabaseStats(
                count: count,
                thumbnailBytes: thumbBytes,
                databaseBytes: dbBytes
            )
        }
    }

    /// Converts arbitrary user input into a safe FTS5 prefix query (`"word1"* "word2"*`).
    public static func buildSafeFTS5Query(from raw: String) -> String? {
        let tokens = raw
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        return tokens.map { "\"\($0)\"*" }.joined(separator: " ")
    }

    // MARK: - Private SQLite Helpers

    private func insertSnapshotLocked(
        timestamp: Date,
        sourceName: String,
        sourceIdentifier: String,
        extractedText: String,
        thumbnailFilename: String,
        frameHash: UInt64
    ) -> Int64? {
        guard let db else { return nil }
        let sql = """
        INSERT INTO snapshots (timestamp, source_name, source_identifier, extracted_text, thumbnail_path, frame_hash)
        VALUES (?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_double(stmt, 1, timestamp.timeIntervalSince1970)
        sqlite3_bind_text(stmt, 2, sourceName, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, sourceIdentifier, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, extractedText, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 5, thumbnailFilename, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 6, Int64(bitPattern: frameHash))

        guard sqlite3_step(stmt) == SQLITE_DONE else { return nil }
        return sqlite3_last_insert_rowid(db)
    }

    private func openAndMigrateLocked() {
        let fm = FileManager.default
        try? fm.createDirectory(at: baseDirectoryURL, withIntermediateDirectories: true)
        try? fm.createDirectory(at: thumbnailsDirectoryURL, withIntermediateDirectories: true)

        var handle: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let handle else {
            return
        }
        self.db = handle

        _ = execSQL(db: handle, "PRAGMA journal_mode = WAL;")
        _ = execSQL(db: handle, "PRAGMA synchronous = NORMAL;")

        let schemaSQL = """
        CREATE TABLE IF NOT EXISTS snapshots (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp REAL NOT NULL,
            source_name TEXT NOT NULL,
            source_identifier TEXT NOT NULL DEFAULT '',
            extracted_text TEXT NOT NULL,
            thumbnail_path TEXT NOT NULL,
            frame_hash INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_snapshots_timestamp ON snapshots(timestamp DESC);
        CREATE VIRTUAL TABLE IF NOT EXISTS snapshots_fts USING fts5(
            extracted_text,
            source_name,
            source_identifier,
            content='snapshots',
            content_rowid='id',
            tokenize='porter unicode61'
        );
        CREATE TRIGGER IF NOT EXISTS snapshots_ai AFTER INSERT ON snapshots BEGIN
            INSERT INTO snapshots_fts(rowid, extracted_text, source_name, source_identifier)
            VALUES (new.id, new.extracted_text, new.source_name, new.source_identifier);
        END;
        CREATE TRIGGER IF NOT EXISTS snapshots_ad AFTER DELETE ON snapshots BEGIN
            INSERT INTO snapshots_fts(snapshots_fts, rowid, extracted_text, source_name, source_identifier)
            VALUES ('delete', old.id, old.extracted_text, old.source_name, old.source_identifier);
        END;
        """
        _ = execSQL(db: handle, schemaSQL)
    }

    private func fetchRecentLocked(db: OpaquePointer, limit: Int) -> [ScreenMemorySearchResult] {
        let sql = """
        SELECT id, timestamp, source_name, source_identifier, extracted_text, thumbnail_path
        FROM snapshots
        ORDER BY timestamp DESC
        LIMIT ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))

        var results: [ScreenMemorySearchResult] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let ts = sqlite3_column_double(stmt, 1)
            let source = columnString(stmt, index: 2)
            let identifier = columnString(stmt, index: 3)
            let text = columnString(stmt, index: 4)
            let thumbRel = columnString(stmt, index: 5)
            results.append(ScreenMemorySearchResult(
                id: id,
                timestamp: Date(timeIntervalSince1970: ts),
                sourceName: source,
                sourceIdentifier: identifier,
                extractedText: text,
                highlightedSnippet: String(text.prefix(160)),
                thumbnailURL: resolveThumbnailURL(thumbRel)
            ))
        }
        return results
    }

    private func selectRows(db: OpaquePointer, sql: String, bindDouble: Double?) -> [(id: Int64, thumb: String)] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        if let bindDouble {
            sqlite3_bind_double(stmt, 1, bindDouble)
        }
        var rows: [(Int64, String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append((sqlite3_column_int64(stmt, 0), columnString(stmt, index: 1)))
        }
        return rows
    }

    private func deleteRowLocked(db: OpaquePointer, id: Int64, thumbnailPath: String) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM snapshots WHERE id = ?;", -1, &stmt, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_DONE else { return false }

        let fileURL = resolveThumbnailURL(thumbnailPath)
        try? FileManager.default.removeItem(at: fileURL)
        return true
    }

    private func execSQL(db: OpaquePointer, _ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    private func columnString(_ stmt: OpaquePointer?, index: Int32) -> String {
        guard let cStr = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: cStr)
    }

    private func resolveThumbnailURL(_ filenameOrPath: String) -> URL {
        if filenameOrPath.hasPrefix("/") {
            return URL(fileURLWithPath: filenameOrPath)
        }
        return thumbnailsDirectoryURL.appendingPathComponent(filenameOrPath, isDirectory: false)
    }

    private func fileSizeBytes(_ url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    }

    private func directorySizeBytes(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        return files.reduce(0) { sum, fileURL in
            sum + fileSizeBytes(fileURL)
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

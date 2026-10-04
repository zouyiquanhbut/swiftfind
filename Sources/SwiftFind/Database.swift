import Foundation
import CSQLite

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}

final class Database {
    private var handle: OpaquePointer?
    private var readHandle: OpaquePointer?
    private let readQueue = DispatchQueue(label: "swiftfind.read")
    private let gramStateLock = NSLock()
    private var gramIndexReady = false
    private let queue = DispatchQueue(label: "swiftfind.database")
    private let searchWorker = DispatchQueue(label: "swiftfind.search", qos: .userInitiated)

    // Never wait for SQLite's serialization queue on the UI thread.
    func searchAsync(_ query: SearchQuery, sort: ResultSort, ascending: Bool) async throws -> [FileRecord] {
        try await withCheckedThrowingContinuation { continuation in
            searchWorker.async {
                let result: Result<[FileRecord], Error> = Result {
                    if query.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       query.extensionName == nil, query.pathPrefix == nil, query.kind == nil,
                       query.minimumSize == nil, query.modifiedAfter == nil {
                        return try self.desktopItems(includeHidden: query.includeHidden)
                    }
                    // Do not perform a full 382k-path filesystem scan before
                    // returning search results. Stale rows are filtered while
                    // reading the result set and cleaned asynchronously below.
                    return try self.search(query, sort: sort, ascending: ascending)
                }
                continuation.resume(with: result)
            }
        }
    }

    init() throws {
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("SwiftFind", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("index.sqlite")
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw DatabaseError.openFailed }
        sqlite3_busy_timeout(handle, 5000)
        try execute("PRAGMA journal_mode=WAL;")
        try execute("PRAGMA synchronous=NORMAL;")
        try execute("CREATE TABLE IF NOT EXISTS schema_info (key TEXT PRIMARY KEY, value TEXT NOT NULL);")
        try execute("""
        CREATE TABLE IF NOT EXISTS files (
            id INTEGER PRIMARY KEY,
            path TEXT NOT NULL UNIQUE,
            name TEXT NOT NULL,
            is_directory INTEGER NOT NULL,
            size INTEGER NOT NULL,
            modified_at REAL,
            volume TEXT NOT NULL
        );
        CREATE VIRTUAL TABLE IF NOT EXISTS file_search USING fts5(
            path UNINDEXED, name, tokenize='unicode61 remove_diacritics 2'
        );
        """)
        try execute("INSERT OR IGNORE INTO schema_info(key,value) VALUES('version','2');")
        try execute("CREATE TABLE IF NOT EXISTS name_grams (gram TEXT NOT NULL, path TEXT NOT NULL, PRIMARY KEY(gram, path)); CREATE INDEX IF NOT EXISTS name_grams_gram ON name_grams(gram);")
        // Build the optional acceleration index after startup; LIKE remains the safe fallback.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            try? self?.buildNameGramIndexIfNeeded()
        }
        guard sqlite3_open_v2(url.path, &readHandle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw DatabaseError.openFailed }
        sqlite3_busy_timeout(readHandle, 1000)
    }

    deinit {
        if let readHandle { sqlite3_close(readHandle) }
        if let handle { sqlite3_close(handle) }
    }

    func execute(_ sql: String) throws {
        try queue.sync {
            var error: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
                let message = error.map { String(cString: $0) } ?? "Unknown SQLite error"
                sqlite3_free(error)
                throw DatabaseError.queryFailed(message)
            }
        }
    }

    func replace(records: [FileRecord]) throws {
        gramStateLock.withLock { gramIndexReady = false }
        try queue.sync {
            try run("BEGIN TRANSACTION;")
            do {
                try run("DELETE FROM files;")
                try run("DELETE FROM file_search;")
                try run("DELETE FROM name_grams;")
                let insert = try prepare("INSERT INTO files(path,name,is_directory,size,modified_at,volume) VALUES(?,?,?,?,?,?);")
                let fts = try prepare("INSERT INTO file_search(path,name) VALUES(?,?);")
                defer { sqlite3_finalize(insert); sqlite3_finalize(fts) }
                for record in records {
                    bind(record, to: insert)
                    guard sqlite3_step(insert) == SQLITE_DONE else { throw DatabaseError.queryFailed(lastError) }
                    sqlite3_reset(insert); sqlite3_clear_bindings(insert)
                    sqlite3_bind_text(fts, 1, record.path, -1, sqliteTransient)
                    sqlite3_bind_text(fts, 2, record.name, -1, sqliteTransient)
                    guard sqlite3_step(fts) == SQLITE_DONE else { throw DatabaseError.queryFailed(lastError) }
                    sqlite3_reset(fts); sqlite3_clear_bindings(fts)
                    try insertNameGrams(record)
                }
                try run("COMMIT;")
            } catch { try? run("ROLLBACK;"); throw error }
        }
    }

    func upsert(records: [FileRecord]) throws {
        guard !records.isEmpty else { return }
        gramStateLock.withLock { gramIndexReady = false }
        try queue.sync {
            try run("BEGIN TRANSACTION;")
            do {
                let removeFTS = try prepare("DELETE FROM file_search WHERE path = ?;")
                let upsert = try prepare("INSERT INTO files(path,name,is_directory,size,modified_at,volume) VALUES(?,?,?,?,?,?) ON CONFLICT(path) DO UPDATE SET name=excluded.name,is_directory=excluded.is_directory,size=excluded.size,modified_at=excluded.modified_at,volume=excluded.volume;")
                let insertFTS = try prepare("INSERT INTO file_search(path,name) VALUES(?,?);")
                defer { sqlite3_finalize(removeFTS); sqlite3_finalize(upsert); sqlite3_finalize(insertFTS) }
                for record in records {
                    sqlite3_bind_text(removeFTS, 1, record.path, -1, sqliteTransient)
                    guard sqlite3_step(removeFTS) == SQLITE_DONE else { throw DatabaseError.queryFailed(lastError) }
                    sqlite3_reset(removeFTS); sqlite3_clear_bindings(removeFTS)
                    bind(record, to: upsert)
                    guard sqlite3_step(upsert) == SQLITE_DONE else { throw DatabaseError.queryFailed(lastError) }
                    sqlite3_reset(upsert); sqlite3_clear_bindings(upsert)
                    sqlite3_bind_text(insertFTS, 1, record.path, -1, sqliteTransient)
                    sqlite3_bind_text(insertFTS, 2, record.name, -1, sqliteTransient)
                    guard sqlite3_step(insertFTS) == SQLITE_DONE else { throw DatabaseError.queryFailed(lastError) }
                    sqlite3_reset(insertFTS); sqlite3_clear_bindings(insertFTS)
                    try insertNameGrams(record)
                }
                try run("COMMIT;")
            } catch { try? run("ROLLBACK;"); throw error }
        }
    }

    /// Lightweight incremental update used for moved/target items. Search reads
    /// from `files`; rebuilding FTS and name grams for every move is unnecessary
    /// and can monopolize SQLite for a large index.
    func upsertFileRows(_ records: [FileRecord]) throws {
        guard !records.isEmpty else { return }
        try queue.sync {
            try run("BEGIN TRANSACTION;")
            do {
                let upsert = try prepare("INSERT INTO files(path,name,is_directory,size,modified_at,volume) VALUES(?,?,?,?,?,?) ON CONFLICT(path) DO UPDATE SET name=excluded.name,is_directory=excluded.is_directory,size=excluded.size,modified_at=excluded.modified_at,volume=excluded.volume;")
                defer { sqlite3_finalize(upsert) }
                for record in records {
                    bind(record, to: upsert)
                    guard sqlite3_step(upsert) == SQLITE_DONE else { throw DatabaseError.queryFailed(lastError) }
                    sqlite3_reset(upsert); sqlite3_clear_bindings(upsert)
                }
                try run("COMMIT;")
            } catch { try? run("ROLLBACK;"); throw error }
        }
    }

    /// Lightweight removal for a burst of filesystem events. The current
    /// LIKE-based search only needs the main files table; FTS/grams are kept
    /// for explicit rebuilds and are not touched per event.
    func removeFileRowsOnly(paths: [String]) throws {
        guard !paths.isEmpty else { return }
        try queue.sync {
            try run("BEGIN TRANSACTION;")
            do {
                let statement = try prepare("DELETE FROM files WHERE path = ? OR path LIKE ?;")
                defer { sqlite3_finalize(statement) }
                for path in Set(paths) {
                    let pattern = path.hasSuffix("/") ? "\(path)%" : "\(path)/%"
                    sqlite3_bind_text(statement, 1, path, -1, sqliteTransient)
                    sqlite3_bind_text(statement, 2, pattern, -1, sqliteTransient)
                    guard sqlite3_step(statement) == SQLITE_DONE else { throw DatabaseError.queryFailed(lastError) }
                    sqlite3_reset(statement); sqlite3_clear_bindings(statement)
                }
                try run("COMMIT;")
            } catch { try? run("ROLLBACK;"); throw error }
        }
    }

    func remove(paths: [String]) throws {
        guard !paths.isEmpty else { return }
        try queue.sync {
            try run("BEGIN TRANSACTION;")
            do {
                let fts = try prepare("DELETE FROM file_search WHERE path = ? OR path LIKE ?;")
                let grams = try prepare("DELETE FROM name_grams WHERE path = ? OR path LIKE ?;")
                let files = try prepare("DELETE FROM files WHERE path = ? OR path LIKE ?;")
                defer { sqlite3_finalize(fts); sqlite3_finalize(grams); sqlite3_finalize(files) }
                for path in paths {
                    let pattern = path.hasSuffix("/") ? "\(path)%" : "\(path)/%"
                    for statement in [fts, grams, files] {
                        sqlite3_bind_text(statement, 1, path, -1, sqliteTransient)
                        sqlite3_bind_text(statement, 2, pattern, -1, sqliteTransient)
                        guard sqlite3_step(statement) == SQLITE_DONE else { throw DatabaseError.queryFailed(lastError) }
                        sqlite3_reset(statement); sqlite3_clear_bindings(statement)
                    }
                }
                try run("COMMIT;")
            } catch { try? run("ROLLBACK;"); throw error }
        }
    }

    /// Direct children of the user's Desktop, used as the default empty-search view.
    func desktopItems(limit: Int = 1_000, includeHidden: Bool = false) throws -> [FileRecord] {
        guard let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first else { return [] }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .nameKey, .volumeNameKey]
        let urls = try FileManager.default.contentsOfDirectory(at: desktop, includingPropertiesForKeys: Array(keys), options: includeHidden ? [] : [.skipsHiddenFiles])
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys), let name = values.name else { return nil }
            return FileRecord(id: 0, path: url.path, name: name, isDirectory: values.isDirectory ?? false, size: Int64(values.fileSize ?? 0), modifiedAt: values.contentModificationDate, volume: values.volumeName ?? "Unknown")
        }
        .sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory && !$1.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        .prefix(limit)
        .map { $0 }

    }

    func recent(limit: Int = 50) throws -> [FileRecord] {
        try queue.sync {
            let statement = try prepare("SELECT id,path,name,is_directory,size,modified_at,volume FROM files ORDER BY modified_at DESC LIMIT \(limit);")
            defer { sqlite3_finalize(statement) }
            var result: [FileRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW { result.append(readRecord(statement)) }
            return result
        }
    }

    func indexedCount() throws -> Int {
        try queue.sync {
            let statement = try prepare("SELECT COUNT(*) FROM files;")
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { throw DatabaseError.queryFailed(lastError) }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    func search(_ query: SearchQuery, sort: ResultSort = .name, ascending: Bool = true, limit: Int? = nil) throws -> [FileRecord] {
        try readQueue.sync {
            func prepareRead(_ sql: String) throws -> OpaquePointer? {
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(readHandle, sql, -1, &statement, nil) == SQLITE_OK else {
                    throw DatabaseError.queryFailed(String(cString: sqlite3_errmsg(readHandle)))
                }
                return statement
            }
            var sql = "SELECT f.id,f.path,f.name,f.is_directory,f.size,f.modified_at,f.volume FROM files f"
            var args: [String] = []
            var rankingArguments: [String] = []
            sql += " WHERE 1=1"
            if !query.includeHidden { sql += " AND f.name NOT LIKE '.%'" }
            if !query.text.isEmpty {
                // Plain LIKE matching is intentionally used for correctness across
                // Chinese, numbers, symbols, and SQLite builds with different FTS tokenizers.
                // FTS5 remains in the schema for a later indexed fast path.
                let terms = query.text.split(whereSeparator: { $0 == " " || $0 == "\t" })
                // A space-separated query is a relevance query: return items
                // matching any term, then rank filename hits before path hits.
                // The old AND/gram combination removed filename-only matches
                // for the first term before relevance sorting could run.
                let field = query.scope == .name ? "f.name" : "f.path"
                let termConditions = terms.map { _ in "lower(\(field)) LIKE ? ESCAPE '\\'" }.joined(separator: " OR ")
                sql += " AND (\(termConditions))"
                for term in terms {
                    let escaped = term.description.lowercased()
                        .replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "%", with: "\\%")
                        .replacingOccurrences(of: "_", with: "\\_")
                    let pattern = "%\(escaped)%"
                    args.append(pattern)
                }
            }
            if let ext = query.extensionName {
                let normalizedExtension = ext.hasPrefix(".") ? ext : ".\(ext)"
                let escapedExtension = normalizedExtension.lowercased()
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "%", with: "\\%")
                    .replacingOccurrences(of: "_", with: "\\_")
                // Extension filters apply to files; folders remain available
                // for the folder-name relevance tiers.
                sql += " AND (f.is_directory = 1 OR lower(f.name) LIKE ? ESCAPE '\\')"
                args.append("%\(escapedExtension)")
            }
            if let path = query.pathPrefix { sql += " AND f.path LIKE ?"; args.append(path.hasSuffix("/") ? "\(path)%" : "\(path)/%") }
            if let kind = query.kind { sql += " AND f.is_directory = \(kind == .folder ? 1 : 0)" }
            if let minimumSize = query.minimumSize { sql += " AND f.size >= \(minimumSize)" }
            if let modifiedAfter = query.modifiedAfter { sql += " AND f.modified_at >= \(modifiedAfter.timeIntervalSince1970)" }
            // Explicit relevance tiers. For `A BIM` with `ext:c` this is:
            // exact A_B.c, A_B folder, A_B file, A folder, A file,
            // BIM folder, BIM file, then path A_B/A/BIM.
            var orderParts: [String] = []
            let terms = query.text.split(whereSeparator: { $0 == " " || $0 == "\t" }).map { $0.description.lowercased() }
            if !terms.isEmpty {
                let combo = terms.joined(separator: "_")
                let comboPattern = "%\(combo)%"
                let exactName = combo + (query.extensionName.map { ".\($0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")))" } ?? "")
                var rankCases = ["CASE WHEN lower(f.name) = ? THEN 0"]
                rankingArguments.append(exactName)
                rankCases.append("WHEN f.is_directory = 1 AND lower(f.name) LIKE ? ESCAPE '\\' THEN 1")
                rankingArguments.append(comboPattern)
                rankCases.append("WHEN f.is_directory = 0 AND lower(f.name) LIKE ? ESCAPE '\\' THEN 2")
                rankingArguments.append(comboPattern)
                for (index, term) in terms.enumerated() {
                    let pattern = "%\(term)%"
                    rankCases.append("WHEN f.is_directory = 1 AND lower(f.name) LIKE ? ESCAPE '\\' THEN \(3 + index * 2)")
                    rankingArguments.append(pattern)
                    rankCases.append("WHEN f.is_directory = 0 AND lower(f.name) LIKE ? ESCAPE '\\' THEN \(4 + index * 2)")
                    rankingArguments.append(pattern)
                }
                rankCases.append("WHEN lower(f.path) LIKE ? ESCAPE '\\' THEN 7")
                rankingArguments.append(comboPattern)
                for (index, term) in terms.enumerated() {
                    rankCases.append("WHEN lower(f.path) LIKE ? ESCAPE '\\' THEN \(8 + index)")
                    rankingArguments.append("%\(term)%")
                }
                rankCases.append("ELSE 100 END ASC")
                orderParts.append(rankCases.joined(separator: " "))
            }
            let direction = ascending ? "ASC" : "DESC"
            switch sort {
            case .name: orderParts.append("f.name COLLATE NOCASE \(direction)"); orderParts.append("f.path COLLATE NOCASE ASC")
            case .kind: orderParts.append("f.is_directory \(direction)"); orderParts.append("lower(f.name) ASC")
            case .size: orderParts.append("f.size \(direction)"); orderParts.append("lower(f.name) ASC")
            case .modified: orderParts.append("f.modified_at \(direction)"); orderParts.append("lower(f.name) ASC")
            }
            sql += " ORDER BY \(orderParts.joined(separator: ", "))"
            if let limit { sql += " LIMIT \(limit)" }
            sql += ";"
            args.append(contentsOf: rankingArguments)
            let statement = try prepareRead(sql); defer { sqlite3_finalize(statement) }
            for (index, arg) in args.enumerated() { sqlite3_bind_text(statement, Int32(index + 1), arg, -1, sqliteTransient) }
            var result: [FileRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let record = readRecord(statement)
                // Do not perform heavyweight index deletion while a search is
                // running. Missing rows are simply hidden and can be cleaned
                // during an explicit index maintenance operation.
                if FileManager.default.fileExists(atPath: record.path) {
                    result.append(record)
                }
            }
            return result
        }
    }

    private static func bigrams(_ value: String) -> [String] {
        let chars = Array(value.lowercased())
        guard chars.count >= 2 else { return [] }
        return (0..<(chars.count - 1)).map { String(chars[$0...($0 + 1)]) }
    }

    private func insertNameGrams(_ record: FileRecord) throws {
        let statement = try prepare("INSERT OR IGNORE INTO name_grams(gram,path) VALUES(?,?);")
        defer { sqlite3_finalize(statement) }
        for gram in Self.bigrams(record.name) {
            sqlite3_bind_text(statement, 1, gram, -1, sqliteTransient)
            sqlite3_bind_text(statement, 2, record.path, -1, sqliteTransient)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw DatabaseError.queryFailed(lastError) }
            sqlite3_reset(statement); sqlite3_clear_bindings(statement)
        }
    }

    private func buildNameGramIndexIfNeeded() throws {
        try queue.sync {
            var statement = try prepare("SELECT COUNT(*) FROM name_grams;")
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { throw DatabaseError.queryFailed(lastError) }
            if sqlite3_column_int64(statement, 0) > 0 {
                gramStateLock.withLock { gramIndexReady = true }
                return
            }
            try run("BEGIN TRANSACTION;")
            do {
                let files = try prepare("SELECT id,path,name,is_directory,size,modified_at,volume FROM files;")
                defer { sqlite3_finalize(files) }
                while sqlite3_step(files) == SQLITE_ROW {
                    try insertNameGrams(readRecord(files))
                }
                try run("COMMIT;")
                gramStateLock.withLock { gramIndexReady = true }
            } catch { try? run("ROLLBACK;"); throw error }
        }
    }

    private static func ftsPrefixQuery(_ text: String) -> String {
        text.split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map { token in
                let escaped = token.replacingOccurrences(of: "\"", with: "\"\"")
                return "\"\(escaped)\"*"
            }
            .joined(separator: " AND ")
    }

    private var lastError: String { handle.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite error" }
    private func run(_ sql: String) throws { guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw DatabaseError.queryFailed(lastError) } }
    private func prepare(_ sql: String) throws -> OpaquePointer? { var statement: OpaquePointer?; guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw DatabaseError.queryFailed(lastError) }; return statement }
    private func bind(_ record: FileRecord, to statement: OpaquePointer?) { sqlite3_bind_text(statement, 1, record.path, -1, sqliteTransient); sqlite3_bind_text(statement, 2, record.name, -1, sqliteTransient); sqlite3_bind_int(statement, 3, record.isDirectory ? 1 : 0); sqlite3_bind_int64(statement, 4, record.size); if let date = record.modifiedAt { sqlite3_bind_double(statement, 5, date.timeIntervalSince1970) } else { sqlite3_bind_null(statement, 5) }; sqlite3_bind_text(statement, 6, record.volume, -1, sqliteTransient) }
    private func readRecord(_ statement: OpaquePointer?) -> FileRecord { FileRecord(id: sqlite3_column_int64(statement, 0), path: String(cString: sqlite3_column_text(statement, 1)), name: String(cString: sqlite3_column_text(statement, 2)), isDirectory: sqlite3_column_int(statement, 3) != 0, size: sqlite3_column_int64(statement, 4), modifiedAt: sqlite3_column_type(statement, 5) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)), volume: String(cString: sqlite3_column_text(statement, 6))) }
}

enum DatabaseError: LocalizedError { case openFailed, queryFailed(String); var errorDescription: String? { switch self { case .openFailed: "无法打开索引数据库"; case .queryFailed(let message): message } } }

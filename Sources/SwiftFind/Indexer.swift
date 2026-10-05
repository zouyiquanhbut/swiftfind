import Foundation
import SwiftUI
import AppKit

final class Indexer: ObservableObject {
    @Published private(set) var isIndexing = false
    @Published private(set) var indexedCount = 0
    @Published var root: URL?
    @Published var status = "尚未建立索引"

    private let database: Database
    private let worker = DispatchQueue(label: "swiftfind.indexer", qos: .utility)
    private var watcher: FSEventsWatcher?
    private var watchedRoots: [URL] = []
    private var scopedRoots: [URL] = []
    private var pendingEvents: [String: FSEventStreamEventFlags] = [:]
    private var pendingFlushWork: DispatchWorkItem?
    private let bookmarkKey = "SwiftFind.indexRoots"

    init(database: Database) {
        self.database = database
        restoreSavedRoots()
    }

    func chooseAndIndex() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "索引此目录"
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        saveRoots(urls)
        root = urls.first
        watchedRoots = urls
        beginAccessing(urls)
        index(urls: urls)
    }

    private func restoreSavedRoots() {
        guard let values = UserDefaults.standard.array(forKey: bookmarkKey) as? [Data] else { return }
        var urls: [URL] = []
        var refreshedBookmarks: [Data] = []
        for data in values {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) else { continue }
            if stale, let refreshed = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
                refreshedBookmarks.append(refreshed)
            } else {
                refreshedBookmarks.append(data)
            }
            if url.startAccessingSecurityScopedResource() { scopedRoots.append(url) }
            urls.append(url)
        }
        UserDefaults.standard.set(refreshedBookmarks, forKey: bookmarkKey)
        guard !urls.isEmpty else { return }
        root = urls.first
        watchedRoots = urls
        startWatcher()
        status = "已恢复索引目录，实时监听中"
        let restoredURLs = urls
        worker.async { [weak self] in
            guard let self else { return }
            let count = (try? self.database.indexedCount()) ?? 0
            DispatchQueue.main.async {
                guard self.watchedRoots == restoredURLs, !self.isIndexing else { return }
                self.indexedCount = count
                if count == 0 {
                    self.status = "正在建立首次索引…"
                    self.index(urls: restoredURLs)
                } else {
                    self.status = "已恢复 \(count.formatted()) 个项目，实时监听中"
                }
            }
        }
    }

    private func saveRoots(_ urls: [URL]) {
        let bookmarks = urls.compactMap { try? $0.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) }
        UserDefaults.standard.set(bookmarks, forKey: bookmarkKey)
    }

    private func beginAccessing(_ urls: [URL]) {
        scopedRoots.forEach { $0.stopAccessingSecurityScopedResource() }
        scopedRoots = urls.filter { $0.startAccessingSecurityScopedResource() }
    }

    func index(urls: [URL]) {
        guard !urls.isEmpty else {
            status = "请先选择要索引的目录"
            return
        }
        guard !isIndexing else { return }
        isIndexing = true; indexedCount = 0; status = "正在扫描…"
        worker.async { [weak self] in
            guard let self else { return }
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .nameKey, .volumeNameKey]
            var records: [FileRecord] = []
            for url in urls {
                if let rootRecord = self.makeRecord(url: url, keys: keys) { records.append(rootRecord) }
                guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else { continue }
                for case let fileURL as URL in enumerator {
                    autoreleasepool {
                        guard let values = try? fileURL.resourceValues(forKeys: keys), let name = values.name else { return }
                        let record = FileRecord(id: 0, path: fileURL.path, name: name, isDirectory: values.isDirectory ?? false, size: Int64(values.fileSize ?? 0), modifiedAt: values.contentModificationDate, volume: values.volumeName ?? fileURL.pathComponents.dropFirst().first ?? "Unknown")
                        records.append(record)
                        if records.count % 1000 == 0 { DispatchQueue.main.async { self.indexedCount = records.count } }
                    }
                }
            }
            do {
                try self.database.replace(records: records)
                self.startWatcher()
                DispatchQueue.main.async { self.indexedCount = records.count; self.status = "已索引 \(records.count.formatted()) 个项目，实时监听中" }
            } catch { DispatchQueue.main.async { self.status = "索引失败：\(error.localizedDescription)" } }
            DispatchQueue.main.async { self.isIndexing = false }
        }
    }

    /// Add content from folders that are not part of the selected index roots.
    /// This is used for persistent target folders and for newly moved items.
    func indexAdditional(urls: [URL], recursive: Bool = true) {
        let uniqueURLs = Array(Set(urls.map { $0.standardizedFileURL }))
        guard !uniqueURLs.isEmpty else { return }
        worker.async { [weak self] in
            guard let self else { return }
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .nameKey, .volumeNameKey]
            var records: [FileRecord] = []
            for url in uniqueURLs {
                if let record = self.makeRecord(url: url, keys: keys) { records.append(record) }
                guard let values = try? url.resourceValues(forKeys: keys), values.isDirectory == true else { continue }
                if recursive {
                    guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else { continue }
                    for case let child as URL in enumerator {
                        autoreleasepool {
                            if let record = self.makeRecord(url: child, keys: keys) { records.append(record) }
                        }
                    }
                } else if let children = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) {
                    for child in children {
                        if let record = self.makeRecord(url: child, keys: keys) { records.append(record) }
                    }
                }
            }
            guard !records.isEmpty else { return }
            guard (try? self.database.upsertFileRows(records)) != nil else { return }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .swiftFindIndexDidChange, object: nil, userInfo: ["indexedDestinationPaths": true])
            }
        }
    }

    deinit { scopedRoots.forEach { $0.stopAccessingSecurityScopedResource() } }

    private func makeRecord(url: URL, keys: Set<URLResourceKey>) -> FileRecord? {
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        let name = values.name ?? url.lastPathComponent
        guard !name.isEmpty else { return nil }
        return FileRecord(id: 0, path: url.path, name: name, isDirectory: values.isDirectory ?? false, size: Int64(values.fileSize ?? 0), modifiedAt: values.contentModificationDate, volume: values.volumeName ?? url.pathComponents.dropFirst().first ?? "Unknown")
    }

    private func startWatcher() {
        watcher = FSEventsWatcher(paths: watchedRoots.map(\.path)) { [weak self] path, flags in
            self?.handle(path: path, flags: flags)
        }
    }

    private func handle(path: String, flags: FSEventStreamEventFlags) {
        // Ignore our own SQLite/WAL activity before it enters the pending queue.
        if isInternalPath(path) { return }
        // FSEvents can report a large burst for one filesystem operation. Move
        // the coalescing state onto the indexer queue so it is synchronized.
        worker.async { [weak self] in
            guard let self else { return }
            self.pendingEvents[path] = (self.pendingEvents[path] ?? 0) | flags
            guard self.pendingFlushWork == nil else { return }
            let work = DispatchWorkItem { [weak self] in self?.flushPendingEvents() }
            self.pendingFlushWork = work
            self.worker.asyncAfter(deadline: .now() + 0.35, execute: work)
        }
    }

    private func flushPendingEvents() {
        let events = pendingEvents
        pendingEvents.removeAll()
        pendingFlushWork = nil
        var removedPaths: [String] = []
        var changedRecords: [FileRecord] = []
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .nameKey, .volumeNameKey]
        for (path, flags) in events {
            if flags & UInt32(kFSEventStreamEventFlagItemRemoved) != 0 || !FileManager.default.fileExists(atPath: path) {
                removedPaths.append(path)
                continue
            }
            let url = URL(fileURLWithPath: path)
            if let values = try? url.resourceValues(forKeys: keys), let name = values.name {
                changedRecords.append(FileRecord(id: 0, path: path, name: name, isDirectory: values.isDirectory ?? false, size: Int64(values.fileSize ?? 0), modifiedAt: values.contentModificationDate, volume: values.volumeName ?? "Unknown"))
            }
        }
        var changed = false
        if !removedPaths.isEmpty {
            try? database.removeFileRowsOnly(paths: removedPaths)
            changed = true
        }
        if !changedRecords.isEmpty {
            try? database.upsertFileRows(changedRecords)
            changed = true
        }
        if changed { publishStatus("索引已实时更新") }
    }

    private func isInternalPath(_ path: String) -> Bool {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return false }
        let ownPath = support.appendingPathComponent("SwiftFind").path
        return path == ownPath || path.hasPrefix(ownPath + "/")
    }

    private func publishStatus(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.status = message
            NotificationCenter.default.post(name: .swiftFindIndexDidChange, object: nil)
        }
    }
}

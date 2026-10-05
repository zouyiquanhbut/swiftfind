import AppKit
import Foundation

@MainActor
final class FolderWorkspaceModel: ObservableObject {
    @Published private(set) var currentFolder: URL?
    @Published private(set) var items: [FileRecord] = []
    private(set) var itemsRevision = 0
    @Published private(set) var isLoading = false
    @Published var error: String?
    @Published var showHidden = false
    @Published var targetedFolderID: Int64?
    @Published var selectedItemID: Int64?

    private var history: [URL] = []
    private var loadTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var generation = 0
    private var observer: NSObjectProtocol?
    private struct CachedFolder {
        let records: [FileRecord]
        let includeHidden: Bool
    }
    private var cache: [URL: CachedFolder] = [:]
    private var cacheOrder: [URL] = []

    init() {
        observer = NotificationCenter.default.addObserver(forName: .swiftFindIndexDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.scheduleRefresh() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        loadTask?.cancel()
        refreshTask?.cancel()
    }

    var canGoBack: Bool { !history.isEmpty }
    var folderName: String { currentFolder?.lastPathComponent ?? "文件夹" }

    func open(_ folder: URL, recordHistory: Bool = true) {
        let normalized = folder.standardizedFileURL
        if currentFolder != normalized { selectedItemID = nil }
        if recordHistory, let currentFolder, currentFolder != normalized { history.append(currentFolder) }
        currentFolder = normalized
        restoreCachedItems(for: normalized)
        refresh()
    }

    func goBack() {
        guard let previous = history.popLast() else { return }
        selectedItemID = nil
        currentFolder = previous
        restoreCachedItems(for: previous)
        refresh()
    }

    func close() {
        loadTask?.cancel()
        refreshTask?.cancel()
        generation += 1
        history.removeAll()
        selectedItemID = nil
        currentFolder = nil
        items.removeAll()
        itemsRevision &+= 1
        isLoading = false
        error = nil
    }

    func refresh() {
        guard let folder = currentFolder else { return }
        loadTask?.cancel()
        generation += 1
        let requestedGeneration = generation
        let includeHidden = showHidden
        isLoading = true
        error = nil
        loadTask = Task.detached(priority: .userInitiated) {
            do {
                let values: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
                let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(values), options: includeHidden ? [] : [.skipsHiddenFiles])
                var records: [FileRecord] = []
                records.reserveCapacity(urls.count)
                for url in urls {
                    try Task.checkCancellation()
                    guard let resource = try? url.resourceValues(forKeys: values) else { continue }
                    let id = Int64(url.path.hashValue)
                    records.append(FileRecord(id: id, path: url.path, name: url.lastPathComponent, isDirectory: resource.isDirectory ?? false, size: Int64(resource.fileSize ?? 0), modifiedAt: resource.contentModificationDate, volume: ""))
                }
                records.sort {
                    if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
                let loadedRecords = records
                await MainActor.run {
                    guard self.generation == requestedGeneration, self.currentFolder == folder else { return }
                    self.setItems(loadedRecords)
                    self.remember(loadedRecords, for: folder, includeHidden: includeHidden)
                    if !loadedRecords.contains(where: { $0.id == self.selectedItemID }) {
                        self.selectedItemID = nil
                    }
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    guard self.generation == requestedGeneration else { return }
                    self.setItems([])
                    self.cache.removeValue(forKey: folder)
                    self.selectedItemID = nil
                    self.isLoading = false
                    self.error = "无法读取文件夹：\(error.localizedDescription)"
                }
            }
        }
    }

    private func setItems(_ records: [FileRecord]) {
        guard items != records else { return }
        items = records
        itemsRevision &+= 1
    }

    private func restoreCachedItems(for folder: URL) {
        let entry = cache[folder]
        setItems(entry?.includeHidden == showHidden ? entry?.records ?? [] : [])
    }

    private func remember(_ records: [FileRecord], for folder: URL, includeHidden: Bool) {
        cache[folder] = CachedFolder(records: records, includeHidden: includeHidden)
        cacheOrder.removeAll { $0 == folder }
        cacheOrder.append(folder)
        while cacheOrder.count > 8 || cache.values.reduce(0, { $0 + $1.records.count }) > 20_000 {
            cache.removeValue(forKey: cacheOrder.removeFirst())
        }
    }

    func scheduleRefresh() {
        guard currentFolder != nil else { return }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled, let self else { return }
            self.refreshTask = nil
            self.refresh()
        }
    }

    func createFolder() {
        guard let currentFolder else { return }
        let alert = NSAlert()
        alert.messageText = "新建文件夹"
        alert.informativeText = "输入文件夹名称："
        let field = NSTextField(string: "新建文件夹")
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "创建")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            _ = try FileOperationService.createFolder(at: currentFolder, name: field.stringValue)
            publishChange()
            refresh()
        } catch { showError("无法新建文件夹", error.localizedDescription) }
    }

    func rename(_ item: FileRecord) {
        let alert = NSAlert()
        alert.messageText = "重命名"
        alert.informativeText = item.isDirectory ? "输入文件夹的新名称：" : "输入文件的新名称："
        let field = NSTextField(string: item.name)
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "重命名")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let destination = try FileOperationService.rename(item.url, to: field.stringValue)
            publishChange(moved: [item.url.path], destinations: [destination.path])
            refresh()
        } catch { showError("无法重命名", error.localizedDescription) }
    }

    func trash(_ item: FileRecord) {
        do {
            try FileOperationService.trash([item.url])
            publishChange(moved: [item.url.path])
            items.removeAll { $0.id == item.id }
            itemsRevision &+= 1
            if let currentFolder { cache.removeValue(forKey: currentFolder) }
            if selectedItemID == item.id { selectedItemID = nil }
        } catch { showError("无法移到废纸篓", error.localizedDescription) }
    }

    func moveDroppedProviders(_ providers: [NSItemProvider], to destination: URL) {
        FileOperationService.loadURLs(from: providers) { [weak self] urls in
            self?.moveDroppedURLs(urls, to: destination)
        }
    }

    func moveDroppedURLs(_ urls: [URL], to destination: URL) {
        do {
            let moves = try FileOperationService.move(urls, to: destination)
            guard !moves.isEmpty else { return }
            cache.removeAll()
            cacheOrder.removeAll()
            publishChange(moved: moves.map { $0.source.path }, destinations: moves.map { $0.destination.path })
            refresh()
        } catch { showError("无法移动项目", error.localizedDescription) }
    }

    func open(_ item: FileRecord) {
        if item.isDirectory { open(item.url) }
        else { NSWorkspace.shared.open(item.url) }
    }

    func reveal(_ item: FileRecord) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }

    private func publishChange(moved: [String] = [], destinations: [String] = []) {
        var info: [String: Any] = [:]
        if !moved.isEmpty { info["movedPaths"] = moved }
        if !destinations.isEmpty { info["movedDestinationPaths"] = destinations }
        NotificationCenter.default.post(name: .swiftFindIndexDidChange, object: nil, userInfo: info)
    }

    private func showError(_ title: String, _ detail: String) {
        error = detail
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.runModal()
    }
}

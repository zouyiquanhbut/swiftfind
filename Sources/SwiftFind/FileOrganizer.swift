import AppKit
import Foundation
import UniformTypeIdentifiers

struct FolderTarget: Identifiable, Hashable {
    let id: UUID
    var name: String
    var url: URL
    var bookmark: Data
}

@MainActor
final class FileOrganizer: ObservableObject {
    @Published private(set) var targets: [FolderTarget] = []
    @Published var hoveredTargetID: UUID?
    @Published var targetDropIndex: Int?
    @Published var isMoving = false
    @Published var message: String?
    @Published var error: String?

    private var lastMoves: [(source: URL, destination: URL)] = []
    private var scopedTargets: [URL] = []
    private let fileManager = FileManager.default
    private let storageKey = "SwiftFind.targetFolders"
    private let reorderType = swiftFindTargetReorderType

    init() { restoreTargets() }

    deinit { scopedTargets.forEach { $0.stopAccessingSecurityScopedResource() } }

    func addTargetFromProviders(_ providers: [NSItemProvider]) {
        guard let provider = providers.first else { return }
        if provider.hasItemConformingToTypeIdentifier(swiftFindPathsType) {
            provider.loadDataRepresentation(forTypeIdentifier: swiftFindPathsType) { [weak self] data, _ in
                guard let data, let paths = try? JSONDecoder().decode([String].self, from: data), let path = paths.first else { return }
                DispatchQueue.main.async { self?.addTarget(url: URL(fileURLWithPath: path)) }
            }
            return
        }
        let identifiers = [swiftFindPathType, UTType.fileURL.identifier, UTType.url.identifier, UTType.data.identifier]
        guard let identifier = identifiers.first(where: provider.hasItemConformingToTypeIdentifier) else { return }
        provider.loadDataRepresentation(forTypeIdentifier: identifier) { [weak self] data, _ in
            guard let data else { return }
            let url: URL?
            if identifier == swiftFindPathType {
                let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : nil
            } else if let parsed = URL(dataRepresentation: data, relativeTo: nil), parsed.isFileURL {
                url = parsed
            } else {
                let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if let parsed = URL(string: text), parsed.isFileURL { url = parsed }
                else if text.hasPrefix("/") { url = URL(fileURLWithPath: text) }
                else { url = nil }
            }
            guard let url else { return }
            DispatchQueue.main.async { self?.addTarget(url: url) }
        }
    }

    func addTarget() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "添加目标文件夹"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addTarget(url: url)
    }

    func createTarget() {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = true
        panel.nameFieldStringValue = "新建文件夹"
        panel.prompt = "创建并添加"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            addTarget(url: url)
        } catch {
            self.error = "无法创建文件夹：\(error.localizedDescription)"
        }
    }

    func moveTarget(from source: Int, to destination: Int) {
        guard targets.indices.contains(source), destination >= 0, destination <= targets.count, source != destination else { return }
        let target = targets.remove(at: source)
        let insertion = min(destination, targets.count)
        targets.insert(target, at: insertion)
        saveTargets()
    }

    func setTargetDropIndex(_ index: Int?) { targetDropIndex = index }

    func handleTargetAreaDrop(_ providers: [NSItemProvider], position: Int, target: URL?) {
        if providers.contains(where: { $0.hasItemConformingToTypeIdentifier(reorderType) }) {
            handleTargetDrop(providers, to: position)
        } else if let target {
            moveDroppedProviders(providers, to: target)
        } else {
            addTargetFromProviders(providers)
        }
    }

    func moveTarget(id: UUID, to destination: Int) {
        guard let source = targets.firstIndex(where: { $0.id == id }) else { return }
        let adjusted = source < destination ? destination - 1 : destination
        moveTarget(from: source, to: max(0, adjusted))
        targetDropIndex = nil
        hoveredTargetID = nil
    }

    func handleTargetDrop(_ providers: [NSItemProvider], to destination: Int) {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(reorderType) }) else { return }
        provider.loadDataRepresentation(forTypeIdentifier: reorderType) { [weak self] data, _ in
            guard let data, let rawID = String(data: data, encoding: .utf8), let sourceID = UUID(uuidString: rawID) else { return }
            DispatchQueue.main.async {
                guard let self, let source = self.targets.firstIndex(where: { $0.id == sourceID }) else { return }
                let insertion = self.targetDropIndex ?? destination
                let adjusted = source < insertion ? insertion - 1 : insertion
                self.moveTarget(from: source, to: max(0, adjusted))
                self.targetDropIndex = nil
                self.hoveredTargetID = nil
            }
        }
    }

    func removeTarget(_ target: FolderTarget) {
        targets.removeAll { $0.id == target.id }
        target.url.stopAccessingSecurityScopedResource()
        scopedTargets.removeAll { $0 == target.url }
        saveTargets()
    }

    @discardableResult
    func move(records: [FileRecord], to destination: URL) -> Bool {
        move(urls: records.map(\.url), to: destination)
    }

    @discardableResult
    func move(urls: [URL], to destination: URL) -> Bool {
        let normalizedDestination = destination.standardizedFileURL
        error = nil
        message = nil
        var sources: [URL] = []
        for source in urls {
            guard source.isFileURL else { error = "拖入的不是本地文件 URL"; return false }
            let source = source.standardizedFileURL
            if sources.contains(source) { continue }
            let canonicalSource = source.resolvingSymlinksInPath().path
            let canonicalDestination = normalizedDestination.resolvingSymlinksInPath().path
            guard canonicalDestination != canonicalSource,
                  !canonicalDestination.hasPrefix(canonicalSource + "/") else {
                error = "不能把文件夹移动到自身或其内部。\n源：\(source.path)\n目标：\(normalizedDestination.path)"
                return false
            }
            if source.deletingLastPathComponent().resolvingSymlinksInPath().path == canonicalDestination { continue }
            do { _ = try fileManager.attributesOfItem(atPath: source.path) }
            catch {
                let detail = error as NSError
                self.error = "无法访问源项目（可能已移动、索引过期或权限不足）。\n源：\(source.path)\n目标：\(normalizedDestination.path)\n\(detail.domain) / \(detail.code)：\(detail.localizedDescription)"
                return false
            }
            sources.append(source)
        }
        // Moving a selected parent already includes its selected descendants.
        sources = sources.filter { child in
            !sources.contains { parent in parent != child && child.path.hasPrefix(parent.path + "/") }
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: normalizedDestination.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            error = "目标文件夹不存在或不是文件夹：\(normalizedDestination.path)"
            return false
        }
        guard !sources.isEmpty else {
            message = "没有需要移动的项目：拖入项目已在目标文件夹中，或拖放列表为空。"
            return false
        }
        isMoving = true
        error = nil
        message = nil
        lastMoves.removeAll()
        var currentSource: URL?
        var currentTarget: URL?
        do {
            for source in sources {
                currentSource = source
                let target = uniqueTarget(for: normalizedDestination.appendingPathComponent(source.lastPathComponent))
                currentTarget = target
                try fileManager.moveItem(at: source, to: target)
                lastMoves.append((source, target))
            }
            message = "已移动 \(sources.count) 个项目到 \(normalizedDestination.lastPathComponent)"
            let completedSources = lastMoves.map(\.source.path)
            let completedDestinations = lastMoves.map(\.destination.path)
            NotificationCenter.default.post(name: .swiftFindIndexDidChange, object: nil, userInfo: [
                "movedPaths": completedSources,
                "movedDestinationPaths": completedDestinations
            ])
        } catch let moveError {
            let detail = moveError as NSError
            self.error = "已移动 \(lastMoves.count) 项；后续移动失败。\n源：\(currentSource?.path ?? "未知")\n目标：\(currentTarget?.path ?? "未知")\n\(detail.domain) / \(detail.code)：\(detail.localizedDescription)"
        }
        isMoving = false
        return self.error == nil
    }

    func undoLastMove() {
        guard !lastMoves.isEmpty else { return }
        do {
            for move in lastMoves.reversed() where fileManager.fileExists(atPath: move.destination.path) {
                guard !fileManager.fileExists(atPath: move.source.path) else { continue }
                try fileManager.moveItem(at: move.destination, to: move.source)
            }
            lastMoves.removeAll()
            message = "已撤销上次移动"
            NotificationCenter.default.post(name: .swiftFindIndexDidChange, object: nil, userInfo: ["restoredPaths": lastMoves.map { $0.source.path }])
        } catch let undoError {
            self.error = "撤销失败：\(undoError.localizedDescription)"
        }
    }

    func moveDroppedProviders(_ providers: [NSItemProvider], to destination: URL) {
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()
        let identifiers = [swiftFindPathsType, swiftFindPathType, UTType.fileURL.identifier, UTType.url.identifier, UTType.data.identifier]
        for provider in providers where identifiers.contains(where: provider.hasItemConformingToTypeIdentifier) {
            group.enter()
            if provider.hasItemConformingToTypeIdentifier(swiftFindPathsType) {
                provider.loadDataRepresentation(forTypeIdentifier: swiftFindPathsType) { data, _ in
                    defer { group.leave() }
                    guard let data, let paths = try? JSONDecoder().decode([String].self, from: data),
                          !paths.isEmpty, paths.allSatisfy({ $0.hasPrefix("/") }) else { return }
                    lock.lock()
                    urls.append(contentsOf: paths.map { URL(fileURLWithPath: $0) })
                    lock.unlock()
                }
                continue
            }
            loadURL(from: provider, identifiers: identifiers) { url in
                defer { group.leave() }
                guard let url else { return }
                lock.lock(); urls.append(url); lock.unlock()
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            if urls.isEmpty {
                self.error = "没有读取到拖入项目的本地路径，请从文件名或图标区域开始拖动"
                return
            }
            self.move(urls: urls, to: destination)
        }
    }

    private func loadURL(from provider: NSItemProvider, identifiers: [String], completion: @escaping (URL?) -> Void) {
        guard let identifier = identifiers.first(where: provider.hasItemConformingToTypeIdentifier) else {
            completion(nil); return
        }
        provider.loadDataRepresentation(forTypeIdentifier: identifier) { [weak provider] data, _ in
            if identifier == swiftFindPathType, let data {
                let path = String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
                completion(path.hasPrefix("/") ? URL(fileURLWithPath: path) : nil)
                return
            }
            if let data, let url = Self.decodeURLData(data) {
                completion(url); return
            }
            guard let provider else { completion(nil); return }
            provider.loadItem(forTypeIdentifier: identifier, options: nil) { item, _ in
                if let url = item as? URL { completion(url) }
                else if let url = item as? NSURL { completion(url as URL) }
                else if let data = item as? Data { completion(Self.decodeURLData(data)) }
                else if let text = item as? String { completion(Self.decodeURLText(text)) }
                else { completion(nil) }
            }
        }
    }

    private static func decodeURLData(_ data: Data) -> URL? {
        if let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL { return url }
        if let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
           let urlString = plist as? String { return decodeURLText(urlString) }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return decodeURLText(text)
    }

    private static func decodeURLText(_ text: String) -> URL? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        guard !value.isEmpty else { return nil }
        if let url = URL(string: value), url.isFileURL { return url }
        return value.hasPrefix("/") ? URL(fileURLWithPath: value) : nil
    }

    private func addTarget(url: URL) {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            error = "只能将文件夹添加为目标文件夹"
            return
        }
        guard !targets.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) else { return }
        guard let bookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) else {
            error = "无法保存目标文件夹权限"
            return
        }
        _ = url.startAccessingSecurityScopedResource()
        scopedTargets.append(url)
        targets.append(FolderTarget(id: UUID(), name: url.lastPathComponent, url: url, bookmark: bookmark))
        saveTargets()
    }

    private func restoreTargets() {
        guard let saved = UserDefaults.standard.array(forKey: storageKey) as? [[String: Any]] else { return }
        for item in saved {
            guard let data = item["bookmark"] as? Data else { continue }
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) else { continue }
            guard url.startAccessingSecurityScopedResource() else { continue }
            let refreshed = (stale ? try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) : nil) ?? data
            scopedTargets.append(url)
            targets.append(FolderTarget(id: UUID(), name: url.lastPathComponent, url: url, bookmark: refreshed))
        }
        saveTargets()
    }

    private func saveTargets() {
        let values = targets.map { ["bookmark": $0.bookmark] as [String: Any] }
        UserDefaults.standard.set(values, forKey: storageKey)
    }

    private func uniqueTarget(for proposed: URL) -> URL {
        guard fileManager.fileExists(atPath: proposed.path) else { return proposed }
        let ext = proposed.pathExtension
        let stem = proposed.deletingPathExtension().lastPathComponent
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        var number = 2
        var candidate: URL
        repeat {
            candidate = proposed.deletingLastPathComponent().appendingPathComponent("\(stem) \(number)\(suffix)")
            number += 1
        } while fileManager.fileExists(atPath: candidate.path)
        return candidate
    }
}

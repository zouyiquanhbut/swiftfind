import AppKit
import Foundation
import UniformTypeIdentifiers

enum FileOperationService {
    static let dropTypes = [swiftFindPathsType, swiftFindPathType, UTType.fileURL.identifier, UTType.url.identifier, UTType.data.identifier]

    static func createFolder(at parent: URL, name: String) throws -> URL {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/") else { throw FileOperationError.invalidName }
        let destination = parent.appendingPathComponent(trimmed, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        return destination
    }

    static func rename(_ source: URL, to name: String) throws -> URL {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/") else { throw FileOperationError.invalidName }
        let destination = source.deletingLastPathComponent().appendingPathComponent(trimmed, isDirectory: source.hasDirectoryPath)
        try FileManager.default.moveItem(at: source, to: destination)
        return destination
    }

    struct MoveResult {
        let moved: [(source: URL, destination: URL)]
        let error: Error?
    }

    static func move(_ sources: [URL], to folder: URL) throws -> [(source: URL, destination: URL)] {
        let result = movePartially(sources, to: folder)
        if let error = result.error, result.moved.isEmpty { throw error }
        return result.moved
    }

    static func movePartially(_ sources: [URL], to folder: URL) -> MoveResult {
        let fileManager = FileManager.default
        let destination = folder.standardizedFileURL
        var moves: [(source: URL, destination: URL)] = []
        let normalizedSources = sources.map { $0.standardizedFileURL }.reduce(into: [URL]()) { result, source in
            guard !result.contains(source) else { return }
            guard !result.contains(where: { source.path.hasPrefix($0.path + "/") }) else { return }
            result.append(source)
        }
        for source in normalizedSources {
            guard source != destination,
                  !destination.path.hasPrefix(source.path + "/"),
                  source.deletingLastPathComponent().standardizedFileURL != destination else { continue }
            let target = uniqueTarget(for: destination.appendingPathComponent(source.lastPathComponent, isDirectory: source.hasDirectoryPath))
            do {
                try fileManager.moveItem(at: source, to: target)
            } catch {
                return MoveResult(moved: moves, error: error)
            }
            moves.append((source, target))
        }
        return MoveResult(moved: moves, error: nil)
    }

    static func trash(_ sources: [URL]) throws {
        for source in sources { try FileManager.default.trashItem(at: source, resultingItemURL: nil) }
    }

    static func provider(for urls: [URL]) -> NSItemProvider {
        let provider = NSItemProvider()
        let paths = urls.map(\.path)
        let payload = (try? JSONEncoder().encode(paths)) ?? Data()
        provider.suggestedName = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) 个项目"
        provider.registerDataRepresentation(forTypeIdentifier: swiftFindPathsType, visibility: .ownProcess) { completion in
            completion(payload, nil)
            return nil
        }
        return provider
    }

    static func loadURLs(from providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for provider in providers where dropTypes.contains(where: provider.hasItemConformingToTypeIdentifier) {
            group.enter()
            let identifier = dropTypes.first(where: provider.hasItemConformingToTypeIdentifier)!
            provider.loadDataRepresentation(forTypeIdentifier: identifier) { data, _ in
                defer { group.leave() }
                guard let data else { return }
                let parsed: [URL]
                if identifier == swiftFindPathsType, let paths = try? JSONDecoder().decode([String].self, from: data) {
                    parsed = paths.map { URL(fileURLWithPath: $0) }
                } else if let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL {
                    parsed = [url]
                } else {
                    let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    parsed = text.hasPrefix("/") ? [URL(fileURLWithPath: text)] : []
                }
                lock.lock(); urls.append(contentsOf: parsed); lock.unlock()
            }
        }
        group.notify(queue: .main) { completion(urls) }
    }

    static func urls(from pasteboard: NSPasteboard) -> [URL] {
        if let data = pasteboard.data(forType: NSPasteboard.PasteboardType(swiftFindPathsType)),
           let paths = try? JSONDecoder().decode([String].self, from: data) {
            return paths.map { URL(fileURLWithPath: $0) }
        }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            return urls
        }
        if let path = pasteboard.string(forType: NSPasteboard.PasteboardType(swiftFindPathType)), path.hasPrefix("/") {
            return [URL(fileURLWithPath: path)]
        }
        return []
    }

    private static func uniqueTarget(for proposed: URL) -> URL {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: proposed.path) else { return proposed }
        let ext = proposed.pathExtension
        let stem = proposed.deletingPathExtension().lastPathComponent
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        var number = 2
        var candidate: URL
        repeat {
            candidate = proposed.deletingLastPathComponent().appendingPathComponent("\(stem) \(number)\(suffix)", isDirectory: proposed.hasDirectoryPath)
            number += 1
        } while fileManager.fileExists(atPath: candidate.path)
        return candidate
    }
}

enum FileOperationError: LocalizedError {
    case invalidName
    var errorDescription: String? {
        switch self { case .invalidName: "名称不能为空，且不能包含斜杠" }
    }
}

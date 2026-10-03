import AppKit
import Foundation
import UniformTypeIdentifiers
let swiftFindPathType = "com.swiftfind.file-path"
let swiftFindPathsType = "com.swiftfind.file-paths"
extension Notification.Name { static let swiftFindIndexDidChange = Notification.Name("testIndex") }
struct FileRecord { let url: URL }
@main struct OrganizerSmoke {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let dest = root.appendingPathComponent("目标")
        let nested = dest.appendingPathComponent("子目录")
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        let source = nested.appendingPathComponent(" 天夏 1.md")
        try Data("hello".utf8).write(to: source)
        let organizer = FileOrganizer()
        organizer.move(urls: [source], to: dest)
        precondition(organizer.error == nil, organizer.error ?? "")
        let moved = dest.appendingPathComponent(source.lastPathComponent)
        precondition(fm.fileExists(atPath: moved.path))
        organizer.undoLastMove()
        precondition(fm.fileExists(atPath: source.path))
        organizer.move(urls: [dest], to: nested)
        precondition(organizer.error != nil)
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: swiftFindPathType, visibility: .all) { done in
            done(source.path.data(using: .utf8), nil); return nil
        }
        organizer.moveDroppedProviders([provider], to: dest)
        for _ in 0..<100 {
            try await Task.sleep(nanoseconds: 50_000_000)
            if fm.fileExists(atPath: moved.path) { break }
        }
        precondition(fm.fileExists(atPath: moved.path), organizer.error ?? "drop timeout")
        organizer.undoLastMove()
        let second = root.appendingPathComponent("第二份.txt")
        try Data("second".utf8).write(to: second)
        let third = root.appendingPathComponent("文件夹")
        try fm.createDirectory(at: third, withIntermediateDirectories: false)
        let batch = NSItemProvider()
        let payload = try JSONEncoder().encode([source.path, second.path, third.path])
        batch.registerDataRepresentation(forTypeIdentifier: swiftFindPathsType, visibility: .ownProcess) { done in
            done(payload, nil); return nil
        }
        organizer.moveDroppedProviders([batch], to: dest)
        let originals = [source, second, third]
        for _ in 0..<100 {
            try await Task.sleep(nanoseconds: 50_000_000)
            if originals.allSatisfy({ fm.fileExists(atPath: dest.appendingPathComponent($0.lastPathComponent).path) }) { break }
        }
        for original in originals {
            precondition(!fm.fileExists(atPath: original.path))
            precondition(fm.fileExists(atPath: dest.appendingPathComponent(original.lastPathComponent).path))
        }
        organizer.undoLastMove()
        precondition(originals.allSatisfy { fm.fileExists(atPath: $0.path) })
        print("PASS: 单项拖放、三项混合批量拖放（两个文件和文件夹）、批量撤销、中文空格路径")
    }
}

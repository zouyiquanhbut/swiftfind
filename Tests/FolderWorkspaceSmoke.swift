import AppKit
import Foundation

let swiftFindPathType = "com.swiftfind.file-path"
let swiftFindPathsType = "com.swiftfind.file-paths"
extension Notification.Name {
    static let swiftFindIndexDidChange = Notification.Name("folderWorkspaceSmokeIndex")
}

@main struct FolderWorkspaceSmoke {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent(".build/folder-test-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        // Force coverage of the negative hash that caused the runtime trap.
        let file = (0..<10000).map { root.appendingPathComponent("文件-\($0).txt") }
            .first { $0.path.hashValue < 0 }!
        try Data("regression".utf8).write(to: file)
        let child = root.appendingPathComponent("子文件夹")
        try fm.createDirectory(at: child, withIntermediateDirectories: false)
        let model = FolderWorkspaceModel()
        model.open(root)
        try await waitForLoad(model)
        precondition(model.error == nil)
        precondition(model.items.count == 2)
        precondition(model.items.contains { $0.path == file.path && $0.id < 0 })
        let directory = model.items.first { $0.isDirectory }!
        model.open(directory)
        try await waitForLoad(model)
        precondition(model.currentFolder?.path == child.path && model.items.isEmpty)
        model.goBack()
        try await waitForLoad(model)
        precondition(model.items.count == 2)
        print("PASS: negative path hash, folder browsing, directory opening, back navigation")
    }

    @MainActor static func waitForLoad(_ model: FolderWorkspaceModel) async throws {
        for _ in 0..<200 {
            if !model.isLoading { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        preconditionFailure("Folder load timed out")
    }
}

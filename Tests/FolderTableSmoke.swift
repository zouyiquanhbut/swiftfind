import AppKit
import SwiftUI

let swiftFindPathType = "com.swiftfind.file-path"
let swiftFindPathsType = "com.swiftfind.file-paths"
extension Notification.Name { static let swiftFindIndexDidChange = Notification.Name("folderTableSmokeIndex") }
final class TableSmokeDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
@main struct FolderTableSmoke {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let delegate = TableSmokeDelegate()
        NSApp.delegate = delegate
        Task { @MainActor in
            do { try await runTests(); exit(0) }
            catch { fatalError("Folder table smoke failed: \(error)") }
        }
        withExtendedLifetime(delegate) { NSApp.run() }
    }
    @MainActor static func runTests() async throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent(".build/table-test-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let child = root.appendingPathComponent("子目录")
        try fm.createDirectory(at: child, withIntermediateDirectories: false)
        let file = root.appendingPathComponent("测试.md")
        try Data("# Test".utf8).write(to: file)
        let model = FolderWorkspaceModel()
        model.open(root)
        try await loaded(model)
        var previewed: URL?
        let hosting = NSHostingView(rootView: FolderTable(model: model, onPreview: { previewed = $0.url }))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<100 {
            if descendants(hosting).contains(where: { $0 is FolderTableView }) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let table = descendants(hosting).compactMap { $0 as? FolderTableView }.first!
        precondition(table.numberOfRows == 2)
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        precondition(model.selectedItemID == model.items[1].id)
        let space = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!
        table.keyDown(with: space)
        precondition(previewed == file)
        let coordinator = table.delegate as! FolderTable.Coordinator
        let writer = coordinator.tableView(table, pasteboardWriterForRow: 1) as! NSPasteboardItem
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.writeObjects([writer])
        precondition(FileOperationService.urls(from: pasteboard) == [file])
        pasteboard.releaseGlobally()
        let revision = model.itemsRevision
        model.refresh()
        try await loaded(model)
        precondition(model.itemsRevision == revision, "Unchanged refresh must not reload all table cells")
        model.open(child)
        precondition(model.items.isEmpty, "Changing folder must immediately clear previous rows")
        try await loaded(model)
        model.goBack()
        precondition(model.items.count == 2, "Back navigation must display cached rows immediately")
        try await loaded(model)
        let deleted = model.items.first { !$0.isDirectory }!.url
        try fm.removeItem(at: deleted)
        model.refresh()
        try await loaded(model)
        precondition(model.items.count == 1)
        model.refresh()
        model.close()
        try await Task.sleep(nanoseconds: 100_000_000)
        precondition(model.currentFolder == nil && model.items.isEmpty && !model.isLoading)
        window.orderOut(nil)
        print("PASS: native selection, Space preview, drag payload, stable refresh, immediate back cache, changed contents and cancelled close")
    }
    @MainActor static func loaded(_ model: FolderWorkspaceModel) async throws {
        for _ in 0..<200 {
            if !model.isLoading { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        preconditionFailure("Folder load timeout")
    }
    @MainActor static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }
}

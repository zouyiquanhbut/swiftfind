import AppKit
import SwiftUI

struct FolderTable: NSViewRepresentable {
    @ObservedObject var model: FolderWorkspaceModel
    let onPreview: (FileRecord) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(model: model, onPreview: onPreview) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let table = FolderTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("folderItem"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.rowHeight = 52
        table.allowsEmptySelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.openClicked)
        table.onPreview = { [weak coordinator = context.coordinator] in coordinator?.preview() }
        table.onOpen = { [weak coordinator = context.coordinator] in coordinator?.openSelected() }
        table.registerForDraggedTypes([.fileURL, NSPasteboard.PasteboardType(swiftFindPathsType), NSPasteboard.PasteboardType(swiftFindPathType)])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: false)
        let menu = NSMenu()
        for (title, action) in [("打开", #selector(Coordinator.openSelected)), ("快速预览", #selector(Coordinator.preview)), ("在 Finder 中显示", #selector(Coordinator.reveal)), ("重命名…", #selector(Coordinator.rename)), ("移到废纸篓", #selector(Coordinator.trash))] {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = context.coordinator
        }
        table.menu = menu
        scroll.documentView = table
        context.coordinator.table = table
        DispatchQueue.main.async { table.window?.makeFirstResponder(table) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.model = model
        coordinator.onPreview = onPreview
        guard let table = coordinator.table else { return }
        let folderChanged = coordinator.folder != model.currentFolder
        if folderChanged || coordinator.revision != model.itemsRevision {
            coordinator.updating = true
            coordinator.folder = model.currentFolder
            coordinator.revision = model.itemsRevision
            coordinator.records = model.items
            table.reloadData()
            if folderChanged { scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView) }
            coordinator.updating = false
        }
        let index = coordinator.records.firstIndex { $0.id == model.selectedItemID }
        if table.selectedRow != (index ?? -1) {
            coordinator.updating = true
            table.selectRowIndexes(index.map { IndexSet(integer: $0) } ?? [], byExtendingSelection: false)
            coordinator.updating = false
        }
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var model: FolderWorkspaceModel
        var onPreview: (FileRecord) -> Void
        var records: [FileRecord] = []
        var revision = -1
        var folder: URL?
        var updating = false
        weak var table: FolderTableView?

        init(model: FolderWorkspaceModel, onPreview: @escaping (FileRecord) -> Void) {
            self.model = model
            self.onPreview = onPreview
        }

        var selected: FileRecord? {
            guard let table, records.indices.contains(table.selectedRow) else { return nil }
            return records[table.selectedRow]
        }

        func numberOfRows(in tableView: NSTableView) -> Int { records.count }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let identifier = NSUserInterfaceItemIdentifier("folderCell")
            let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? ResultCell) ?? ResultCell()
            cell.identifier = identifier
            cell.configure(records[row], query: "")
            return cell
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating else { return }
            model.selectedItemID = selected?.id
        }
        @objc func openClicked() {
            guard let table, records.indices.contains(table.clickedRow) else { return }
            model.open(records[table.clickedRow])
        }
        @objc func openSelected() { if let selected { model.open(selected) } }
        @objc func preview() { if let selected, !selected.isDirectory { onPreview(selected) } }
        @objc func reveal() { if let selected { model.reveal(selected) } }
        @objc func rename() { if let selected { model.rename(selected) } }
        @objc func trash() { if let selected { model.trash(selected) } }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard records.indices.contains(row) else { return nil }
            let item = NSPasteboardItem()
            item.setString(records[row].url.absoluteString, forType: .fileURL)
            item.setString(records[row].path, forType: NSPasteboard.PasteboardType(swiftFindPathType))
            return item
        }
        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
            guard !FileOperationService.urls(from: info.draggingPasteboard).isEmpty else { return [] }
            if operation == .on, records.indices.contains(row), records[row].isDirectory {
                tableView.setDropRow(row, dropOperation: .on)
            } else {
                tableView.setDropRow(-1, dropOperation: .on)
            }
            return .move
        }
        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation operation: NSTableView.DropOperation) -> Bool {
            let destination = operation == .on && records.indices.contains(row) && records[row].isDirectory ? records[row].url : model.currentFolder
            let urls = FileOperationService.urls(from: info.draggingPasteboard)
            guard let destination, !urls.isEmpty else { return false }
            model.moveDroppedURLs(urls, to: destination)
            return true
        }
    }
}

final class FolderTableView: NSTableView {
    var onPreview: (() -> Void)?
    var onOpen: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == 49 && flags.isEmpty { onPreview?(); return }
        if event.keyCode == 36 && flags.isEmpty { onOpen?(); return }
        super.keyDown(with: event)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let index = row(at: convert(event.locationInWindow, from: nil))
        guard index >= 0 else { return nil }
        selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        return super.menu(for: event)
    }
}

import AppKit
import SwiftUI

struct ResultsTable: NSViewRepresentable {
    @ObservedObject var model: SearchModel

    func makeCoordinator() -> Coordinator { Coordinator(model) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let table = ResultTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("result"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.rowHeight = 52
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.openClicked)
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: false)
        table.onPreview = { [weak coordinator = context.coordinator] in coordinator?.preview() }
        table.onOpen = { [weak coordinator = context.coordinator] reveal in coordinator?.openSelected(reveal) }
        table.onMoveToTarget = { [weak coordinator = context.coordinator] index in coordinator?.moveSelected(toTargetAt: index) }
        table.onTrash = { [weak coordinator = context.coordinator] confirm in coordinator?.trash(confirm: confirm) }
        let menu = NSMenu()
        for (title, action) in [("打开", #selector(Coordinator.openMenu)), ("快速预览", #selector(Coordinator.preview)), ("在 Finder 中显示", #selector(Coordinator.reveal)), ("复制路径", #selector(Coordinator.copyPaths)), ("重命名…", #selector(Coordinator.rename)), ("移到废纸篓", #selector(Coordinator.trashMenu))] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = context.coordinator
        }
        table.menu = menu
        scroll.documentView = table
        context.coordinator.table = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.model = model
        let rows = model.query.isEmpty ? model.recentResults : model.results
        let sortChanged = coordinator.sort != model.sort || coordinator.ascending != model.ascending
        let resultsChanged = coordinator.resultsRevision != model.resultsRevision
        guard resultsChanged || model.query != coordinator.query || sortChanged else { return }
        guard let table = coordinator.table else { return }
        let selectedPaths = Set(table.selectedRowIndexes.compactMap { coordinator.records.indices.contains($0) ? coordinator.records[$0].path : nil })
        coordinator.updating = true
        coordinator.records = rows
        coordinator.query = model.query
        coordinator.resultsRevision = model.resultsRevision
        coordinator.sort = model.sort
        coordinator.ascending = model.ascending
        table.reloadData()
        let indexes = IndexSet(rows.indices.filter { selectedPaths.contains(rows[$0].path) })
        table.selectRowIndexes(indexes, byExtendingSelection: false)
        coordinator.updating = false
        let ids = Set(indexes.map { rows[$0].id })
        DispatchQueue.main.async {
            if model.selectedIDs != ids { model.selectedIDs = ids }
        }
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var model: SearchModel
        var records: [FileRecord] = []
        var query = ""
        var resultsRevision = -1
        var sort: ResultSort = .name
        var ascending = true
        var updating = false
        weak var table: ResultTableView?
        init(_ model: SearchModel) { self.model = model }
        func numberOfRows(in tableView: NSTableView) -> Int { records.count }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let id = NSUserInterfaceItemIdentifier("cell")
            let cell = (tableView.makeView(withIdentifier: id, owner: self) as? ResultCell) ?? ResultCell()
            cell.identifier = id
            cell.configure(records[row], query: query)
            return cell
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table else { return }
            model.selectedIDs = Set(table.selectedRowIndexes.filter { records.indices.contains($0) }.map { records[$0].id })
        }
        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard records.indices.contains(row) else { return nil }
            let item = NSPasteboardItem()
            item.setString(records[row].url.absoluteString, forType: .fileURL)
            item.setData(Data(records[row].path.utf8), forType: NSPasteboard.PasteboardType(swiftFindPathType))
            return item
        }
        var selected: [FileRecord] {
            guard let table else { return [] }
            return table.selectedRowIndexes.filter { records.indices.contains($0) }.map { records[$0] }
        }
        @objc func openClicked() {
            guard let table, records.indices.contains(table.clickedRow) else { return }
            model.open(records[table.clickedRow])
        }
        func openSelected(_ reveal: Bool) { if let record = selected.first { model.open(record, reveal: reveal) } }
        func moveSelected(toTargetAt index: Int) { model.move(selected, toTargetAt: index) }
        @objc func openMenu() { openSelected(false) }
        @objc func reveal() { openSelected(true) }
        @objc func preview() { if let record = selected.first { model.openQuickLook(record) } }
        @objc func rename() {
            guard selected.count == 1, let record = selected.first else { return }
            FileActions.rename(record) { self.table?.reloadData() }
        }
        @objc func trashMenu() { trash(confirm: true) }
        func trash(confirm: Bool) {
            let records = selected
            FileActions.trash(records, confirm: confirm) { self.table?.reloadData() }
        }
        @objc func copyPaths() {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(selected.map(\.path).joined(separator: "\n"), forType: .string)
        }
    }
}

final class ResultTableView: NSTableView {
    var onPreview: (() -> Void)?
    var onOpen: ((Bool) -> Void)?
    var onMoveToTarget: ((Int) -> Void)?
    var onTrash: ((Bool) -> Void)?
    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == 49 && flags.isEmpty { onPreview?(); return }
        if event.keyCode == 36 { onOpen?(flags.contains(.command)); return }
        if event.keyCode == 51 && flags == .command { onTrash?(false); return }
        if flags == .option, let character = event.charactersIgnoringModifiers?.first,
           let digit = character.wholeNumberValue, (1...9).contains(digit) {
            onMoveToTarget?(digit - 1)
            return
        }
        if event.charactersIgnoringModifiers == "a" && flags == .command { selectAll(nil); return }
        super.keyDown(with: event)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let index = row(at: convert(event.locationInWindow, from: nil))
        guard index >= 0 else { return nil }
        if !selectedRowIndexes.contains(index) { selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        return super.menu(for: event)
    }
}

private final class ResultCell: NSTableCellView {
    let title = NSTextField(labelWithString: "")
    let path = NSTextField(labelWithString: "")
    let size = NSTextField(labelWithString: "")
    let icon = NSImageView()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for view in [title, path, size, icon] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        title.font = .systemFont(ofSize: 13)
        path.font = .systemFont(ofSize: 11)
        path.textColor = .secondaryLabelColor
        size.font = .systemFont(ofSize: 11)
        size.textColor = .secondaryLabelColor
        for label in [title, path, size] { label.lineBreakMode = .byTruncatingMiddle; label.maximumNumberOfLines = 1 }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8), icon.centerYAnchor.constraint(equalTo: centerYAnchor), icon.widthAnchor.constraint(equalToConstant: 22), icon.heightAnchor.constraint(equalToConstant: 22),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8), title.topAnchor.constraint(equalTo: topAnchor, constant: 7), title.trailingAnchor.constraint(equalTo: size.leadingAnchor, constant: -8),
            path.leadingAnchor.constraint(equalTo: title.leadingAnchor), path.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3), path.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            size.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10), size.centerYAnchor.constraint(equalTo: centerYAnchor), size.widthAnchor.constraint(equalToConstant: 85)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
    // Let the table handle clicks anywhere in the row, including labels and icon.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func configure(_ record: FileRecord, query: String) {
        title.attributedStringValue = highlighted(record.name, query)
        path.attributedStringValue = highlighted(record.path, query)
        size.stringValue = record.sizeText
        icon.image = NSImage(systemSymbolName: record.isDirectory ? "folder.fill" : "doc", accessibilityDescription: nil)
        toolTip = record.path
    }
    private func highlighted(_ value: String, _ query: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: value)
        let text = value as NSString
        for term in SearchQueryParser().parse(query).text.split(whereSeparator: { $0.isWhitespace }) {
            var remaining = NSRange(location: 0, length: text.length)
            while remaining.length > 0 {
                let match = text.range(of: String(term), options: .caseInsensitive, range: remaining)
                if match.location == NSNotFound { break }
                result.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.3), range: match)
                remaining = NSRange(location: NSMaxRange(match), length: text.length - NSMaxRange(match))
            }
        }
        return result
    }
}

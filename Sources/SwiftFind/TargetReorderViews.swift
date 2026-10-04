import AppKit
import SwiftUI

private let targetReorderPasteboardType = NSPasteboard.PasteboardType(swiftFindTargetReorderType)

struct TargetReorderHandle: NSViewRepresentable {
    let targetID: UUID

    func makeNSView(context: Context) -> ReorderHandleNSView {
        let view = ReorderHandleNSView()
        view.targetID = targetID
        return view
    }

    func updateNSView(_ nsView: ReorderHandleNSView, context: Context) {
        nsView.targetID = targetID
    }
}

final class ReorderHandleNSView: NSView, NSDraggingSource {
    var targetID: UUID?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let imageView = NSImageView(image: NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "拖动排序") ?? NSImage())
        imageView.contentTintColor = .secondaryLabelColor
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 18),
            imageView.heightAnchor.constraint(equalToConstant: 18)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func mouseDown(with event: NSEvent) {
        guard let targetID else { return }
        let item = NSPasteboardItem()
        item.setString(targetID.uuidString, forType: targetReorderPasteboardType)
        let dragging = NSDraggingItem(pasteboardWriter: item)
        dragging.setDraggingFrame(bounds, contents: layer)
        beginDraggingSession(with: [dragging], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationForDraggingAt screenPoint: NSPoint) -> NSDragOperation { .move }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .move }
}

struct TargetReorderDropZone: NSViewRepresentable {
    let position: Int
    let organizer: FileOrganizer

    func makeNSView(context: Context) -> ReorderDropNSView {
        let view = ReorderDropNSView()
        view.position = position
        view.organizer = organizer
        return view
    }

    func updateNSView(_ nsView: ReorderDropNSView, context: Context) {
        nsView.position = position
        nsView.organizer = organizer
    }
}

final class ReorderDropNSView: NSView {
    var position = 0
    weak var organizer: FileOrganizer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([targetReorderPasteboardType])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.types?.contains(targetReorderPasteboardType) == true else { return [] }
        organizer?.setTargetDropIndex(position)
        return .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        // Keep this as a cheap fallback for AppKit view reuse/boundary
        // transitions. FileOrganizer ignores identical positions, so staying
        // in one zone does not publish repeated SwiftUI updates.
        organizer?.setTargetDropIndex(position)
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        if organizer?.targetDropIndex == position { organizer?.setTargetDropIndex(nil) }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let text = sender.draggingPasteboard.string(forType: targetReorderPasteboardType),
              let id = UUID(uuidString: text) else { return false }
        organizer?.moveTarget(id: id, to: position)
        return true
    }
}

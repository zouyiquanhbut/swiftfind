import AppKit
import SwiftUI

struct KeyHandlingView: NSViewRepresentable {
    let onSpace: () -> Void
    var selectionID: Int64? = nil

    func makeNSView(context: Context) -> HandlerView {
        let view = HandlerView()
        view.onSpace = onSpace
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ nsView: HandlerView, context: Context) {
        nsView.onSpace = onSpace
        if nsView.selectionID != selectionID {
            nsView.selectionID = selectionID
            if selectionID != nil {
                DispatchQueue.main.async { nsView.window?.makeFirstResponder(nsView) }
            }
        }
    }

    final class HandlerView: NSView {
        var onSpace: (() -> Void)?
        var selectionID: Int64?

        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if event.keyCode == 49 && modifiers.isEmpty {
                onSpace?()
            } else {
                super.keyDown(with: event)
            }
        }
    }
}

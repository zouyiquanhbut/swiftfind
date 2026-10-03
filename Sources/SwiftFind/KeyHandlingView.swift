import AppKit
import SwiftUI

struct KeyHandlingView: NSViewRepresentable {
    let onSpace: () -> Void

    func makeNSView(context: Context) -> HandlerView {
        let view = HandlerView()
        view.onSpace = onSpace
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ nsView: HandlerView, context: Context) {
        nsView.onSpace = onSpace
    }

    final class HandlerView: NSView {
        var onSpace: (() -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 49 {
                onSpace?()
            } else {
                super.keyDown(with: event)
            }
        }
    }
}

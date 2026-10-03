import AppKit

final class StatusBarController {
    private let item: NSStatusItem
    private var observer: NSObjectProtocol?

    init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = item.button else { return }
        button.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "SwiftFind")
        button.image?.isTemplate = true
        button.toolTip = "SwiftFind：搜索文件"
        button.target = self
        button.action = #selector(showSearchWindow)
        observer = NotificationCenter.default.addObserver(forName: .swiftFindToggleWindow, object: nil, queue: .main) { [weak self] _ in self?.showSearchWindow() }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    @objc private func showSearchWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.title == "SwiftFind" }) {
            if window.isVisible && NSApp.isActive { window.orderOut(nil) } else { window.makeKeyAndOrderFront(nil) }
        } else {
            NSApp.sendAction(#selector(NSResponder.newWindowForTab(_:)), to: nil, from: nil)
        }
    }
}

import AppKit

/// Open the directory's contents in Finder, not its parent with the item selected.
@MainActor
enum FolderOpener {
    static func open(_ url: URL) {
        guard let finder = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder") else {
            showError("无法找到 Finder")
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: finder, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error {
                let message = error.localizedDescription
                Task { @MainActor in showError(message) }
            }
        }
    }

    private static func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "无法打开文件夹"
        alert.informativeText = message
        alert.runModal()
    }
}

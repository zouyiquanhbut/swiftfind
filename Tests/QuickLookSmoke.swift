import AppKit
import Foundation

extension Notification.Name {
    static let swiftFindIndexDidChange = Notification.Name("quickLookSmokeIndex")
}
final class FileOrganizer {
    struct Target { let url: URL }
    var targets: [Target] = []
    func move(urls: [URL], to destination: URL) -> Bool { false }
}
final class SmokeAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main struct QuickLookSmoke {
    @MainActor static func main() {
        _ = NSApplication.shared
        let delegate = SmokeAppDelegate()
        NSApp.delegate = delegate
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await runTests(); exit(0) }
            catch { fatalError("Preview smoke failed: \(error)") }
        }
        withExtendedLifetime(delegate) { NSApp.run() }
        fatalError("Application exited before smoke tests completed")
    }

    @MainActor static func runTests() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("第一份.txt")
        let second = root.appendingPathComponent("第二份.txt")
        let markdown = root.appendingPathComponent("说明.MD")
        let markdownText = "# 阅读测试\n\n中文 Markdown **正文**\n"
        try Data("First preview".utf8).write(to: first)
        try Data("Second preview".utf8).write(to: second)
        try Data(markdownText.utf8).write(to: markdown)
        let fontKey = "markdownPreviewFontSize"
        let savedSize = UserDefaults.standard.object(forKey: fontKey)
        defer {
            if let savedSize { UserDefaults.standard.set(savedSize, forKey: fontKey) }
            else { UserDefaults.standard.removeObject(forKey: fontKey) }
        }
        UserDefaults.standard.set(18, forKey: fontKey)
        let organizer = FileOrganizer()
        let controller = QuickLookController.shared
        for cycle in 0..<10 {
            controller.show(urls: [first, second], selected: first, organizer: organizer)
            try await Task.sleep(nanoseconds: 100_000_000)
            controller.show(urls: [first, second], selected: second, organizer: organizer)
            try await Task.sleep(nanoseconds: 100_000_000)
            controller.show(urls: [first, second, markdown], selected: markdown, organizer: organizer)
            let content = controller.window!.contentView!
            let markdownView = descendants(content).compactMap { $0 as? MarkdownPreviewView }.first!
            let textView = descendants(markdownView).compactMap { $0 as? NSTextView }.first!
            for _ in 0..<100 {
                if textView.string == markdownText { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            precondition(!markdownView.isHidden && textView.string == markdownText)
            precondition(!textView.isEditable && textView.isSelectable)
            let largerButton = descendants(markdownView).compactMap { $0 as? NSButton }.first { $0.title == "A+" }!
            let smallerButton = descendants(markdownView).compactMap { $0 as? NSButton }.first { $0.title == "A−" }!
            largerButton.performClick(nil)
            precondition(textView.font?.pointSize == 20)
            precondition(UserDefaults.standard.double(forKey: fontKey) == 20)
            let reopenedView = MarkdownPreviewView(frame: .zero)
            let reopenedText = descendants(reopenedView).compactMap { $0 as? NSTextView }.first!
            precondition(reopenedText.font?.pointSize == 20)
            smallerButton.performClick(nil)
            precondition(textView.font?.pointSize == 18)
            controller.window?.performClose(nil)
            precondition(controller.window?.isVisible == false)
            print("Preview cycle \(cycle + 1) passed")
        }
        print("PASS: ten preview cycles, Markdown reading, font controls and saved size")
    }

    @MainActor static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }
}

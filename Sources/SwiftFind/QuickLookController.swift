import AppKit
import QuickLookUI
import SwiftUI

/// A Quick Look panel with explicit previous/next controls for the current result set.
final class QuickLookController: NSWindowController {
    static let shared = QuickLookController()
    private let previewView: QLPreviewView
    private let previousButton = NSButton()
    private let nextButton = NSButton()
    private let trashButton = NSButton()
    private var urls: [URL] = []
    private weak var organizer: FileOrganizer?
    private var currentIndex = 0

    private init() {
        previewView = QLPreviewView(frame: .zero, style: .normal)
        let panel = NavigationPreviewPanel(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 640),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "快速预览"
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        panel.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        configurePanel(panel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func show(urls: [URL], selected: URL, organizer: FileOrganizer) {
        self.organizer = organizer
        let files = urls.filter { !$0.hasDirectoryPath }
        guard !files.isEmpty else { return }
        self.urls = files
        currentIndex = files.firstIndex(of: selected) ?? 0
        updatePreview()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func configurePanel(_ panel: NSPanel) {
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = content
        previewView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(previewView)

        configure(button: previousButton, symbol: "chevron.left", action: #selector(previous))
        configure(button: nextButton, symbol: "chevron.right", action: #selector(next))
        configure(button: trashButton, symbol: "trash", action: #selector(trashCurrent))
        trashButton.toolTip = "移到废纸篓（⌘⌫）"
        content.addSubview(previousButton)
        content.addSubview(nextButton)
        content.addSubview(trashButton)

        NSLayoutConstraint.activate([
            previewView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            previewView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            previewView.topAnchor.constraint(equalTo: content.topAnchor),
            previewView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            previousButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            previousButton.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            previousButton.widthAnchor.constraint(equalToConstant: 42),
            previousButton.heightAnchor.constraint(equalToConstant: 52),
            nextButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            nextButton.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            nextButton.widthAnchor.constraint(equalToConstant: 42),
            nextButton.heightAnchor.constraint(equalToConstant: 52),
            trashButton.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            trashButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            trashButton.widthAnchor.constraint(equalToConstant: 42),
            trashButton.heightAnchor.constraint(equalToConstant: 32)
        ])
    }

    private func configure(button: NSButton, symbol: String, action: Selector) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .texturedRounded
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imagePosition = .imageOnly
        button.target = self
        button.action = action
    }

    @objc private func previous() {
        guard currentIndex > 0 else { return }
        currentIndex -= 1
        updatePreview()
    }

    @objc private func next() {
        guard currentIndex < urls.count - 1 else { return }
        currentIndex += 1
        updatePreview()
    }

    @objc private func trashCurrent() {
        guard urls.indices.contains(currentIndex) else { return }
        let url = urls[currentIndex]
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            urls.remove(at: currentIndex)
            NotificationCenter.default.post(name: .swiftFindIndexDidChange, object: nil, userInfo: ["movedPaths": [url.path]])
            if urls.isEmpty {
                close()
            } else {
                currentIndex = min(currentIndex, urls.count - 1)
                updatePreview()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "无法移到废纸篓"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == 123 && flags.isEmpty { previous(); return true }
        if event.keyCode == 124 && flags.isEmpty { next(); return true }
        if event.keyCode == 51 && flags == .command { trashCurrent(); return true }
        if flags == .option, let character = event.charactersIgnoringModifiers?.first,
           let digit = character.wholeNumberValue, (1...9).contains(digit) {
            moveCurrent(toTargetAt: digit - 1)
            return true
        }
        return false
    }

    private func moveCurrent(toTargetAt index: Int) {
        guard urls.indices.contains(currentIndex), let organizer else { return }
        guard organizer.targets.indices.contains(index) else {
            let alert = NSAlert()
            alert.messageText = "目标文件夹快捷键 ⌥\(index + 1) 尚未设置"
            alert.runModal()
            return
        }
        let url = urls[currentIndex]
        guard organizer.move(urls: [url], to: organizer.targets[index].url) else { return }
        urls.remove(at: currentIndex)
        if urls.isEmpty { close() }
        else { currentIndex = min(currentIndex, urls.count - 1); updatePreview() }
    }

    private func updatePreview() {
        guard urls.indices.contains(currentIndex) else { return }
        let url = urls[currentIndex]
        previewView.previewItem = url as NSURL
        previousButton.isEnabled = currentIndex > 0
        nextButton.isEnabled = currentIndex < urls.count - 1
        window?.title = "\(url.lastPathComponent)（\(currentIndex + 1)/\(urls.count)）"
    }
}

private final class NavigationPreviewPanel: NSPanel {
    var keyHandler: ((NSEvent) -> Bool)?
    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }
}

struct HistoryView: View {
    let history: [String]
    let select: (String) -> Void

    var body: some View {
        if !history.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text("最近搜索").font(.caption).foregroundStyle(.secondary)
                ForEach(history.prefix(5), id: \.self) { value in
                    Button { select(value) } label: {
                        HStack { Image(systemName: "clock"); Text(value); Spacer() }
                    }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 14).padding(.bottom, 8)
        }
    }
}

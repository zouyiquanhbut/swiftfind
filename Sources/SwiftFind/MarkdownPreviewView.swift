import AppKit

/// A selectable Markdown source preview with a persistent reading size.
final class MarkdownPreviewView: NSView {
    private let textView = NSTextView()
    private let smallerButton = NSButton(title: "A−", target: nil, action: nil)
    private let largerButton = NSButton(title: "A+", target: nil, action: nil)
    private let sizeLabel = NSTextField(labelWithString: "")
    private var loadTask: Task<Void, Never>?
    private var generation = 0
    private static let sizeKey = "markdownPreviewFontSize"
    private var fontSize: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: sizeKey)
        return saved.isFinite && saved >= 12 && saved <= 36 ? CGFloat(saved) : 18
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let toolbar = NSStackView(views: [smallerButton, sizeLabel, largerButton])
        toolbar.spacing = 10
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        smallerButton.target = self
        smallerButton.action = #selector(decreaseSize)
        smallerButton.toolTip = "缩小 Markdown 字号"
        largerButton.target = self
        largerButton.action = #selector(increaseSize)
        largerButton.toolTip = "放大 Markdown 字号"
        smallerButton.bezelStyle = .rounded
        largerButton.bezelStyle = .rounded
        addSubview(toolbar)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 64, height: 20)
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        scroll.documentView = textView
        addSubview(scroll)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -52)
        ])
        applyFontSize()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit { loadTask?.cancel() }

    func show(_ url: URL) {
        clear()
        let requestedGeneration = generation
        textView.string = "读取 Markdown…"
        loadTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try String(contentsOf: url, encoding: .utf8) }
            }.value
            guard !Task.isCancelled, let self, self.generation == requestedGeneration else { return }
            switch result {
            case .success(let text): self.textView.string = text
            case .failure(let error): self.textView.string = "无法读取 Markdown：\(error.localizedDescription)"
            }
            self.applyFontSize()
            self.textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        }
    }

    func clear() {
        generation += 1
        loadTask?.cancel()
        loadTask = nil
        textView.string = ""
    }

    @objc private func decreaseSize() { changeSize(by: -2) }
    @objc private func increaseSize() { changeSize(by: 2) }

    private func changeSize(by delta: CGFloat) {
        fontSize = min(36, max(12, fontSize + delta))
        UserDefaults.standard.set(Double(fontSize), forKey: Self.sizeKey)
        applyFontSize()
    }

    private func applyFontSize() {
        textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        sizeLabel.stringValue = "\(Int(fontSize)) pt"
        smallerButton.isEnabled = fontSize > 12
        largerButton.isEnabled = fontSize < 36
    }
}

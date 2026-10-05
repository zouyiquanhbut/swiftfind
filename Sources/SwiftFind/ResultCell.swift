import AppKit

final class ResultCell: NSTableCellView {
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
